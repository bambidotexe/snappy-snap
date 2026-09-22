import Foundation

/// The rules that turn what was found into a level. Every page that reports one of these states reads it
/// from here, so the System page's permission row and the Health page's agree, and so do the System page's
/// tiling rows and the Health page's.
///
/// **What red is for.** SnappySnap's job is to snap a window the user drags, through Accessibility. Red
/// is reserved for what stops that: the Accessibility permission denied, the drag detection down. Every
/// other thing that is not as it should be is orange, because windows still snap.
public enum HealthRules {
    /// A macOS permission, or a setup the welcome window asks for: green while it is in place; missing,
    /// **red when the welcome window marks it required** (Accessibility: without it no window moves) and
    /// orange otherwise (Notifications: only the update announcement needs it). Never blue.
    public static func grant(held: Bool, required: Bool) -> HealthLevel {
        if held { return .good }
        return required ? .failure : .warning
    }

    /// macOS's own drag tiling ("Drag windows to left or right edge of screen to tile", "Drag windows to
    /// menu bar to fill screen"). On, macOS and SnappySnap both grab the same drag: orange, never red,
    /// because SnappySnap still snaps.
    public static func edgeTiling(conflicts: Bool) -> HealthLevel {
        conflicts ? .warning : .good
    }

    /// macOS's "Tiled windows have margins", which must say what the gap switch says: macOS applies its
    /// margins to the placements SnappySnap does not own, a title bar double-clicked or the green button's
    /// tiling menu, so the two agree when both leave a gap or neither does.
    public static func margins(on: Bool, gapOn: Bool) -> HealthLevel {
        on == gapOn ? .good : .warning
    }

    /// macOS's "Hold ⌥ key while dragging windows to tile". It fights SnappySnap only while the halves
    /// held under ⌥ Option are switched on: both then answer the same key during the same drag. With
    /// them off, holding ⌥ Option means nothing to SnappySnap and the switch is harmless.
    public static func optionTiling(on: Bool, optionHalvesOn: Bool) -> HealthLevel {
        on && optionHalvesOn ? .warning : .good
    }

    /// The drag detection: what every snap starts from. No row at all while the app is still waiting for
    /// the Accessibility permission (the permission's own row is the red one, and the detection starts the
    /// moment it arrives); red once it has failed to start or macOS has switched it off for good.
    public static func dragDetection(_ engine: EngineState) -> HealthLevel? {
        switch engine {
        case .waiting: nil
        case .failed: .failure
        case .running(let facts): facts.listening ? .good : .failure
        }
    }

    /// A drag made with fn held is a window move macOS runs itself; SnappySnap hears its press only from
    /// the second listener. Without it those drags are not snapped and every other one is.
    public static func fnDrags(heard: Bool) -> HealthLevel {
        heard ? .good : .warning
    }

    /// How often macOS paused the drag detection since launch. A pause for answering too slowly is this
    /// app's own fault and a drag may have been missed: orange. A pause macOS makes for its own reasons (a
    /// password field taking the keyboard) is nobody's fault and nothing to fix: fine.
    public static func pauses(slow: Int, byMacOS: Int) -> HealthLevel {
        slow > 0 ? .warning : .good
    }

    /// Whether Space changes and Mission Control are followed. Without it a gesture is not stood down when
    /// the screen changes under it, and windows parked by Snap Assist can be stranded.
    public static func spaces(watched: Bool) -> HealthLevel {
        watched ? .good : .warning
    }

    /// Windows Snap Assist moved into its deck and could not put back. Each one sits in a corner of the
    /// screen with nothing to click, until the next launch tries again. A record of them that could not be
    /// read at launch is the same thing with no next try: orange too.
    public static func stranded(_ count: Int, recordReadable: Bool = true) -> HealthLevel {
        count == 0 && recordReadable ? .good : .warning
    }

    /// One thing the hidden parts of macOS buy, on this Mac. Missing sends it down its public route: it
    /// still works, a little less exactly.
    public static func hiddenFeature(available: Bool) -> HealthLevel {
        available ? .good : .warning
    }
}

extension HealthRules {
    /// Whether a file in `~/Library/Logs/DiagnosticReports` is a crash report of the process named
    /// `process`: the name, a dash, the date the system stamps (`SnappySnap-2026-09-21-101010.ips`), and the
    /// extension of a crash report old or new. A user fault of the same process (`ExcUserFault_…`), or
    /// another process whose name merely starts the same way, is not.
    public static func isCrashReport(fileName: String, process: String) -> Bool {
        guard fileName.hasPrefix(process + "-"), fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash")
        else { return false }
        let stamp = fileName.dropFirst(process.count + 1)
        // yyyy-MM-dd-HHmmss, digits where the date's digits go.
        let pattern = Array("0000-00-00-000000")
        guard stamp.count > pattern.count else { return false }
        return zip(stamp, pattern).allSatisfy { char, slot in slot == "-" ? char == "-" : char.isASCII && char.isNumber }
    }
}

/// Where the drag detection is. It is started once, the moment the Accessibility permission is there, and
/// never retried: a start that fails leaves the app inert until it is opened again.
public enum EngineState: Equatable, Sendable {
    /// Not started yet: the Accessibility permission has not arrived.
    case waiting
    /// Started, with what each part of it reports now.
    case running(EngineFacts)
    /// The permission arrived and the drag detection could not be started.
    case failed
}

/// What the running drag detection says about itself, as plain values.
public struct EngineFacts: Equatable, Sendable {
    /// The listener every drag comes through exists and macOS has it switched on.
    public var listening: Bool
    /// The second listener, which hears the press of a drag made with fn held, could be started.
    public var hearsFnDrags: Bool
    /// How many times since launch macOS paused the listener because the app answered too slowly.
    public var pausedForSlowness: Int
    /// How many times since launch macOS paused it for reasons of its own.
    public var pausedByMacOS: Int
    /// Space changes and Mission Control are being watched.
    public var watchingSpaces: Bool

    public init(listening: Bool, hearsFnDrags: Bool, pausedForSlowness: Int, pausedByMacOS: Int,
                watchingSpaces: Bool) {
        self.listening = listening
        self.hearsFnDrags = hearsFnDrags
        self.pausedForSlowness = pausedForSlowness
        self.pausedByMacOS = pausedByMacOS
        self.watchingSpaces = watchingSpaces
    }
}

/// What macOS says about the notification permission.
public enum NotificationGrant: Equatable, Sendable {
    case granted
    /// Refused, or switched off in System Settings › Notifications.
    case denied
    /// Never asked: the welcome window's Allow button has not been pressed.
    case notAsked
}
