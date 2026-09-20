import CoreGraphics
import Foundation

/// Why a live gesture or phase was taken off the user's screen by the system rather than ended by the
/// user. Every surface goes on either one — the zone preview, the snap bar, a Snap Assist selection,
/// the pills and the knobs — and so does the state behind it, with the single exception named by
/// `DragResumption`: a drag still held through a Space change is suspended rather than ended.
///
/// Every overlay panel is `.moveToActiveSpace`, so a surface left behind stays with the Space it was
/// shown on rather than following the user to one where the windows it describes are not. What does
/// not end itself is the state behind it: a Snap Assist phase holds real windows parked off-screen
/// until *something* ends it, so a phase abandoned on another Space strands them.
public enum SpaceInterruption: String, Sendable, CaseIterable {
    /// The active Space changed: another desktop, or a full-screen app entered or left.
    /// `NSWorkspace.activeSpaceDidChangeNotification` is exactly this and nothing else.
    case spaceChange
    /// Mission Control, App Exposé or the Spaces bar took the screen without changing Space.
    /// Nothing notifies; `MissionControlDetector` says what is observable instead.
    case missionControl
}

/// One on-screen window as CGWindowList describes it, reduced to the three facts this question needs.
/// Deliberately not `WindowInfo`: that one is the app's model of a *user's* window — layer 0, regular
/// applications, big enough to snap — and every window this type is about fails all three tests.
public struct SystemWindow: Hashable, Sendable {
    public var ownerPID: Int32
    /// The window level. Ordinary application windows are 0; the system's own surfaces are above it.
    public var layer: Int
    /// Bounds in CG space (origin top-left of the primary display, y down), as CGWindowList gives them.
    public var frame: CGRect

    public init(ownerPID: Int32, layer: Int, frame: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.frame = frame
    }
}

/// Mission Control and App Exposé, recognised from the window list because **nothing else can see
/// them**.
///
/// Measured on this Mac (macOS 26) with every candidate observer registered at once — `NSWorkspace`'s
/// notification centre with a nil name, eleven named distributed notifications, an `AXObserver` on the
/// WindowManager and Dock processes, `NSWindow.occlusionState` on a probe panel joining every Space,
/// and a 20 Hz poll of the frontmost application. Entering Mission Control fires **not one of them**:
/// no workspace notification, no distributed notification, no AX notification, no occlusion change on
/// the all-Spaces probe panel, no change of frontmost application. (A Space change, by contrast, fires
/// `NSWorkspaceActiveSpaceDidChangeNotification` and is left to it.)
///
/// What does change is the window list, and only there: the WindowManager process puts up a backdrop
/// the size of the whole display above layer 0, plus the Spaces bar and one thumbnail per Space.
/// Measured signatures, all with `kCGWindowLayer > 0` and owner `com.apple.WindowManager`:
///
/// - Mission Control: a 1512×982 backdrop at layer 19, a 1512×244 Spaces bar at layer 14, and five
///   169×129 thumbnails at layer 15.
/// - App Exposé: the same 1512×982 backdrop at layer 19 and nothing else above layer 0.
/// - Idle desktop, and the whole of a Space change: nothing above layer 0 at all.
///
/// **The rule is the full-display backdrop, not merely "WindowManager is drawing".** The narrower
/// test is what keeps a legitimate gesture safe: a drag to the very top edge can reveal the Spaces
/// bar on its own, and the top edge is also this app's maximize zone — recognising the strip would
/// cancel the user's maximize. The backdrop covers a display; the strip covers a quarter of one.
///
/// Stage Manager's strip is owned by the same process and is *not* a false positive: it sits at a
/// large negative layer, below the `layer > 0` line. Nor is another application's full-screen window,
/// however high it sits — the owner is tested first.
public enum MissionControlDetector {
    /// How much of a display the surface has to cover to count as its backdrop. The measured backdrop
    /// covers it exactly; the margin is for a display whose bounds and window bounds disagree by a
    /// point, not an invitation to match something smaller.
    public static let coverage: Double = 0.9

    /// The surface that shows Mission Control or App Exposé, with the index of the display it covers,
    /// or nil when `windows` show neither.
    ///
    /// - Parameters:
    ///   - windows: every on-screen window, in any order. Layer-0 windows may be included; they are
    ///     what this is defined against, so filtering them out first is the caller's option, never a
    ///     requirement.
    ///   - windowManagerPID: the WindowManager process. Passed in rather than found by owner *name*:
    ///     CGWindowList's owner names are localized — the wallpaper agent comes back as "Fond
    ///     d'écran" on this Mac — so a name comparison would work in one language and fail silently in
    ///     the next.
    ///   - displays: display frames in CG space.
    public static func backdrop(in windows: [SystemWindow], windowManagerPID: Int32,
                                displays: [CGRect]) -> (window: SystemWindow, display: Int)? {
        for window in windows where window.ownerPID == windowManagerPID && window.layer > 0 {
            if let index = displays.firstIndex(where: { covers($0, window.frame) }) {
                return (window, index)
            }
        }
        return nil
    }

    /// Whether `window` covers `display` — at least `coverage` of its width *and* of its height, which
    /// a strip across the top of a display never does however wide it is.
    public static func covers(_ display: CGRect, _ window: CGRect) -> Bool {
        guard display.width > 0, display.height > 0 else { return false }
        let overlap = window.intersection(display)
        guard !overlap.isNull else { return false }
        return overlap.width >= display.width * coverage && overlap.height >= display.height * coverage
    }
}

/// Whether a Space is sliding, read from where a **Space-bound** 1 × 1 sentinel panel is listed.
///
/// Measured: a sentinel at a display's horizontal edge goes occluded **27–53 ms** after the slide
/// starts (the trailing edge at 439–472 ms) against 972–1007 ms for
/// `activeSpaceDidChangeNotification`. Occlusion on its own is not the answer, though — a menu, a
/// full-screen surface or another window covering that one point occludes it too, and cancelling a
/// live gesture for a menu would be worse than waiting for the notification.
///
/// **A slide displaces the sentinel in the window list; a covering window does not.** That single
/// `CGWindowListCopyWindowInfo` read, taken in the same turn as the occlusion notification, is the
/// confirmation — and it is the whole of the difference between the two cases. A sentinel that has
/// left the list entirely counts as displaced: the Space it belongs to is no longer the one on screen.
public enum SpaceSlideDetector {
    /// True when the sentinel is not where it was placed.
    ///
    /// - Parameters:
    ///   - sentinelID: the sentinel panel's window number.
    ///   - placed: the frame the sentinel was given, in whichever space the caller reads `listed` in
    ///     (CG space in this app — the window list's own).
    ///   - listed: every on-screen window's id and bounds, in any order.
    ///   - tolerance: how far the listed origin may differ from `placed` on either axis and still
    ///     count as where it was put. Half a point: the sentinel never moves of its own accord, so
    ///     this is for a rounding disagreement between AppKit and the window server and nothing else.
    public static func isSliding(sentinelID: UInt32, placed: CGRect,
                                 listed: [(id: UInt32, frame: CGRect)],
                                 tolerance: Double = 0.5) -> Bool {
        guard let found = listed.first(where: { $0.id == sentinelID }) else { return true }
        return abs(Double(found.frame.origin.x) - Double(placed.origin.x)) > tolerance
            || abs(Double(found.frame.origin.y) - Double(placed.origin.y)) > tolerance
    }
}

/// One interruption per Mission Control, not one per poll.
///
/// The detector answers a question about *now*, and the poll asks it ten times a second; without a
/// memory, a phase would be ended again on every pass for as long as Mission Control stayed up — and
/// each of those calls is a restore pass with Accessibility writes in it.
///
/// `isShowing` is also read as a level, by the features that have to stand down for as long as
/// Mission Control is up rather than be cancelled once, so the poll that feeds this must keep running
/// for as long as it is true — see `SpaceWatcher.tick`. `forget()` is for the watcher that stops
/// looking: what it last saw must not go on standing those features down.
public struct MissionControlGate: Sendable, Equatable {
    /// How long after Mission Control leaves before a pill or a knob may be offered again. Measured:
    /// the backdrop is gone 332 ms after the exit keystroke and the Spaces bar at 466, but the windows
    /// are still *growing back* for about 300 ms after that. A pill
    /// offered inside that window is drawn between two windows that are still moving, at a gap that is
    /// about to stop existing. The grace is a floor on when the next poll may re-offer, not a delay
    /// added to anything the user did.
    public static let reofferGrace: TimeInterval = 0.15

    public private(set) var isShowing: Bool
    /// When `isShowing` last fell, in the caller's clock. Nil until it has fallen once: SnapCore holds
    /// no clock of its own, so "never" cannot be written as a time.
    private var fellAt: TimeInterval?

    public init(isShowing: Bool = false) {
        self.isShowing = isShowing
    }

    /// Records this reading and returns true only on the rising edge — the pass that first sees it.
    /// `now` is the caller's clock (`CACurrentMediaTime()` in the app); SnapCore takes none. It is
    /// kept on the falling edge so `isInGrace` has something to measure from.
    public mutating func update(showing: Bool, now: TimeInterval) -> Bool {
        let wasShowing = isShowing
        isShowing = showing
        if wasShowing && !showing { fellAt = now }
        return showing && !wasShowing
    }

    /// True from the falling edge until `reofferGrace` later. Features that re-offer on a poll wait
    /// on it. False for a gate that has never seen Mission Control go down.
    public func isInGrace(now: TimeInterval) -> Bool {
        guard let fellAt else { return false }
        return now - fellAt < Self.reofferGrace
    }

    /// Re-arms the gate, so the next `update(showing: true, …)` is a rising edge again. The grace goes with it: a
    /// watcher that has stopped looking must not hold the handle bar down for a Mission Control it can
    /// no longer see leave.
    public mutating func forget() {
        isShowing = false
        fellAt = nil
    }
}

/// When a drag the user never let go of may come back after the Space slid out from under it.
///
/// A Space change is the **one** interruption a gesture survives, and it survives because macOS made
/// it: holding a dragged window against a side edge switches Space and carries the window along, with
/// the button still down. The drag that arrives on the new Space is the same drag, so it is resumed
/// rather than ended — every other interruption, Mission Control included, still ends it outright.
///
/// Two facts have to hold first, and each answers a different way of getting it wrong.
///
/// - **The slide has to be over.** The Space change is caught 27–53 ms in (`SpaceSlideDetector`) but
///   the slide runs for about 450 ms more, and the window list read the resumption depends on would
///   describe the Space being *left*. A drag resumed against those windows arranges around neighbours
///   that are not on screen.
/// - **The pointer has to have moved.** It is resting against the edge that triggered the slide, so
///   resuming where it stands lights that edge's zone the instant the new Space appears — under a hand
///   that was holding still to switch Spaces, not aiming at anything.
public enum DragResumption {
    /// How far the pointer has come from where the interruption found it.
    public static func travel(from origin: CGPoint, to pointer: CGPoint) -> Double {
        hypot(Double(pointer.x - origin.x), Double(pointer.y - origin.y))
    }

    /// Whether the suspended drag comes back on this event.
    ///
    /// - Parameters:
    ///   - elapsed: seconds since the interruption was detected, in the caller's clock
    ///     (`CACurrentMediaTime()` in the app). SnapCore holds no clock of its own.
    ///   - travel: how far the pointer has moved since, from `travel(from:to:)`.
    public static func mayResume(elapsed: TimeInterval, travel: Double,
                                 settle: TimeInterval = Settings.Fixed.dragResumeSettle,
                                 minimumTravel: Double = Settings.Fixed.dragResumeTravel) -> Bool {
        elapsed >= settle && travel >= minimumTravel
    }
}
