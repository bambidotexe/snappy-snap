import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// The app's own icon, then starting up, updates, and the two ways out.
struct GeneralPage: View {
    @ObservedObject var store: SettingsStore
    /// The login item's state lives in `SMAppService` alone, not in our settings file: the user can
    /// remove SnappySnap in System Settings › General › Login Items without ever opening this window,
    /// and it survives a reinstall of our preferences. The switch therefore shows the system's answer,
    /// re-read by `SystemStatus` on every open and on every poll, and nothing is mirrored into
    /// `Settings`: a second copy could only ever disagree with the one that decides.
    @ObservedObject var status: SystemStatus
    @State private var loginError: String?

    /// The side of the app icon that heads the page.
    private static let iconSide: CGFloat = 144

    var body: some View {
        SettingsPage {
            // The icon alone, centred: no name and no version, which the Updates group gives.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            // There is no pause switch: a user who does not want snapping quits the app. With the icon
            // hidden its menu is hidden with it, so the way back to this window has to be named.
            SettingsGroup(title: L("Startup"),
                          notes: [L("With the icon hidden, SnappySnap keeps working. Open it again from the Applications folder or Spotlight to get back to this window.")]) {
                ToggleRow(L("Launch at login"),
                          isOn: Binding(get: { status.launchAtLogin }, set: setLaunchAtLogin))
                ToggleRow(L("Show in menu bar"), isOn: $store.settings.showInMenuBar)
                if let loginError {
                    StatusRow(loginError, mark: .warning(L("Failed")))
                }
            }
            UpdatesGroup()
            SettingsGroup(title: L("Quit")) {
                // Through `NSApplication.terminate`, as the menu item does, so `applicationWillTerminate`
                // runs and puts back any window Snap Assist has parked off-screen. No confirmation:
                // opening the app again undoes it.
                ButtonRow {
                    Button(L("Quit SnappySnap"), role: .destructive) { NSApp.terminate(nil) }
                }
            }
            // The warning is not a state that can be put right: it is the hazard of the other way out,
            // and the button beside it is the way that is not hazardous. It therefore always shows.
            SettingsGroup(title: L("Uninstall"),
                          hint: L("Gives back the Accessibility permission, removes the entry in Login Items, and removes SnappySnap's settings and its update folder. SnappySnap then puts every parked window back, moves itself to the Trash and quits."),
                          warnings: [L("Do not drag SnappySnap to the Trash. The Login Items entry and the Accessibility permission stay behind, pointing at an app that is gone.")]) {
                ButtonRow {
                    Button(L("Uninstall SnappySnap"), role: .destructive) { confirmUninstall() }
                }
            }
        }
    }

    /// Asks first, because it takes the app with it, and says afterwards what it could not remove.
    ///
    /// The preferences and the folder are not removed here and cannot be: the quit puts the parked windows
    /// back and the stores that do it write into the preferences, and cfprefsd writes the domain out again
    /// as the process exits whatever happens. A detached helper waits for the pid instead.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = L("Uninstall SnappySnap?")
        alert.informativeText = L("SnappySnap gives back the Accessibility permission, removes the entry in Login Items, and removes its settings and its update folder. It then puts every parked window back, moves itself to the Trash and quits.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L("Uninstall"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "dev.rubens.SnappySnap"
        var failures = Uninstall.removeSystemRegistrations(bundleIdentifier: bundleID)
        Uninstall.moveBundleToTrash { failure in
            if let failure { failures.append(failure) }
            if let failure = Uninstall.startHelper(bundleIdentifier: bundleID) { failures.append(failure) }
            let result = NSAlert()
            result.messageText = failures.isEmpty ? L("SnappySnap has been removed") : L("SnappySnap has been removed, except for this")
            result.informativeText = failures.isEmpty
                ? L("SnappySnap is in the Trash, and nothing it set up is left on the Mac.")
                : failures.map(Self.sentence).joined(separator: "\n\n")
            result.alertStyle = failures.isEmpty ? .informational : .warning
            result.addButton(withTitle: L("Quit"))
            result.runModal()
            NSApp.terminate(nil)
        }
    }

    /// `Uninstall` says which step and what the system said; the words are this page's.
    private static func sentence(for failure: UninstallFailure) -> String {
        switch failure.step {
        case .accessibilityGrant:
            L("The Accessibility permission could not be given back. Remove SnappySnap yourself in System Settings, Privacy & Security, Accessibility.")
        case .loginItem:
            String(format: L("The Login Items entry could not be removed: %@. Remove SnappySnap yourself in System Settings, General, Login Items."), failure.reason)
        case .bundleToTrash:
            String(format: L("SnappySnap could not move itself to the Trash: %@. Drag it there from the Applications folder; that is all that is left of it."), failure.reason)
        case .storedState:
            String(format: L("The last step could not be started: %@. SnappySnap's settings and its folder in Application Support are still there; remove them by hand."), failure.reason)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            loginError = nil
        } catch {
            // Registering fails for an unsigned or un-bundled build; the message is shown rather than
            // swallowed, and the switch settles wherever the system actually ended up.
            loginError = error.localizedDescription
        }
        status.refreshLoginItem()
    }
}

// MARK: - Updates

/// The version row carries the last answer as its status mark, and the group has one button: the way
/// to look for a release, or, once a newer one is known, the way to get it, which opens the update
/// window. The app also looks on its own, shortly after launch and then weekly, so the state is the
/// app's (`UpdateController.shared`) and not this view's: what a check found while the window was
/// closed is here when it opens. Which button, and what a press starts, are `UpdatePanel`'s rules.
private struct UpdatesGroup: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        SettingsGroup(title: L("Updates")) {
            // The app's own name is never translated, so the version row is built rather than looked up.
            StatusRow(updates.appVersion.isEmpty ? "SnappySnap" : "SnappySnap \(updates.appVersion)",
                      mark: mark)
            ButtonRow {
                if updates.panel.offersUpdate {
                    Button(L("Update")) { updates.press() }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                } else {
                    Button(L("Check for Updates")) { updates.press() }
                        .disabled(updates.panel.isBusy)
                }
            }
        }
    }

    /// What the version row says on its right, or nothing before the first answer.
    private var mark: StatusMark? {
        switch updates.panel.state {
        case .idle: nil
        case .checking: .busy(L("Checking"))
        case .upToDate: .good(L("Up to date"))
        case .available(let version): .info(L("Version \(version.displayString) is available"))
        case .noRelease: .warning(L("No release published yet"))
        case .checkFailed(let reason): .warning(L("Could not check: \(reason)"))
        case .installFailed(let reason): .warning(L("Update failed: \(reason)"))
        }
    }
}
