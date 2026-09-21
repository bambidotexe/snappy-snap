import Foundation
import os
import UserNotifications

/// Identifiers, never shown: outside the class so the delegate's callbacks, which arrive off the main
/// actor, can read them.
private enum UpdateNotification {
    static let identifier = "update"
    static let category = "update"
    static let action = "update.open"
}

/// The one notification the app ever posts: a newer release found by a check nobody asked for. Permission
/// is never asked for here: the welcome window's Allow button is the one place that asks, and this reads
/// the grant and posts only if it is already there. Accessibility stays the only thing the app needs to
/// work, and a user who says no still finds the release in Settings.
///
/// `UNUserNotificationCenter.current()` traps in a process with no bundle (a binary run out of
/// `.build`), so nothing here touches it unless the app runs from one.
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// The notification's Update button, or a click on the notification itself.
    var onUpdateRequested: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    /// At launch, before the first run-loop turn ends: a click on a notification left by an earlier run
    /// starts the app, and is delivered to the delegate found in place then.
    func start() {
        guard let center else { return }
        center.delegate = self
        // `.foreground`: the button brings the app forward, which the update window needs.
        let update = UNNotificationAction(identifier: UpdateNotification.action, title: L("Update"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: UpdateNotification.category, actions: [update], intentIdentifiers: []),
        ])
    }

    /// One at a time: a later check's notification replaces the one still in Notification Center.
    func postUpdateAvailable(version: String) {
        guard let center else { return }
        let title = L("Version \(version) is available")
        let body = L("Click Update to download and install it.")
        // Reads, never asks. A check the user did not start must not put a permission dialog on their
        // screen out of nowhere: every prompt in this app follows a click, and the click for this one
        // is the Allow button on the welcome pages. Never granted, nothing is lost — the release shows
        // in Settings all the same.
        Task { @MainActor in
            guard await center.notificationSettings().authorizationStatus == .authorized else {
                Logger.update.notice("notification not posted: not allowed; the release shows in Settings")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = UpdateNotification.category
            try? await center.add(
                UNNotificationRequest(identifier: UpdateNotification.identifier, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let wanted = response.actionIdentifier == UpdateNotification.action
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if response.notification.request.identifier == UpdateNotification.identifier, wanted {
            Task { @MainActor in self.onUpdateRequested?() }
        }
        completionHandler()
    }

    /// Asked only while the app is frontmost, which for this app means Settings is the window in front:
    /// the notification shows then too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
