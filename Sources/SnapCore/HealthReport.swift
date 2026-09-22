import Foundation

/// Everything the Health page reports, as values. The app gathers them (`SystemAdapters` reads the
/// system, the app reads its own state); this type turns them into the page's two tables, so what a fact
/// reads as, in which colour and with which sentence, is decided here and tested.
///
/// Every property starts at what a healthy app reports, so a test states only what it changes.
public struct HealthFacts: Equatable, Sendable {
    // Permissions, read on the Settings window's 2 s poll.
    public var accessibilityGranted = true
    public var notifications: NotificationGrant = .granted

    // macOS's own tiling, read on the same poll, and the setting of the app's own it is judged against.
    /// "Drag windows to left or right edge of screen to tile" or "Drag windows to menu bar to fill screen".
    public var edgeTilingOn = false
    /// "Hold ⌥ key while dragging windows to tile".
    public var optionTilingOn = false
    /// The halves held under ⌥ Option.
    public var optionHalvesOn = false

    // Snapping.
    public var engine: EngineState = .running(EngineFacts(listening: true, hearsFnDrags: true,
                                                          pausedForSlowness: 0, pausedByMacOS: 0,
                                                          watchingSpaces: true))
    /// When the last window was placed by a snap this launch, nil before the first.
    public var lastSnap: Date?
    /// Windows still exactly where a snap left them.
    public var snappedWindows = 0
    /// Windows Snap Assist could not put back.
    public var strandedWindows = 0
    /// False when the record of windows an earlier run parked could not be read at launch.
    public var parkedRecordReadable = true

    /// When each crash report of this app in the last `Settings.Fixed.healthCrashWindow` was written,
    /// newest first.
    public var recentCrashes: [Date] = []

    /// When these facts were read. `SnapCore` reads no clock, so the moment is handed in with the rest.
    public var now = Date(timeIntervalSince1970: 0)

    public init() {}
}

/// The Health page's two tables: the checks, green, orange or red, and the readings, blue.
///
/// **A check is something that has to be in place or running for windows to snap**: the two permissions,
/// the drag detection and its parts, and what stops it doing its job (macOS's tiling grabbing the same
/// drag, a window Snap Assist could not put back). A preference is never a check, whichever way it is set
/// (the gap, the handles, the custom areas, the hidden macOS features, Launch at login), and neither is a
/// reading. The skill `macos-building-settings-pages` (*The Health page*) holds the rules.
///
/// Accessibility, Notifications and the drag detection are always lines; every other check is a line only
/// while it is wrong, because it has nothing to say while it is fine.
public enum HealthReport {
    /// The Health table, in page order.
    public static func checks(for f: HealthFacts) -> [HealthRow] {
        let w = HealthWords.self
        let notificationsHeld = f.notifications == .granted
        var rows = [
            HealthRow(id: "accessibility", label: w.accessibilityLabel,
                      level: HealthRules.grant(held: f.accessibilityGranted, required: true),
                      word: f.accessibilityGranted ? w.granted : w.denied, fix: w.accessibilityFix),
            HealthRow(id: "notifications", label: w.notificationsLabel,
                      level: HealthRules.grant(held: notificationsHeld, required: false),
                      word: notificationsHeld ? w.granted : w.denied,
                      fix: f.notifications == .notAsked ? w.notificationsNotAskedFix : w.notificationsDeniedFix),
        ]

        // The detection's own lines only once it has been started, or has failed to: while the permission
        // is still missing, that permission's line is the one thing to fix.
        if let level = HealthRules.dragDetection(f.engine) {
            rows.append(HealthRow(id: "drag detection", label: w.dragDetectionLabel, level: level,
                                  word: level == .good ? w.enabled : w.failed, fix: w.dragDetectionFix))
        }
        if case .running(let engine) = f.engine {
            if HealthRules.fnDrags(heard: engine.hearsFnDrags) >= .warning {
                rows.append(HealthRow(id: "fn drags", label: w.fnDragsLabel, level: .warning, word: w.failed,
                                      fix: w.fnDragsFix))
            }
            let pauses = HealthRules.pauses(slow: engine.pausedForSlowness, byMacOS: engine.pausedByMacOS)
            if pauses >= .warning {
                rows.append(HealthRow(id: "pauses", label: w.pausesLabel, level: pauses,
                                      word: "\(engine.pausedForSlowness + engine.pausedByMacOS)",
                                      detail: w.pausesDetail(slow: engine.pausedForSlowness,
                                                             byMacOS: engine.pausedByMacOS),
                                      fix: w.pausesFix))
            }
            if HealthRules.spaces(watched: engine.watchingSpaces) >= .warning {
                rows.append(HealthRow(id: "spaces", label: w.spacesLabel, level: .warning, word: w.failed,
                                      fix: w.spacesFix))
            }
        }

        // One line for macOS's tiling, whichever of its switches fights the drag, with a sentence for each.
        let edge = HealthRules.edgeTiling(conflicts: f.edgeTilingOn)
        let option = HealthRules.optionTiling(on: f.optionTilingOn, optionHalvesOn: f.optionHalvesOn)
        if max(edge, option) >= .warning {
            let fixes = [edge >= .warning ? w.edgeTilingFix : nil, option >= .warning ? w.optionTilingFix : nil]
            rows.append(HealthRow(id: "macos tiling", label: w.tilingTitle, level: max(edge, option),
                                  word: w.enabled, fix: fixes.compactMap { $0 }.joined(separator: " ")))
        }

        let stranded = HealthRules.stranded(f.strandedWindows, recordReadable: f.parkedRecordReadable)
        if stranded >= .warning {
            rows.append(HealthRow(id: "stranded", label: w.strandedLabel, level: stranded,
                                  word: f.parkedRecordReadable ? "\(f.strandedWindows)" : w.invalid,
                                  fix: f.parkedRecordReadable ? w.strandedFix : w.parkedRecordFix))
        }

        if let last = f.recentCrashes.first {
            rows.append(HealthRow(id: "crashes",
                                  label: w.crashesLabel(days: Int(Settings.Fixed.healthCrashWindow / 86_400)),
                                  level: .warning, word: "\(f.recentCrashes.count)",
                                  detail: w.lastCrash(stamp(last)), fix: w.crashesFix))
        }
        return rows
    }

    /// The Information table, in page order: when a window last snapped, and how many still sit where a
    /// snap left them.
    public static func readings(for f: HealthFacts) -> [InfoRow] {
        let w = HealthWords.self
        return [
            InfoRow(id: "last snap", label: w.lastSnapLabel,
                    value: f.lastSnap.map { w.ago(seconds: f.now.timeIntervalSince($0)) } ?? w.noneYet,
                    detail: f.lastSnap.map(stamp)),
            InfoRow(id: "snapped windows", label: w.snappedWindowsLabel, value: "\(f.snappedWindows)"),
        ]
    }

    /// A moment as a tooltip wants it: the same in every language, sortable, to the minute, in the Mac's own
    /// time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
