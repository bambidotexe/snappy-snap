import AppKit
import os
import SnapCore
import SwiftUI
import SystemAdapters

/// The app's settings, one page per subject, picked from the window's toolbar. Every page is a column
/// of groups built from the kit in `SettingsRows.swift`: a title, a card of rows, and under the card
/// its hint, its warnings and its notes. On every page each number is a constant in
/// `SnapCore.Settings.Fixed`, and a choice that is a matter of taste rather than of the machine is not
/// offered at all.
///
/// Every control writes straight through `SettingsStore`, which persists on `didSet`, so there is no
/// Apply button and no local copy to get out of step.
///
/// **The copy has four rules.** Every text is the default size: `.body`, `.headline` for a group's
/// title, monospaced `.body` for what is code. A keyboard key is written symbol first, "⌘ Command". No
/// sentence uses a dash longer than the one on the keyboard. And a state is always a `StatusRow`.
///
/// `SnapCore.Settings` is spelled out wherever it appears because `SwiftUI` also exports a `Settings`
/// type (the scene).
struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: SystemStatus
    let minimums: MinimumSizeStore
    let health: HealthCheck

    var body: some View {
        // The page scrolls because the window's height is capped to what fits on the screen: on a
        // short display a long page is scrolled rather than cut off.
        ScrollView(.vertical) {
            page
                .frame(width: SettingsMetrics.contentWidth, alignment: .topLeading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SettingsPageHeight.self, value: proxy.size.height)
                    }
                }
        }
        .frame(width: SettingsMetrics.contentWidth)
        .onPreferenceChange(SettingsPageHeight.self) { [selection] height in
            // Preferences are delivered while SwiftUI updates, which is on the main actor.
            MainActor.assumeIsolated { selection.pageHeightChanged?(height) }
        }
    }

    @ViewBuilder private var page: some View {
        switch selection.page {
        case .general: GeneralPage(store: store, status: status)
        case .snapping: SnappingPage(store: store, status: status)
        case .snapBar: SnapBarPage(store: store)
        case .handles: HandlesPage(store: store, minimums: minimums)
        case .customAreas: CustomAreasPage(store: store)
        case .system: SystemPage(store: store, status: status)
        case .health: HealthPage(store: store, status: status, health: health)
        case .tip: TipPage()
        }
    }
}

/// The pages, in toolbar order. The raw value is the toolbar item's identifier, so the toolbar and the
/// selection cannot disagree about which page a click means.
///
/// General first, then the features in the order a user meets them, then what the app needs from the
/// system, then its health, then the tip jar last.
enum SettingsPageID: String, CaseIterable, Sendable {
    case general, snapping, snapBar, handles, customAreas, system, health, tip

    /// The toolbar item's label, and the window's title while the page is shown.
    var title: String {
        switch self {
        case .general: L("General")
        case .snapping: L("Snapping")
        case .snapBar: L("Snap Bar")
        case .handles: L("Handles")
        case .customAreas: L("Custom Areas")
        case .system: L("System")
        case .health: L("Health")
        case .tip: L("Tip")
        }
    }

    /// The SF Symbol drawn above the title.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .snapping: "rectangle.lefthalf.inset.filled"
        case .snapBar: "rectangle.topthird.inset.filled"
        case .handles: "arrow.left.and.line.vertical.and.arrow.right"
        case .customAreas: "rectangle.3.group"
        case .system: "checkmark.shield"
        case .health: "stethoscope"
        case .tip: "mug"
        }
    }
}

/// What the window and its one SwiftUI root share: which page is shown, set by the toolbar, and where
/// the page's measured height goes, set by the window.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var page: SettingsPageID = .general
    /// Called with the shown page's natural height whenever it changes: on a page switch, and when a
    /// page gains or loses a line of its own.
    var pageHeightChanged: ((CGFloat) -> Void)?
}

/// How tall the shown page wants to be, read from behind the page.
private struct SettingsPageHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The system state the window shows

/// The facts this window reports but does not own: whether Accessibility and notifications are granted,
/// what the system's tiling switches say, whether SnappySnap is registered as a login item, and whether
/// the drag detection is running. All of them can change while the window is shut, and none of them
/// lives in `Settings`.
///
/// **The window drives this, not a view.** `.onAppear` fires once per hosting view, and this window
/// is built once and re-shown, so a view-lifecycle hook would read the system exactly one time in
/// the life of the process. Nor is the polling a `TimelineView(.periodic:)`: the System page has to
/// notice a permission granted while it is open, but nothing documents such a schedule stopping for
/// a window that is merely ordered out, and `AXIsProcessTrusted()` plus a synchronous `cfprefsd`
/// round trip every two seconds for the life of the process would run on the thread that serves the
/// event tap. `startPolling`/`stopPolling` are called from the window's own open, close and
/// miniaturise.
///
/// Every property is published only when it actually changes, so an open window that is watching
/// nothing costs a handful of reads every two seconds and no SwiftUI invalidation at all. Each one is a
/// reader: nothing here ever asks macOS for anything.
@MainActor
final class SystemStatus: ObservableObject {
    /// Slow enough to be free, fast enough that flipping a switch in System Settings and coming
    /// back finds the page already right.
    static let pollInterval: TimeInterval = 2

    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var notifications: NotificationGrant
    @Published private(set) var tiling: SystemTilingState
    /// What `SMAppService` says, including the one state the General page's switch cannot show: registered,
    /// then switched off in System Settings. The Health page reports that one.
    @Published private(set) var loginItem: LoginItemState
    /// Whether the drag detection is waiting for the permission, running, or failed to start. Read with the
    /// permission, so the Health page's two rows move together when the grant arrives.
    @Published private(set) var engine: EngineState

    /// The General page's switch: on only while the system would open the app at login.
    var launchAtLogin: Bool { loginItem == .enabled }

    private let readEngine: @MainActor () -> EngineState
    private var timer: Timer?

    init(engine readEngine: @escaping @MainActor () -> EngineState) {
        self.readEngine = readEngine
        accessibilityGranted = Permissions.accessibilityGranted
        notifications = GrantCatalog.notificationGrant
        tiling = SystemTilingPrefs.read()
        loginItem = LoginItem.state
        engine = readEngine()
    }

    /// Logged at both ends on purpose: "is this still asking the system questions?" has to be
    /// answerable from the log, because a lifecycle nobody can see is one nobody can check.
    func startPolling() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Logger.app.debug("settings: system status poll started")
    }

    func stopPolling() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Logger.app.debug("settings: system status poll stopped")
    }

    /// Re-reads the login item alone, after an attempt to change it. Always read back rather than
    /// assumed: `register()` can fail, and a switch showing what the click asked for over a system that
    /// refused it is the worse of the two lies.
    func refreshLoginItem() {
        let state = LoginItem.state
        if state != loginItem { loginItem = state }
    }

    /// Everything, now, rather than at the next tick: every tick, and the Health page's Check Again.
    func refresh() {
        let granted = Permissions.accessibilityGranted
        if granted != accessibilityGranted { accessibilityGranted = granted }
        let state = SystemTilingPrefs.read()
        if state != tiling { tiling = state }
        refreshLoginItem()
        let engine = readEngine()
        if engine != self.engine { self.engine = engine }
        // Read, never asked: `notificationSettings()` answers and prompts nobody. It answers later, so
        // the value lands a moment after the others.
        GrantCatalog.refreshNotifications { [weak self] in
            guard let self else { return }
            let grant = GrantCatalog.notificationGrant
            if grant != self.notifications { self.notifications = grant }
        }
    }
}
