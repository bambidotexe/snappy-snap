import AppKit
import ServiceManagement
import SnapCore
import SystemAdapters
import UserNotifications

/// What the onboarding lists: the two macOS grants SnappySnap can ask for, and the two settings it
/// works best with. One list, so a flow fixed here is fixed everywhere it is shown.
///
/// **A grant's action asks macOS and nothing else.** The system dialog carries its own way to System
/// Settings, so the app never opens a pane beside it, nor instead of it once a grant has been refused.
/// macOS tiling is the one exception, because there is no dialog for it: the pane *is* that row's flow.
///
/// Notification authorization is read asynchronously, so callers refresh it with `refreshNotifications`
/// and read the cached value through `notificationsGranted`.
@MainActor
enum GrantCatalog {
    private(set) static var notificationsGranted = false

    /// Every macOS grant SnappySnap can ask for. Accessibility is required: without it the app moves no
    /// window at all.
    ///
    /// Both rows name System Settings in `mayOpen`, not only the one whose button opens a pane: a system
    /// permission dialog carries its own button there, so either row can be the reason the user ends up
    /// in System Settings, and the wizard has to come back when they leave it.
    static var permissions: [GrantItem] {[
        GrantItem(id: .accessibility,
                  title: L("Device Control and Data Access"),
                  why: L("Lets SnappySnap see the window you are dragging and move and resize windows for you. Nothing about your windows ever leaves your Mac."),
                  required: true,
                  granted: { Permissions.accessibilityGranted },
                  buttonTitle: L("Allow…"),
                  action: { _, done in Permissions.promptForAccessibility(); done() },
                  mayOpen: systemSettings),
        GrantItem(id: .notifications,
                  title: L("Allow Notifications"),
                  why: L("Lets SnappySnap say when a new version is out. That is the only notification it ever posts."),
                  required: false,
                  granted: { notificationsGranted },
                  buttonTitle: L("Allow…"),
                  action: { _, done in requestNotifications(done) },
                  mayOpen: systemSettings),
    ]}

    /// The two settings that decide whether SnappySnap is the one handling a drag, and whether it is
    /// there at all without being opened. Neither is a permission, and neither is required.
    ///
    /// The tiling row stands for two switches rather than one, so it carries a name of the app's own and
    /// quotes both switches word for word in `why`: the user has to find them both, and turning off only
    /// one still leaves macOS grabbing the other drag.
    static var setUp: [GrantItem] {[
        GrantItem(id: .systemTiling,
                  title: L("macOS window tiling"),
                  why: L("In Desktop & Dock, turn off “Drag windows to left or right edge of screen to tile” and “Drag windows to menu bar to fill screen”. Left on, macOS and SnappySnap grab the same drags."),
                  required: false,
                  granted: { !SystemTilingPrefs.read().conflicts },
                  buttonTitle: L("Open Desktop & Dock Settings"),
                  action: { _, done in Permissions.openDesktopAndDockSettings(); done() },
                  mayOpen: systemSettings,
                  doneTitle: L("Off")),
        GrantItem(id: .loginItem,
                  title: L("Open at Login"),
                  why: L("Starts SnappySnap when you log in, so snapping is there without opening anything."),
                  required: false,
                  granted: { LoginItem.isEnabled },
                  // `SMAppService.mainApp` registers and unregisters from here, so this flow never leaves
                  // the app and `mayOpen` stays nil. The user can still undo it in System Settings, which
                  // the poll picks up like any other change.
                  buttonTitle: L("Turn On"),
                  action: { window, done in setLoginItem(true, window, done) },
                  doneTitle: L("On"),
                  removeTitle: L("Turn Off"),
                  remove: { window, done in setLoginItem(false, window, done) }),
    ]}

    /// The app a grant flow can send the user to.
    static let systemSettings = "com.apple.systempreferences"

    /// Reads the notification grant into the cache the rows use. `notificationSettings()` reads and
    /// never asks, which is what lets the 2 s poll call it.
    ///
    /// `UNUserNotificationCenter.current()` traps in a process with no bundle, which is how `axprobe`
    /// and a unit test run, so the centre is only reached from inside an `.app`.
    static func refreshNotifications(_ done: @escaping () -> Void) {
        guard let centre else { done(); return }
        Task { @MainActor in
            notificationsGranted = await centre.notificationSettings().authorizationStatus == .authorized
            done()
        }
    }

    /// Asks. Only a row's button reaches this.
    private static func requestNotifications(_ done: @escaping () -> Void) {
        guard let centre else { done(); return }
        Task { @MainActor in
            _ = try? await centre.requestAuthorization(options: [.alert])
            refreshNotifications(done)
        }
    }

    private static var centre: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    private static func setLoginItem(_ on: Bool, _ window: NSWindow?, _ done: @escaping () -> Void) {
        do { try LoginItem.setEnabled(on) }
        catch { report(L("Open at Login"), error.localizedDescription, in: window) }
        done()
    }

    /// A refusal is worth nothing at all to the user unless we say so: the row would simply stay as it
    /// was, with no reason given.
    private static func report(_ title: String, _ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }
}
