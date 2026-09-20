import AppKit
import SwiftUI
import SystemAdapters

struct OnboardingView: View {
    let tiling: SystemTilingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("SnappySnap needs Accessibility access"))
                .font(.title2.bold())
            Text(L("It uses Accessibility to see which window you drag and to move and resize windows. Nothing about your windows leaves your Mac."))
            Text(L("1. Click “Open Accessibility Settings”.\n2. Enable SnappySnap in the list.\n3. Come back here and the app starts by itself."))
            Button(L("Open Accessibility Settings")) { Permissions.openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
            if tiling.conflicts {
                Divider()
                Label(L("macOS edge tiling is on and will fight SnappySnap. Turn off “Drag windows to screen edges to tile” and “Drag windows to menu bar to fill screen”."), systemImage: "exclamationmark.triangle")
                Button(L("Open Desktop & Dock Settings")) { Permissions.openDesktopAndDockSettings() }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class OnboardingWindow {
    private let window: NSWindow

    init(tiling: SystemTilingState) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Welcome to SnappySnap")
        window.contentViewController = NSHostingController(rootView: OnboardingView(tiling: tiling))
        window.isReleasedWhenClosed = false
        window.center()
    }

    /// Whether the window is on screen. `SettingsWindow` asks, so that closing Settings over a
    /// still-open onboarding window does not deactivate the app out from under it.
    var isUp: Bool { window.isVisible }

    func show() {
        // `ignoringOtherApps`, like `SettingsWindow`: measured on macOS 27, the cooperative
        // `activate()` cannot bring an accessory app forward — it left a window of ours *behind* the
        // one it opened over, with our process not frontmost. This is the window that most needs to be
        // seen: without the permission it asks for, the app does nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}
