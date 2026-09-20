import CoreGraphics
import Foundation

/// The windows Snap Assist has moved out of the way, on disk.
///
/// A parked window sits in a corner of the screen with no Dock affordance, so unlike a minimized one it
/// leaves the user nothing to click. This list is the way back: it is written as windows are parked, and
/// cleared only once every one of them is home. If the app dies mid-phase, the next launch reads it and
/// puts the windows back.
@MainActor
public final class ParkedWindowsStore {
    /// One parked window. Identified by window id *and* pid, so a stale entry cannot be applied to some
    /// other app's window after a relaunch.
    public struct Entry: Codable, Hashable, Sendable {
        public var windowID: CGWindowID
        public var pid: pid_t
        /// Where the window was before it was parked, in CG space.
        public var frame: CGRect

        public init(windowID: CGWindowID, pid: pid_t, frame: CGRect) {
            self.windowID = windowID
            self.pid = pid
            self.frame = frame
        }
    }

    /// Its own key: this is short-lived crash-recovery state, not a user setting.
    public static let defaultsKey = "parkedWindows.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// Writing an empty list clears the key: nothing is parked, so there is nothing to recover.
    ///
    /// **Why the deprecated `synchronize()` is here.** `set` hands the value to `cfprefsd` — a separate
    /// process — *asynchronously*, so between the call returning and the XPC going out there is a
    /// window in which a `SIGKILL` of this app loses the record. That window is microseconds wide and
    /// the live proof went the other way (a kill 120 ms into a deal recovered all eight entries at
    /// their true pre-move frames), but "empirically true on this machine" is the wrong standard for
    /// the *only* way back for a window with no Dock affordance, and the app's own dev loop kills it
    /// with `pkill` on every relaunch. `synchronize()` forces that hand-off to happen now, which closes
    /// exactly this gap; it does not promise `cfprefsd` reached the disk, so a kernel panic or a power
    /// cut is outside the promise. It is deprecated because it was misused for cross-process reads,
    /// and there is no replacement for "make this durable now".
    ///
    /// The price is one synchronous `cfprefsd` round trip per call. That is off the drag path and off
    /// every write pass's deadline: the callers are the park loop at phase start (once per window) and
    /// the phase's end (once per pass), where the Accessibility calls beside it cost 1–30 ms each.
    public func save(_ entries: [Entry]) {
        guard !entries.isEmpty else {
            clear()
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        defaults.synchronize()
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
