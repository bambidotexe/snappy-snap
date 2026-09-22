import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// **While the gap is on, no window is left larger than the space the gap leaves.** A window that
/// is — because it was zoomed, because its title bar was double-clicked, or because it was already
/// that size when the gap was switched on — is animated back inside that space, gap and all. The
/// threshold is the working area less a gap at each end, not the working area itself: see
/// `OversizeCorrection.correction(for:in:gap:)`.
///
/// It is a preference of its own (`Settings.correctOversizedWindows`, on by default) as well as being
/// governed by the gap, because a user who wants the gap on their own snaps and wants macOS's zoom
/// left exactly as macOS left it is asking for something coherent.
///
/// The gap is the whole reason this exists. macOS's own zoom and its tiling gestures place a window
/// flush against the working area, and the app cannot ask them not to; what it can do is put the
/// window where it would have put it, so that one arrangement does not have two kinds of edge in it.
/// Switch the gap off and this stops correcting anything, because there is then nothing to disagree
/// with.
///
/// **What it costs when there is nothing to do.** A 10 Hz timer — `SpaceWatcher.idlePollInterval`,
/// the cadence every background poll in this app runs at — whose pass is one `WindowList.snapshot()`
/// (0.2–0.3 ms, no permission, no window names), one dictionary lookup per window for the observation
/// half below — plus, on a tick where a held window lowers its row, one JSON encode and one defaults
/// write, 117 µs measured for 45 rows — and then five boolean reads that end the pass whenever the gap
/// is off, this switch is off, a gesture is live, a correction is already running or the left button is
/// down. Past that it is pure arithmetic.
/// Accessibility is touched **only for a window that is actually oversized and has settled**, which
/// is a handful of times a day rather than ten times a second. There is no 60 Hz half to this poll:
/// nothing here has to be seen within a frame.
///
/// **What keeps it from fighting the user.**
/// - It stands down for every gesture this app owns (`isSuspended`), for Mission Control and for its
///   re-entry grace, exactly as the pill and the knob do. Every bullet here is about the **correction**;
///   the observation pass at the bottom of this comment stands down for none of them, because it lowers
///   a saved size rather than writing a window.
/// - It never acts while the **left button is down**: a window being dragged or live-resized is one
///   the user is holding, whatever its frame says.
/// - It waits for the frame to **stop changing**, and then for `settleDelay` on top: a zoom animates
///   for a couple of hundred milliseconds, and correcting a window mid-zoom would be correcting a
///   frame nobody chose. Any change of frame restarts that clock.
/// - It never reads Accessibility for a window `SteppingSnapEngine` is animating, and it posts
///   nothing while one of its own corrections is in flight — so no window it touches can have posts
///   in flight when it reads it.
/// - The correction goes through the engine like every other placement in the app: it animates, it is
///   written by `WindowWriter`, and a refusal raises the window's own floor (§6), never its application's row.
/// - An application that rounds its size to a grid (Terminal, to whole rows and columns) can land up
///   to half a cell over the gap. Such a landing is asked once more for a size that rounds to the cell
///   below (`OversizeCorrection.gridRetry`), so the window ends inside the gap rather than over it.
/// - A window that **refuses** to come back inside the area is asked once and then left alone until
///   its **size** changes again, so an application with a large minimum size is not fought once a
///   tenth of a second for ever — and moving it somewhere else does not send it back to the gap's edge.
///
/// It logs a corrected window, with the numbers, and a refusal. A sweep that finds nothing is silent.
///
/// # The other half: a window shows its saved size too high
///
/// `MinimumSizeStore` can hold a row that is too high for this Mac — a read taken before the
/// application settled, a built-in row measured on another configuration — and while a window is
/// stuck at or above that row nothing in a gesture can contradict it: the divider stops there, so the
/// window never gets small enough to show the row wrong. Without this pass the only escape is
/// Settings, which is the one place the user must never have to go for this.
///
/// This sweep already asks every window on screen how big it is, ten times a second, from the window
/// list alone. Asking *"and is it smaller than its saved size?"* in the same pass costs a dictionary
/// lookup per window and lowers the row **at the moment the user proves it too high** — resizing the
/// window by hand — rather than at the next press. It is why there is no second cadence for this.
///
/// **Only a held window may lower a row** (`MinimumSizeStore.observe(windowID:pid:size:)`): one an
/// Accessibility path has observed — pressed, dragged, parked or landed. CGWindowList cannot tell a
/// Save sheet or a Get Info panel from a main window, and a row lowered to a sheet's size would be
/// wrong for every main window afterwards. The store answers *held?* first, so the pass costs one
/// lookup for a window nobody has held.
///
/// **Neither preference gates it.** The gap and `correctOversizedWindows` govern whether this class
/// *corrects* a window; a user with the gap off still deserves a saved size that is true, so the
/// observation pass runs on every tick and the correction guards sit behind it. The only windows it
/// skips are the ones the engine is animating, whose intermediate frames nobody chose. It does not
/// stand down for `isSuspended` or for the left button either, and the button is the point: a window
/// the user is hand-resizing smaller is exactly the evidence being waited for. Nothing in it writes,
/// reads Accessibility or touches a window — it only lowers something the app believed.
@MainActor
final class OversizeWatcher {
    /// The one cadence this app polls at when nothing is live (`SpaceWatcher.idlePollInterval`).
    static let pollInterval: TimeInterval = 0.1
    /// How long a window has to have held one oversized frame before it is corrected. Covers the
    /// zoom animation and a title-bar double-click, and it is the grace a freshly zoomed window
    /// gets: half a second of being exactly what was asked for before this puts the gap back around
    /// it.
    static let settleDelay: TimeInterval = 0.5
    /// Slack on every comparison of two frames (`OversizeCorrection.tolerance`).
    static let tolerance = OversizeCorrection.tolerance

    private let ax: AccessibilityWindows
    private let engine: SteppingSnapEngine
    private let writer: WindowWriter
    private let screens: any ScreensProviding
    private let settingsStore: SettingsStore
    /// Where a saved size a window has shown too high is lowered. Governed by neither preference — see the type comment.
    private let minimums: MinimumSizeStore
    /// Whether some other feature owns the screen. The same question the handle bar and the junction
    /// knobs ask, asked here for the same reason: two features moving one window is one too many.
    private let isSuspended: @MainActor () -> Bool

    /// One oversized window, as of the last pass.
    private struct Seen {
        /// The frame it was last seen at. A different one restarts the clock.
        var frame: CGRect
        /// When it was first seen at that frame.
        var since: TimeInterval
    }

    private var timer: Timer?
    private var seen: [UInt32: Seen] = [:]
    /// Windows whose correction is in flight. While this is non-empty nothing is swept: the one thing
    /// this class must never do is read a window it is writing.
    private var correcting: Set<UInt32> = []
    /// What a window came back with after it was asked to shrink and would not. It is asked again only
    /// once it is at some other size — otherwise every pass would re-post the write it just refused.
    private var refused: [UInt32: CGRect] = [:]

    init(ax: AccessibilityWindows, engine: SteppingSnapEngine, writer: WindowWriter,
         screens: any ScreensProviding, settingsStore: SettingsStore, minimums: MinimumSizeStore,
         isSuspended: @escaping @MainActor () -> Bool) {
        self.ax = ax
        self.engine = engine
        self.writer = writer
        self.screens = screens
        self.settingsStore = settingsStore
        self.minimums = minimums
        self.isSuspended = isSuspended
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common`, so a menu tracking or a live resize does not stop the poll — those are exactly
        // the moments a window changes size.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        forget()
    }

    /// One pass. Internal rather than private so a probe can drive it without a run loop.
    func tick() {
        // One snapshot, two jobs — and the observation pass goes first because it is the one neither
        // preference governs. See the type comment.
        let windows = WindowList.snapshot()
        observe(windows)
        // Two preferences, read together: the gap is what there is to disagree with, and
        // `correctOversizedWindows` is whether this feature acts on the disagreement at all. Either
        // one off, nothing is oversized, and whatever was being waited on is forgotten so that
        // switching it back on starts the clock again rather than correcting on the next tick.
        guard settingsStore.settings.gapEnabled, settingsStore.settings.correctOversizedWindows else {
            forget()
            return
        }
        guard correcting.isEmpty, !isSuspended(), !HandleBarController.leftButtonIsDown() else { return }
        let displays = screens.displays
        guard !displays.isEmpty else { return }
        let gap = settingsStore.settings.gap
        let now = CACurrentMediaTime()
        var stillOversized: Set<UInt32> = []
        for window in windows {
            // The window's own display, by its centre. Nothing is corrected against a display the
            // window is merely near: `Screens.display(containing:)` falls back to the nearest one, and
            // a window off every display is one this feature has nothing to say about.
            guard let display = displays.first(where: { $0.frame.contains(window.frame.center) }) else { continue }
            // A native full-screen window fills the whole display, menu bar included. It is not
            // oversized, it is somewhere else, and resizing it would be the worst thing in this file.
            guard !fillsDisplay(window.frame, display.frame) else { continue }
            guard let wanted = OversizeCorrection.correction(for: window.frame, in: display.visibleFrame, gap: gap) else {
                continue
            }
            // A window the engine is moving is a window with posts in flight — not read, not written,
            // and not even remembered, because the frame it is passing through is not a frame anybody
            // chose.
            guard !engine.isAnimating(windowID: window.id) else { continue }
            stillOversized.insert(window.id)
            // Asked once and refused: left alone until it is at some other size. Moved is not resized.
            if let landed = refused[window.id], OversizeCorrection.sameSize(landed, window.frame) { continue }
            refused[window.id] = nil
            let entry = seen[window.id]
            if let entry, Self.sameFrame(entry.frame, window.frame) {
                guard now - entry.since >= Self.settleDelay else { continue }
                correct(window, to: wanted, display: display)
                // One window a pass: the sweep stands down until this correction has answered, and the
                // next pass sees the arrangement it left.
                return
            }
            seen[window.id] = Seen(frame: window.frame, since: now)
        }
        // A window that has stopped being oversized — or stopped being listed — takes its clock with it.
        seen = seen.filter { stillOversized.contains($0.key) }
        refused = refused.filter { stillOversized.contains($0.key) }
    }

    // MARK: - Lowering a saved size

    /// **A held window smaller than its saved size is the evidence that size cannot survive**, and this
    /// is where the app notices it on its own — at the moment it becomes true, rather than at the next
    /// press of a handle that would never have let it become true.
    ///
    /// Window id and pid only: `MinimumSizeStore.observe(windowID:pid:size:)` needs no `AXUIElement`,
    /// so this sweeps every window on screen at 10 Hz and makes no Accessibility call at all — which is
    /// also what makes it safe to run while another feature is mid-gesture.
    ///
    /// One line per saved size lowered, with the window's size and both numbers. There is no second
    /// line: the size is lowered, so the next pass finds nothing to say.
    private func observe(_ windows: [WindowInfo]) {
        for window in windows {
            // A window the engine is moving is passing through frames nobody chose, and an intermediate
            // one is not evidence of anything.
            guard !engine.isAnimating(windowID: window.id) else { continue }
            guard let seen = minimums.observe(windowID: window.id, pid: window.pid, size: window.frame.size),
                  seen.loweredSomething else { continue }
            MinimumProbe.logLowering(seen, window: window.id, size: window.frame.size, log: Logger.app)
        }
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func fillsDisplay(_ frame: CGRect, _ display: CGRect) -> Bool {
        frame.width >= display.width - Self.tolerance && frame.height >= display.height - Self.tolerance
    }

    // MARK: - The correction

    /// Through the same engine every other placement uses, with the app's `animationDuration`: a
    /// correction is a placement like any other, so it animates and it is written off the main
    /// thread.
    private func correct(_ window: WindowInfo, to wanted: CGRect, display: DisplayInfo) {
        guard let handle = ax.handle(forWindowID: window.id, pid: window.pid) else { return }
        // Asked before anything is written, and remembered as a refusal so that a window that cannot
        // be resized at all is asked once rather than on every pass.
        guard ax.isResizable(handle) else {
            refused[window.id] = window.frame
            seen[window.id] = nil
            return
        }
        // Belt to the braces above: nothing should have posts in flight here, and if something does,
        // this pass is not the moment to add to them.
        guard !writer.hasPending(handle) else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else { return }
        let area = display.visibleFrame
        correcting.insert(window.id)
        seen[window.id] = nil
        Logger.app.info("""
            window \(window.id, privacy: .public) (pid \(window.pid, privacy: .public)) is \
            \(window.frame.width, format: .fixed(precision: 0), privacy: .public)×\
            \(window.frame.height, format: .fixed(precision: 0), privacy: .public) on a \
            \(area.width, format: .fixed(precision: 0), privacy: .public)×\
            \(area.height, format: .fixed(precision: 0), privacy: .public) area; resizing it to \
            \(wanted.width, format: .fixed(precision: 0), privacy: .public)×\
            \(wanted.height, format: .fixed(precision: 0), privacy: .public) to keep the gap
            """)
        place(handle, window: window.id, from: window.frame, to: wanted, area: area, screen: screen, retry: true)
    }

    /// One write of a correction, and what its landing decides. A landing still oversized by no more
    /// than an application's rounding is asked once more for a size that rounds down
    /// (`OversizeCorrection.gridRetry`); anything else still oversized is a refusal.
    private func place(_ handle: WindowHandle, window: UInt32, from: CGRect, to wanted: CGRect, area: CGRect,
                       screen: NSScreen, retry: Bool) {
        engine.snap(handle, from: from, to: wanted, within: area,
                    duration: settingsStore.settings.animationDuration, on: screen, refusal: .anchorInward) { [weak self] landed in
            guard let self else { return }
            guard let landed else {
                self.correcting.remove(window)
                return
            }
            guard OversizeCorrection.correction(for: landed, in: area, gap: self.settingsStore.settings.gap) != nil else {
                self.correcting.remove(window)
                return
            }
            if retry, let smaller = OversizeCorrection.gridRetry(asked: wanted, landed: landed) {
                Logger.app.info("""
                    window \(window, privacy: .public) rounded \
                    \(wanted.width, format: .fixed(precision: 0), privacy: .public)×\
                    \(wanted.height, format: .fixed(precision: 0), privacy: .public) up to \
                    \(landed.width, format: .fixed(precision: 0), privacy: .public)×\
                    \(landed.height, format: .fixed(precision: 0), privacy: .public); asking for \
                    \(smaller.width, format: .fixed(precision: 0), privacy: .public)×\
                    \(smaller.height, format: .fixed(precision: 0), privacy: .public) so it rounds inside the gap
                    """)
                self.place(handle, window: window, from: landed, to: smaller, area: area, screen: screen, retry: false)
                return
            }
            self.correcting.remove(window)
            self.refused[window] = landed
            Logger.app.info("""
                window \(window, privacy: .public) would not come inside the working area: it took \
                \(landed.width, format: .fixed(precision: 0), privacy: .public)×\
                \(landed.height, format: .fixed(precision: 0), privacy: .public); left as it is until it is resized
                """)
        }
    }

    private func forget() {
        seen = [:]
        refused = [:]
    }
}
