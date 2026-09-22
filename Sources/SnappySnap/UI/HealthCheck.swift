import AppKit
import SnapCore
import SystemAdapters

/// What only the running app knows about its snapping, handed to the Settings window by `AppDelegate`:
/// when a snap last landed, what the registry holds, and what Snap Assist could not put back.
struct AppHealthState {
    var lastSnap: Date?
    var registry: SnapRegistry
    var strandedWindows: Int
    var parkedRecordReadable: Bool
}

/// The readings only the Health page shows. What the rest of the window also shows (a permission, the
/// tiling switches, and the drag detection with them) is `SystemStatus`'s, polled every 2 s while the
/// window is open; the settings are the store's, as they are now. These are read when the page is shown and
/// when Check Again is pressed, and never on a timer, so a page nobody is looking at costs nothing.
///
/// **The window drives this, not a view**, like `SystemStatus`: `SettingsWindow` reads it when it opens on
/// the Health page and when the page is picked.
///
/// Every reading is cheap and answers at once (a directory listing, one window list), so all of them are
/// taken on the main thread. None waits on a socket, a subprocess or another app.
@MainActor
final class HealthCheck: ObservableObject {
    struct Readings: Equatable {
        var readAt = Date()
        var lastSnap: Date?
        var snappedWindows = 0
        var strandedWindows = 0
        var parkedRecordReadable = true
        var recentCrashes: [Date] = []
    }

    @Published private(set) var readings = Readings()
    /// True from a press of Check Again until its readings have landed, and for at least
    /// `Settings.Fixed.healthMinimumBusy`.
    @Published private(set) var isChecking = false

    private let store: SettingsStore
    private let app: @MainActor () -> AppHealthState

    init(store: SettingsStore, app: @escaping @MainActor () -> AppHealthState) {
        self.store = store
        self.app = app
    }

    /// Everything the page reports: the polled states from `status`, the one setting a check is judged
    /// against, and the rest from here.
    func facts(_ status: SystemStatus) -> HealthFacts {
        var f = HealthFacts()
        f.accessibilityGranted = status.accessibilityGranted
        f.notifications = status.notifications
        f.edgeTilingOn = status.tiling.conflicts
        f.optionTilingOn = status.tiling.optionTiling
        f.optionHalvesOn = store.settings.optionHalves
        f.engine = status.engine
        f.lastSnap = readings.lastSnap
        f.snappedWindows = readings.snappedWindows
        f.strandedWindows = readings.strandedWindows
        f.parkedRecordReadable = readings.parkedRecordReadable
        f.recentCrashes = readings.recentCrashes
        f.now = readings.readAt
        return f
    }

    /// Reads everything again.
    func read() {
        let now = Date()
        let app = app()
        let process = Bundle.main.executableURL?.lastPathComponent ?? "SnappySnap"
        // It needs no permission and reads no window name.
        let frames = Dictionary(WindowList.onScreenIDsAndFrames().map { ($0.id, $0.frame) },
                                uniquingKeysWith: { first, _ in first })
        let fresh = Readings(
            readAt: now,
            lastSnap: app.lastSnap,
            snappedWindows: app.registry.stillSnapped(among: frames),
            strandedWindows: app.strandedWindows,
            parkedRecordReadable: app.parkedRecordReadable,
            recentCrashes: CrashReports.recent(process: process,
                                               since: now.addingTimeInterval(-SnapCore.Settings.Fixed.healthCrashWindow)))
        if fresh != readings { readings = fresh }
    }

    /// Check Again: every reading now, the polled states with them, and a spinner beside the button long
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
