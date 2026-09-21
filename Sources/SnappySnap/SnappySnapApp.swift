import AppKit

/// The run loop is AppKit's, not SwiftUI's. The status item is added and removed by `AppDelegate` as
/// the user's choice changes (§14 *Show in menu bar*), and a `MenuBarExtra` cannot be: a scene
/// re-reads its `isInserted` binding only when SwiftUI re-evaluates the scene, which a change
/// published from the delegate does not cause (`pitfalls.md` 50). Nothing is lost by owning the loop
/// — the Settings window and every overlay are `NSHostingController`s; the welcome window is AppKit
/// already, and the Settings window was never a SwiftUI `Settings` scene.
@main
enum SnappySnapMain {
    /// `NSApplication.delegate` is a weak reference, so the delegate is held here for the process's
    /// lifetime.
    @MainActor private static var delegate: AppDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Stated here as well as by `Info.plist`'s `LSUIElement`, so a binary run straight out of
        // `.build` — where no bundle is read — is an accessory too, with no Dock icon and no menu
        // bar of its own.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
