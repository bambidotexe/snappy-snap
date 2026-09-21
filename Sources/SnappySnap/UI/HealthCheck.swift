import AppKit
import SnapCore
import SystemAdapters

/// What only the running app knows about its snapping, handed to the Settings window by `AppDelegate`:
/// when a snap last landed, what the registry holds, what Snap Assist could not put back, and the displays
/// as the app measured them.
struct AppHealthState {
    var lastSnap: Date?
    var registry: SnapRegistry
    var strandedWindows: Int
    var parkedRecordReadable: Bool
    var displays: [DisplayInfo]
}

/// The readings only the Health page shows. What the rest of the window also shows (a permission, the
/// tiling switches, the login item, and the drag detection with them) is `SystemStatus`'s, polled every
/// 2 s while the window is open; the settings are the store's, as they are now. These are read when the
/// page is shown and when Check Again is pressed, and never on a timer, so a page nobody is looking at
/// costs nothing.
///
/// **The window drives this, not a view**, like `SystemStatus`: `SettingsWindow` reads it when it opens on
/// the Health page and when the page is picked.
///
/// Every reading is cheap and answers at once (a sysctl, a `task_info`, a directory listing, one window
/// list, a parse of the custom areas' text), so all of them are taken on the main thread. None waits on a
/// socket, a subprocess or another app.
@MainActor
final class HealthCheck: ObservableObject {
    struct Readings: Equatable {
        var readAt = Date()
        var lastSnap: Date?
        var snappedWindows = 0
        var strandedWindows = 0
        var parkedRecordReadable = true
        var handlePlaces = 0
        var windowSizes = WindowSizesFact(readable: true, builtIn: 0, measured: 0, edited: 0)
        var customAreas: CustomAreasFact = .valid(areas: 0)
        var macOSVersion = ""
        var macOSDetail = ""
        var hiddenFeatures: [HiddenFeatureFact] = []
        var displays: [DisplayFact] = []
        var runningSeconds: TimeInterval?
        var memoryBytes: UInt64?
        var recentCrashes: [Date] = []
        var location: AppLocation = .applications
        var bundlePath = ""
    }

    @Published private(set) var readings = Readings()
    /// True from a press of Check Again until its readings have landed, and for at least
    /// `Settings.Fixed.healthMinimumBusy`.
    @Published private(set) var isChecking = false

    private let store: SettingsStore
    private let minimums: MinimumSizeStore
    private let app: @MainActor () -> AppHealthState

    init(store: SettingsStore, minimums: MinimumSizeStore, app: @escaping @MainActor () -> AppHealthState) {
        self.store = store
        self.minimums = minimums
        self.app = app
    }

    /// Everything the page reports: the polled states from `status`, the settings as they are now, and the
    /// rest from here.
    func facts(_ status: SystemStatus) -> HealthFacts {
        let settings = store.settings
        var f = HealthFacts()
        f.accessibilityGranted = status.accessibilityGranted
        f.notifications = status.notifications
        f.edgeTilingOn = status.tiling.conflicts
        f.marginsOn = status.tiling.margins
        f.optionTilingOn = status.tiling.optionTiling
        f.gapOn = settings.gapEnabled
        f.optionHalvesOn = settings.optionHalves
        f.engine = status.engine
        f.lastSnap = readings.lastSnap
        f.snappedWindows = readings.snappedWindows
        f.strandedWindows = readings.strandedWindows
        f.parkedRecordReadable = readings.parkedRecordReadable
        f.handlesOn = settings.handleBar
        f.handlePlaces = readings.handlePlaces
        f.windowSizes = readings.windowSizes
        f.customAreasOn = settings.customAreas
        f.customAreas = readings.customAreas
        f.macOSVersion = readings.macOSVersion
        f.macOSDetail = readings.macOSDetail
        f.hiddenFeaturesOn = settings.usePrivateAPIs
        f.hiddenFeatures = readings.hiddenFeatures
        f.snapBarOn = settings.snapBar
        f.snapBarAppearance = settings.snapBarAppearance
        f.displays = readings.displays
        f.loginItem = status.loginItem
        f.runningSeconds = readings.runningSeconds
        f.memoryBytes = readings.memoryBytes
        f.recentCrashes = readings.recentCrashes
        f.location = readings.location
        f.bundlePath = readings.bundlePath
        f.now = readings.readAt
        return f
    }

    /// Reads everything again.
    func read() {
        let now = Date()
        let app = app()
        let settings = store.settings
        let process = Bundle.main.executableURL?.lastPathComponent ?? "SnappySnap"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let rows = minimums.list.rows
        // One window list serves both counts. It needs no permission and reads no window name.
        let onScreen = WindowList.snapshot()
        let pairs = AdjacencyDetector.pairs(in: onScreen, maxGap: settings.handleMaxGap,
                                            minOverlap: settings.handleMinOverlap)
            .filter { HandleBarGeometry.isWithinOneDisplay($0, displays: app.displays) }
        let frames = Dictionary(WindowList.onScreenIDsAndFrames().map { ($0.id, $0.frame) },
                                uniquingKeysWith: { first, _ in first })
        let parsed = CustomZones.parse(store.customZonesJSON)

        let fresh = Readings(
            readAt: now,
            lastSnap: app.lastSnap,
            snappedWindows: app.registry.stillSnapped(among: frames),
            strandedWindows: app.strandedWindows,
            parkedRecordReadable: app.parkedRecordReadable,
            handlePlaces: pairs.count,
            windowSizes: WindowSizesFact(readable: !minimums.storedListWasUnreadable,
                                         builtIn: rows.filter { $0.origin == .builtIn }.count,
                                         measured: rows.filter { $0.origin == .measured }.count,
                                         edited: rows.filter { $0.origin == .edited }.count),
            customAreas: parsed.zones.map { .valid(areas: $0.areaCount) } ?? .invalid(parsed.problem ?? ""),
            macOSVersion: os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                                              : "\(os.majorVersion).\(os.minorVersion)",
            macOSDetail: ProcessInfo.processInfo.operatingSystemVersionString,
            hiddenFeatures: PrivateFeature.allCases.map { feature in
                HiddenFeatureFact(id: feature.rawValue, title: feature.title,
                                  available: PrivateAPI.shared.isAvailable(feature),
                                  detail: PrivateAPI.shared.report(for: feature))
            },
            displays: app.displays.map { display in
                DisplayFact(id: display.id, name: display.name, isBuiltIn: display.isBuiltIn,
                            size: display.frame.size, housing: display.housing?.size)
            },
            runningSeconds: ProcessStats.launchDate.map { now.timeIntervalSince($0) },
            memoryBytes: ProcessStats.memoryFootprint,
            recentCrashes: CrashReports.recent(process: process,
                                               since: now.addingTimeInterval(-SnapCore.Settings.Fixed.healthCrashWindow)),
            location: InstallLocation.current(),
            bundlePath: Bundle.main.bundleURL.path)
        if fresh != readings { readings = fresh }
    }

    /// Check Again: every reading now, the polled states with them, and the overview reads *Checking* long
    /// enough to be seen.
    func checkAgain(_ status: SystemStatus) {
        guard !isChecking else { return }
        isChecking = true
        status.refresh()
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + SnapCore.Settings.Fixed.healthMinimumBusy) { [weak self] in
            self?.isChecking = false
        }
    }
}
