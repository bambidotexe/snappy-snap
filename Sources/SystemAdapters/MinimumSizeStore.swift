import AppKit
import Combine
import CoreGraphics
import Foundation
import SnapCore

/// Everything SnappySnap knows about how small windows go, and the one place it is written.
///
/// **Two layers.** The **list** (`MinimumSizeList`): one row per application, persisted under
/// `minimumSizes.v3` as the part this Mac produced, and published so the Settings tab follows it. The
/// **windows**: for every window an Accessibility path has held, in memory, its own floor — a raise
/// over its application's row, from a refusal or from a probe that read higher than the row —
/// whether a probe was spent on it this session, and the bundle identifier it was held under.
///
/// Each method is one rule of `docs/functional.md` §6:
/// - `observe` is a free look at a window's size. It lowers the row and the window's own floor to
///   what was seen, per axis, and never raises anything. From an Accessibility path it also **holds**
///   the window; from the 10 Hz sweep it lowers only a held window, because CGWindowList cannot tell
///   a sheet or a panel from a main window, and a row lowered to a sheet's size would be wrong for
///   every main window afterwards.
/// - `recordProbe` writes what a probe believed: the row of an application that had none, or a
///   window's own floor where the probe read higher than the row.
/// - `refused` raises a window's own floor and **never the row**.
/// - `edit`, `add`, `remove` and `reset` are the user's.
///
/// **Reads never publish; writes publish only on a change.** The store is asked at the press of every
/// handle gesture, on the run loop that serves the event tap, so `list` is assigned — and the file
/// written — only when a mutation actually changed it. Nothing here makes an Accessibility call: a
/// bundle identifier is read from `NSRunningApplication` once per held window.
@MainActor
public final class MinimumSizeStore: ObservableObject {
    /// Its own key: a learned fact about other applications, not a user setting. **v3** holds the
    /// stored part of the list and is absent while the list equals the built-in one.
    public static let defaultsKey = "minimumSizes.v3"
    /// Earlier shapes, deleted rather than read. Nothing is migrated: this Mac starts from the
    /// built-in list and measures the rest again, once each.
    static let retiredKeys = ["minimumSizes.v2", "minimumSizes.v1", "knownMinimums.v1"]
    /// How many windows are remembered before the least recently touched are dropped. A desktop has
    /// tens of windows, not hundreds; this exists so a long-lived session that has opened and closed
    /// thousands cannot grow the table without bound.
    static let windowCeiling = 512

    @Published public private(set) var list: MinimumSizeList

    /// One held window. `pid` is carried so a `CGWindowID` the window server has handed out again
    /// cannot answer for the window that used to own it. `bundleID` is read once, when the window is
    /// first held, so the sweep never asks `NSRunningApplication` anything.
    private struct WindowEntry {
        var pid: pid_t
        var bundleID: String?
        var floor = WindowFloor()
        var probed = false
        /// When the window was last held or seen, on the store's own monotonic clock. A counter rather
        /// than a date, so two windows held in the same instant still have an order to be evicted in.
        var touched: UInt64
    }

    private var windows: [CGWindowID: WindowEntry] = [:]
    private var clock: UInt64 = 0
    private let defaults: UserDefaults

    /// True when a saved list was there at launch and could not be read, so the built-in one stands in
    /// for it. The Health page reports it; the next change writes a readable list over it.
    public let storedListWasUnreadable: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.defaultsKey)
        let stored = data.flatMap { try? JSONDecoder().decode(MinimumSizeList.Stored.self, from: $0) }
        storedListWasUnreadable = data != nil && stored == nil
        list = MinimumSizeList(stored: stored ?? MinimumSizeList.Stored())
        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Reads

    /// The bundle identifier of a running process, or nil for one that has none. A process with no
    /// bundle identifier has no row and can have none: the only other key would be its pid, which
    /// means nothing after it exits.
    private func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// The row of the application behind `pid`, if it has one.
    public func row(for pid: pid_t) -> MinimumRow? {
        guard let id = bundleID(for: pid) else { return nil }
        return list.row(for: id)
    }

    /// Whether the application behind `pid` has a row — and is therefore never probed outside the deck.
    public func hasRow(for pid: pid_t) -> Bool { row(for: pid) != nil }

    /// What this window will not go below: its application's row lifted, per axis, by the window's
    /// own floor. Nil when there is neither; **0 on an axis nothing knows**, which every caller
    /// takes as "presume".
    public func minimum(for handle: WindowHandle) -> CGSize? {
        minimum(forWindowID: handle.windowID, pid: handle.pid)
    }

    /// The same question asked with **no Accessibility element** — a window id and its owner, which
    /// is everything the window list hands out, and therefore everything a drag start can afford per
    /// occupant on screen.
    public func minimum(forWindowID id: CGWindowID?, pid: pid_t) -> CGSize? {
        let entry = id.flatMap { windows[$0] }.flatMap { $0.pid == pid ? $0 : nil }
        let row = (entry?.bundleID ?? bundleID(for: pid)).flatMap { list.row(for: $0) }
        return MinimumSizePolicy.floor(row: row?.size, window: entry?.floor)
    }

    /// Whether a probe has been spent on this window in this session, whatever it read back.
    public func wasProbed(_ handle: WindowHandle) -> Bool {
        guard let id = handle.windowID, let entry = windows[id], entry.pid == handle.pid else { return false }
        return entry.probed
    }

    /// For tests: how many windows are held.
    var heldWindowCount: Int { windows.count }

    // MARK: - Observations

    /// What one look at a window changed, for the caller's log line.
    public struct Observation: Sendable {
        public let bundleID: String?
        /// The application's row before and after, when the look lowered it.
        public let row: (from: CGSize, to: CGSize)?
        /// The window's own floor before and after, when the look lowered it.
        public let windowFloor: (from: CGSize, to: CGSize)?

        public var loweredSomething: Bool { row != nil || windowFloor != nil }
    }

    /// A free look at a window from an Accessibility path — a press, a drag start, the deck, a
    /// landing. **Holds** the window, then lowers its row and its own floor to `size`, per axis,
    /// where they were larger by more than the tolerance. Never raises anything.
    @discardableResult
    public func observe(_ handle: WindowHandle, size: CGSize) -> Observation {
        let key = hold(handle)
        return lower(windowID: handle.windowID, pid: handle.pid, bundleID: key, size: size)
    }

    /// The sweep's look: a window id and its owner, everything CGWindowList hands out. **Nil for a
    /// window nothing has held** — a sheet, a panel, a window the app has never touched — which may
    /// not lower a row. One dictionary lookup answers that before anything else.
    @discardableResult
    public func observe(windowID id: CGWindowID, pid: pid_t, size: CGSize) -> Observation? {
        guard var entry = windows[id], entry.pid == pid else { return nil }
        entry.touched = tick()
        windows[id] = entry
        return lower(windowID: id, pid: pid, bundleID: entry.bundleID, size: size)
    }

    @discardableResult
    private func lower(windowID id: CGWindowID?, pid: pid_t, bundleID: String?, size: CGSize) -> Observation {
        let loweredRow = bundleID.flatMap { key in mutate { $0.lower(key, seeing: size) } }
        var loweredWindow: (from: CGSize, to: CGSize)?
        if let id, var entry = windows[id], entry.pid == pid {
            let after = entry.floor.lowered(seeing: size)
            if after != entry.floor {
                loweredWindow = (entry.floor.size, after.size)
                entry.floor = after
                windows[id] = entry
            }
        }
        return Observation(bundleID: bundleID, row: loweredRow, windowFloor: loweredWindow)
    }

    /// Holds a window: makes its entry if it has none, refreshes its touch, and returns the bundle
    /// identifier it is held under — looked up once per window, or per call for a window with no id,
    /// which has no entry to remember it in.
    @discardableResult
    private func hold(_ handle: WindowHandle) -> String? {
        guard let id = handle.windowID else { return bundleID(for: handle.pid) }
        if var entry = windows[id], entry.pid == handle.pid {
            entry.touched = tick()
            windows[id] = entry
            return entry.bundleID
        }
        let key = bundleID(for: handle.pid)
        windows[id] = WindowEntry(pid: handle.pid, bundleID: key, touched: tick())
        trim()
        return key
    }

    private func tick() -> UInt64 {
        clock += 1
        return clock
    }

    /// Least recently touched first, and only ever back down to the ceiling. There is no notification
    /// for a window closing that this class hears, so the table is trimmed rather than kept exact.
    private func trim() {
        guard windows.count > Self.windowCeiling else { return }
        let doomed = windows.sorted { $0.value.touched < $1.value.touched }
            .prefix(windows.count - Self.windowCeiling)
        for entry in doomed { windows.removeValue(forKey: entry.key) }
    }

    // MARK: - Probes

    /// A probe has been written to this window. Whatever it reads back, it is not spent on the window
    /// again in this session.
    public func markProbed(_ handle: WindowHandle) {
        hold(handle)
        guard let id = handle.windowID, var entry = windows[id], entry.pid == handle.pid else { return }
        entry.probed = true
        windows[id] = entry
    }

    /// What a probe's result was written as.
    public enum ProbeRecord: Sendable, Equatable {
        /// The application had no row; this measurement is now its row.
        case row(MinimumRow)
        /// The window's own floor, after: the application has a row and the probe read higher, or it
        /// has none and the probe believed one axis only.
        case windowFloor(CGSize)
        /// Nothing believed, or nothing above the row.
        case nothing
    }

    /// Records a probe's result. `believed` is the read-back with **0 on every axis that was not
    /// believed**. Per believed axis: the window was seen at that size, so its row and its floor are
    /// lowered to it where they were larger; an application with no row gets the believed axis as
    /// the window's floor, and both axes as its row; an application with a row and a result higher
    /// than it gets the window's floor raised — **the row does not move**.
    @discardableResult
    public func recordProbe(_ believed: CGSize, for handle: WindowHandle) -> ProbeRecord {
        markProbed(handle)
        let key = hold(handle)
        lower(windowID: handle.windowID, pid: handle.pid, bundleID: key, size: believed)
        guard believed.width > 0 || believed.height > 0 else { return .nothing }
        if let key, let row = list.row(for: key) {
            var above = CGSize.zero
            let slack = MinimumSizePolicy.observationTolerance
            if Double(believed.width) > row.width + slack { above.width = believed.width }
            if Double(believed.height) > row.height + slack { above.height = believed.height }
            guard above != .zero, let floor = raise(above, for: handle) else { return .nothing }
            return .windowFloor(floor)
        }
        // No row. Both axes believed make the row — and only the row: a raise on top of it would keep
        // this window at a reading that a later, smaller window of the application has already
        // corrected in the row, with nothing but a hand-resize to lower it. One axis believed is the
        // window's own floor on that axis, and the application stays rowless.
        if let key, believed.width > 0, believed.height > 0 {
            let name = NSRunningApplication(processIdentifier: handle.pid)?.localizedName ?? key
            if let row = mutate({ $0.measured(believed, bundleID: key, name: name) }) { return .row(row) }
        }
        return raise(believed, for: handle).map { .windowFloor($0) } ?? .nothing
    }

    /// Raises the window's own floor by `size`, per axis (0 says nothing). Returns the floor after,
    /// or nil when the window has no id to remember it by or nothing changed.
    private func raise(_ size: CGSize, for handle: WindowHandle) -> CGSize? {
        hold(handle)
        guard let id = handle.windowID, var entry = windows[id], entry.pid == handle.pid else { return nil }
        let after = entry.floor.raised(by: size)
        guard after != entry.floor else { return nil }
        entry.floor = after
        windows[id] = entry
        return after.size
    }

    /// A landing larger than asked, on the axes it was asked to change (0 says nothing about an
    /// axis): **the row does not move.** Returns the window's own floor after, when it changed.
    @discardableResult
    public func refused(_ size: CGSize, for handle: WindowHandle) -> CGSize? {
        guard size.width > 0 || size.height > 0 else { return nil }
        return raise(size, for: handle)
    }

    // MARK: - The user's

    public func edit(_ bundleID: String, width: Double? = nil, height: Double? = nil) {
        mutate { $0.edit(bundleID, width: width, height: height) }
    }

    public func add(bundleID: String, name: String, size: CGSize) {
        mutate { $0.add(bundleID: bundleID, name: name, size: size) }
    }

    /// Removing a row means *measure this application again* — from nothing. The windows held under
    /// this identifier go with it: their own floors, and whether a probe was spent on them, so the
    /// next press probes again rather than clamping at a floor the removed row left behind.
    public func remove(_ bundleID: String) {
        mutate { $0.remove(bundleID) }
        windows = windows.filter { $0.value.bundleID != bundleID }
    }

    /// The built-in list, and nothing else the app has learned: every window's own floor and every
    /// probe go too, so what the tab shows is what every handle clamps with.
    public func reset() {
        mutate { $0.reset() }
        windows = [:]
    }

    // MARK: - Writing

    /// Every write to the list goes through here: the copy is assigned back — and so published and
    /// saved — only when the mutation changed it.
    @discardableResult
    private func mutate<T>(_ body: (inout MinimumSizeList) -> T) -> T {
        var copy = list
        let result = body(&copy)
        if copy != list {
            list = copy
            save()
        }
        return result
    }

    /// The stored part, or nothing at all while the list equals the built-in one — so a Mac whose
    /// user never touched the list follows the built-in list from build to build.
    ///
    /// Written on every change, with no coalescing: one save is one JSON encode of the stored rows
    /// and one `UserDefaults.set`, measured at 117 µs for 45 rows (51 µs of it the encode), so the 10 Hz
    /// sweep lowering a row on every tick of a hand-resize costs about a millisecond of main-thread
    /// time per second, and a lowered row can never be lost to a crash.
    private func save() {
        if list.isBuiltIn {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(list.stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
