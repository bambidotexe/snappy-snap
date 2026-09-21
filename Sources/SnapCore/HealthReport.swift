import CoreGraphics
import Foundation

/// Everything the Health page reports, as values. The app gathers them (`SystemAdapters` reads the
/// system, the app reads its own state); this type turns them into the page's groups, so what a fact
/// reads as, in which colour and with which sentence, is decided here and tested.
///
/// Every property starts at what a healthy app reports, so a test states only what it changes.
public struct HealthFacts: Equatable, Sendable {
    // Permissions, read on the Settings window's 2 s poll.
    public var accessibilityGranted = true
    public var notifications: NotificationGrant = .granted

    // macOS's own tiling, read on the same poll, and the two settings it is judged against.
    /// "Drag windows to left or right edge of screen to tile" or "Drag windows to menu bar to fill screen".
    public var edgeTilingOn = false
    /// "Tiled windows have margins".
    public var marginsOn = true
    /// "Hold ⌥ key while dragging windows to tile".
    public var optionTilingOn = false
    public var gapOn = true
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

    // Handles.
    public var handlesOn = true
    /// Dividers between two windows where a handle would be offered right now.
    public var handlePlaces = 0
    public var windowSizes = WindowSizesFact(readable: true, builtIn: 0, measured: 0, edited: 0)

    // Custom areas.
    public var customAreasOn = true
    public var customAreas: CustomAreasFact = .valid(areas: 0)

    // Compatibility.
    public var macOSVersion = ""
    /// macOS's own long description of itself, with its build: the row's tooltip.
    public var macOSDetail: String?
    public var hiddenFeaturesOn = true
    public var hiddenFeatures: [HiddenFeatureFact] = []
    public var snapBarOn = true
    public var snapBarAppearance: SnapBarAppearance = .notch
    public var displays: [DisplayFact] = []

    // The app itself.
    public var loginItem: LoginItemState = .disabled
    /// How long this process has been running, nil when the system would not say.
    public var runningSeconds: TimeInterval?
    /// The memory this process holds, as Activity Monitor counts it; nil when the system would not say.
    public var memoryBytes: UInt64?
    /// When each crash report of this app in the last `Settings.Fixed.healthCrashWindow` was written,
    /// newest first.
    public var recentCrashes: [Date] = []
    public var location: AppLocation = .applications
    /// Where the running bundle is, for the location row's tooltip and the report.
    public var bundlePath = ""

    /// When these facts were read. `SnapCore` reads no clock, so the moment is handed in with the rest.
    public var now = Date(timeIntervalSince1970: 0)

    public init() {}
}

/// The saved list of window sizes, as the Handles page's Apps list shows it.
public struct WindowSizesFact: Equatable, Sendable {
    /// False when a saved list was there and could not be read, so the built-in one stands in for it.
    public var readable: Bool
    public var builtIn: Int
    public var measured: Int
    public var edited: Int

    public init(readable: Bool, builtIn: Int, measured: Int, edited: Int) {
        self.readable = readable
        self.builtIn = builtIn
        self.measured = measured
        self.edited = edited
    }
}

/// What the custom areas' text comes to, as Verify would say it.
public enum CustomAreasFact: Equatable, Sendable {
    case valid(areas: Int)
    /// The sentence naming what failed.
    case invalid(String)
}

/// One thing the hidden parts of macOS buy, on this Mac.
public struct HiddenFeatureFact: Equatable, Sendable {
    public var id: String
    /// Its line's title, as the System page shows it.
    public var title: String
    public var available: Bool
    /// The symbols behind it, and whether each was found: what a bug report is read from.
    public var detail: String

    public init(id: String, title: String, available: Bool, detail: String) {
        self.id = id
        self.title = title
        self.available = available
        self.detail = detail
    }
}

/// One attached display, as the snap bar sees it.
public struct DisplayFact: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var isBuiltIn: Bool
    /// The display's frame, in points.
    public var size: CGSize
    /// The camera housing's size, nil on a display without one.
    public var housing: CGSize?

    public init(id: UInt32, name: String, isBuiltIn: Bool, size: CGSize, housing: CGSize?) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.size = size
        self.housing = housing
    }
}

/// The Health page's groups, and the text Copy Report puts on the clipboard.
public enum HealthReport {
    /// The groups under the overview, in page order: what the app needs from macOS first, the way the
    /// System page and the welcome window order it, then one group per subject of the app's own in the
    /// order of their pages, then compatibility, then the app itself.
    public static func groups(for facts: HealthFacts) -> [HealthGroup] {
        [permissions(facts), tiling(facts), snapping(facts), handles(facts), customAreas(facts),
         compatibility(facts), app(facts)]
    }

    static func permissions(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        let notificationsHeld = f.notifications == .granted
        return HealthGroup(id: "permissions", title: w.permissionsTitle, rows: [
            HealthRow(id: "accessibility", label: w.accessibilityLabel,
                      level: HealthRules.grant(held: f.accessibilityGranted, required: true),
                      word: f.accessibilityGranted ? w.granted : w.denied, fix: w.accessibilityFix),
            HealthRow(id: "notifications", label: w.notificationsLabel,
                      level: HealthRules.grant(held: notificationsHeld, required: false),
                      word: notificationsHeld ? w.granted : w.denied,
                      fix: f.notifications == .notAsked ? w.notificationsNotAskedFix : w.notificationsDeniedFix),
        ])
    }

    static func tiling(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        return HealthGroup(id: "tiling", title: w.tilingTitle, rows: [
            HealthRow(id: "edge tiling", label: w.edgeTilingLabel,
                      level: HealthRules.edgeTiling(conflicts: f.edgeTilingOn),
                      word: f.edgeTilingOn ? w.enabled : w.disabled, fix: w.edgeTilingFix),
            HealthRow(id: "margins", label: w.marginsLabel,
                      level: HealthRules.margins(on: f.marginsOn, gapOn: f.gapOn),
                      word: f.marginsOn ? w.enabled : w.disabled, fix: w.marginsFix(gapOn: f.gapOn)),
            HealthRow(id: "option tiling", label: w.optionTilingLabel,
                      level: HealthRules.optionTiling(on: f.optionTilingOn, optionHalvesOn: f.optionHalvesOn),
                      word: f.optionTilingOn ? w.enabled : w.disabled, fix: w.optionTilingFix),
        ])
    }

    static func snapping(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        var rows: [HealthRow] = []
        // The detection's own rows only once it has been started, or has failed to: while the permission
        // is still missing, that permission's row is the one thing to fix.
        if let level = HealthRules.dragDetection(f.engine) {
            rows.append(HealthRow(id: "drag detection", label: w.dragDetectionLabel, level: level,
                                  word: level == .good ? w.enabled : w.failed, fix: w.dragDetectionFix))
        }
        if case .running(let engine) = f.engine {
            rows.append(HealthRow(id: "fn drags", label: w.fnDragsLabel,
                                  level: HealthRules.fnDrags(heard: engine.hearsFnDrags),
                                  word: engine.hearsFnDrags ? w.enabled : w.failed, fix: w.fnDragsFix))
            let pauses = engine.pausedForSlowness + engine.pausedByMacOS
            rows.append(HealthRow(id: "pauses", label: w.pausesLabel,
                                  level: HealthRules.pauses(slow: engine.pausedForSlowness,
                                                            byMacOS: engine.pausedByMacOS),
                                  word: pauses == 0 ? w.never : "\(pauses)",
                                  detail: pauses == 0 ? nil : w.pausesDetail(slow: engine.pausedForSlowness,
                                                                              byMacOS: engine.pausedByMacOS),
                                  fix: w.pausesFix))
            rows.append(HealthRow(id: "spaces", label: w.spacesLabel,
                                  level: HealthRules.spaces(watched: engine.watchingSpaces),
                                  word: engine.watchingSpaces ? w.enabled : w.failed, fix: w.spacesFix))
        }
        rows.append(HealthRow(id: "last snap", label: w.lastSnapLabel, level: .info,
                              word: f.lastSnap.map { w.ago(seconds: f.now.timeIntervalSince($0)) } ?? w.noneYet,
                              detail: f.lastSnap.map(stamp)))
        rows.append(HealthRow(id: "snapped windows", label: w.snappedWindowsLabel, level: .info,
                              word: "\(f.snappedWindows)"))
        rows.append(HealthRow(id: "stranded", label: w.strandedLabel,
                              level: HealthRules.stranded(f.strandedWindows, recordReadable: f.parkedRecordReadable),
                              word: f.parkedRecordReadable ? "\(f.strandedWindows)" : w.invalid,
                              fix: f.parkedRecordReadable ? w.strandedFix : w.parkedRecordFix))
        return HealthGroup(id: "snapping", title: w.snappingTitle, rows: rows)
    }

    static func handles(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        let sizes = f.windowSizes
        let apps = sizes.builtIn + sizes.measured + sizes.edited
        return HealthGroup(id: "handles", title: w.handlesTitle, rows: [
            HealthRow(id: "handle places", label: w.handlePlacesLabel, level: .info,
                      word: f.handlesOn ? "\(f.handlePlaces)" : w.disabled),
            HealthRow(id: "window sizes", label: w.windowSizesLabel,
                      level: HealthRules.windowSizes(readable: sizes.readable),
                      word: sizes.readable ? w.apps(apps) : w.invalid,
                      detail: w.windowSizesDetail(builtIn: sizes.builtIn, measured: sizes.measured,
                                                  edited: sizes.edited),
                      fix: w.windowSizesFix),
        ])
    }

    static func customAreas(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        let row: HealthRow
        switch (f.customAreasOn, f.customAreas) {
        case (false, _):
            row = HealthRow(id: "custom areas", label: w.customAreasLabel,
                            level: HealthRules.customAreas(enabled: false, valid: true), word: w.disabled)
        case (true, .valid(let areas)):
            row = HealthRow(id: "custom areas", label: w.customAreasLabel,
                            level: HealthRules.customAreas(enabled: true, valid: true), word: w.valid,
                            detail: w.areas(areas))
        case (true, .invalid(let problem)):
            row = HealthRow(id: "custom areas", label: w.customAreasLabel,
                            level: HealthRules.customAreas(enabled: true, valid: false), word: w.invalid,
                            detail: problem, fix: w.customAreasFix)
        }
        return HealthGroup(id: "custom areas", title: w.customAreasTitle, rows: [row])
    }

    static func compatibility(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        var rows: [HealthRow] = [
            HealthRow(id: "macos", label: "macOS", level: .info, word: f.macOSVersion, detail: f.macOSDetail),
            HealthRow(id: "hidden features", label: w.hiddenFeaturesLabel,
                      level: HealthRules.hiddenFeatures(on: f.hiddenFeaturesOn),
                      word: f.hiddenFeaturesOn ? w.enabled : w.disabled),
        ]
        // Each line reports the Mac, not the switch, exactly as the System page's lines do.
        for feature in f.hiddenFeatures {
            rows.append(HealthRow(id: "hidden feature \(feature.id)", label: feature.title,
                                  level: HealthRules.hiddenFeature(available: feature.available),
                                  word: feature.available ? w.available : w.missing,
                                  detail: feature.detail, fix: w.hiddenFeatureFix))
        }
        for display in f.displays {
            rows.append(HealthRow(id: "display \(display.id)",
                                  label: w.snapBarOn(display: display.name),
                                  level: .info,
                                  word: f.snapBarOn
                                    ? w.surface(f.snapBarAppearance.surface(withHousing: display.housing != nil))
                                    : w.disabled,
                                  detail: w.displayDetail(size: display.size, housing: display.housing)))
        }
        return HealthGroup(id: "compatibility", title: w.compatibilityTitle, rows: rows)
    }

    /// What every app of the family reports about itself: whether it comes back at login, how long it has
    /// been up, what it holds, whether it has crashed, and whether it is installed at all.
    static func app(_ f: HealthFacts) -> HealthGroup {
        let w = HealthWords.self
        var rows: [HealthRow] = []

        rows.append(HealthRow(id: "login item", label: w.launchAtLoginLabel,
                              level: HealthRules.loginItem(f.loginItem),
                              word: f.loginItem == .enabled ? w.enabled : w.disabled,
                              fix: w.loginItemNeedsApprovalFix))

        if let seconds = f.runningSeconds {
            rows.append(HealthRow(id: "running for", label: w.runningForLabel, level: .info,
                                  word: w.duration(seconds: seconds)))
        }
        if let bytes = f.memoryBytes {
            rows.append(HealthRow(id: "memory", label: w.memoryLabel, level: .info,
                                  word: w.megabytes(Int((Double(bytes) / 1_048_576).rounded()))))
        }

        let crashes = f.recentCrashes.count
        rows.append(HealthRow(id: "crashes",
                              label: w.crashesLabel(days: Int(Settings.Fixed.healthCrashWindow / 86_400)),
                              level: HealthRules.crashes(crashes),
                              word: crashes == 0 ? w.none : "\(crashes)",
                              detail: f.recentCrashes.first.map { w.lastCrash(stamp($0)) },
                              fix: w.crashesFix))

        rows.append(HealthRow(id: "location", label: w.locationLabel,
                              level: HealthRules.location(f.location),
                              word: w.locationWord(f.location), detail: f.bundlePath, fix: w.locationFix))

        return HealthGroup(id: "app", title: w.appTitle, rows: rows)
    }

    /// The first row's word: everything works, how many lines to look at, or how many stop the app.
    public static func summaryWord(_ summary: HealthSummary) -> String {
        switch summary.level {
        case .failure: HealthWords.notWorking(problems: summary.blocking)
        case .warning: HealthWords.toLookAt(summary.toLookAt)
        case .good, .info: HealthWords.everythingWorks
        }
    }

    /// The copied report: which app and which system, the summary, then every group of the page with one
    /// line per row, its level, its word and its detail. Written for a bug report, so nothing in it is a
    /// secret: the page reads no window title and no file of the user's.
    public static func text(appName: String, version: String, system: String, groups: [HealthGroup]) -> String {
        var lines = ["\(appName) \(version), \(system)", summaryWord(HealthSummary(groups: groups))]
        for group in groups {
            lines.append("")
            lines.append(group.title)
            for row in group.rows {
                var line = "\(tag(row.level)) \(row.label): \(row.word)"
                if let detail = row.detail, !detail.isEmpty {
                    line += " (\(detail.replacingOccurrences(of: "\n", with: "; ")))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func tag(_ level: HealthLevel) -> String {
        switch level {
        case .info: "[INFO]"
        case .good: "[OK]  "
        case .warning: "[WARN]"
        case .failure: "[FAIL]"
        }
    }

    /// A moment as a bug report wants it: the same in every language, sortable, to the minute, in the Mac's
    /// own time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
