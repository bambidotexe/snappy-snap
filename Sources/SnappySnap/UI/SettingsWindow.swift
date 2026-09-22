import AppKit
import os
import SnapCore
import SwiftUI
import SystemAdapters

/// SnappySnap is an accessory app whose overlays never activate it. The Settings window is the one
/// deliberate exception: the user opens it on purpose, so it may take focus.
///
/// Built by hand rather than with SwiftUI's `Settings` scene and `SettingsLink`, on purpose. In a
/// `MenuBarExtra`-only `LSUIElement` app the framework orders that window in without bringing the app
/// forward, so it needs an `NSApp.activate(ignoringOtherApps:)`, and the only place a scene offers to
/// hang one is `.onAppear`, which fires per hosting view and so would not run again when the same
/// window is re-shown. Owning the window means every open runs the same lines, and it gives the poll
/// behind the System page an open and a close to start and stop on.
///
/// **The pages are picked from a real `NSToolbar`.** `toolbarStyle = .preference` is what draws each
/// page's symbol above its title, and the window's title is the shown page's. There is one
/// `NSHostingController` for the whole window: the toolbar sets a page on `SettingsSelection` and the
/// SwiftUI root swaps it in.
///
/// **The window's height follows the page and its width never moves.** The page reports its natural
/// height and the window resizes to it around its own top-left corner, so the title bar stays put while
/// the bottom edge moves. That happens on a page switch and equally when a page gains a line of its
/// own, a warning under the Gap group or an error under the login switch, because what is measured is
/// what is on screen and not which page was picked.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let status: SystemStatus
    /// The Health page's own readings, taken when that page is shown and on its Check Again, never on a
    /// timer.
    private let health: HealthCheck
    private let selection = SettingsSelection()
    private let hosting: NSHostingController<SettingsView>
    /// Whether closing may hand focus back. Injected rather than inferred from `NSApp.windows`: the
    /// windows that must keep us active are a Snap Assist surface, which holds key so that Escape
    /// reaches it, and the welcome window. "Any visible key-capable window we own" happens to
    /// name exactly those two, every other overlay having `canBecomeKey == false`, and would silently
    /// stop meaning that the day a key-capable panel with no claim on our activation is added.
    private let othersNeedUsActive: @MainActor () -> Bool

    /// What the window is sized to, in content points. Zero until the page has been measured once.
    private var contentHeight: CGFloat = 0
    /// Whether the window has been sized and centred. Until it has, a reported height is recorded and
    /// nothing moves: `show()` is what centres, and it must do so at the right size.
    private var hasBeenPlaced = false
    /// Whether a resize is already queued for the next turn of the run loop.
    private var resizePending = false

    /// The height the window is laid out at while the first page is measured. Any value works; this
    /// one is close enough to the General page that the measurement rarely changes the layout twice.
    private static let measuringHeight: CGFloat = 480
    /// How much of the screen's height the window leaves alone, so a page that would fill the display
    /// scrolls instead. The menu bar and the Dock are already out of `visibleFrame`.
    private static let screenAllowance: CGFloat = 140

    /// `engine` and `app` are what only the running app knows about itself: whether the drag detection is
    /// up, and what the snapping has done. `AppDelegate` answers both.
    init(store: SettingsStore, minimums: MinimumSizeStore,
         engine: @escaping @MainActor () -> EngineState, app: @escaping @MainActor () -> AppHealthState,
         othersNeedUsActive: @escaping @MainActor () -> Bool) {
        self.othersNeedUsActive = othersNeedUsActive
        status = SystemStatus(engine: engine)
        health = HealthCheck(store: store, app: app)
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = selection.page.title
        window.isReleasedWhenClosed = false
        hosting = NSHostingController(rootView: SettingsView(selection: selection, store: store,
                                                            status: status, minimums: minimums,
                                                            health: health))
        // The height is this class's to animate. A hosting controller that also constrains the window
        // to its content fights every resize.
        hosting.sizingOptions = []
        super.init()
        selection.pageHeightChanged = { [weak self] height in self?.pageReported(height) }
        window.contentViewController = hosting
        window.delegate = self
        installToolbar()
    }

    /// Whether the window is on screen. The handle bar and the junction knobs read this: their panels
    /// sit above ordinary windows, so while Settings is up they would draw over it and swallow the
    /// clicks meant for its controls. False once the window is closed *or* miniaturised, which is right
    /// both times: a miniaturised window has no controls to protect.
    var isUp: Bool { window.isVisible }

    func show() {
        // Sized before it is centred, never after: assigning an `NSHostingController` does not size
        // the window until its view lays out, so centring before that puts a zero-width window's
        // origin at the middle of the screen. Measured: the window landed at x = 756 on a 1512 pt
        // display.
        if !hasBeenPlaced {
            window.setContentSize(NSSize(width: SettingsMetrics.contentWidth, height: Self.measuringHeight))
            // Lays the page out, which reports its height into `pageReported`.
            window.layoutIfNeeded()
            if contentHeight <= 0 {
                // The page has not reported. Ask the hosting controller instead, so the window is
                // never centred at a height nobody chose.
                let fits = hosting.sizeThatFits(in: NSSize(width: SettingsMetrics.contentWidth,
                                                           height: maxContentHeight))
                contentHeight = clamp(fits.height)
            }
            hasBeenPlaced = true
            window.setFrame(frame(forContentHeight: contentHeight), display: false)
            window.center()
        }
        // `ignoringOtherApps` rather than the cooperative `activate()`: measured on macOS 27, the
        // plain call left the window *behind* the Finder window it opened over, with our process not
        // frontmost. An accessory app is never handed an activation token by the app it is taking over
        // from, and this window is the one thing in SnappySnap the user asked for by name.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        status.startPolling()
        if selection.page == .health { health.read() }
    }

    // MARK: - Height

    /// The tallest the content may be: what fits on the screen the window is on, less the allowance.
    private var maxContentHeight: CGFloat {
        let screen = window.screen ?? NSScreen.main
        return max(200, (screen?.visibleFrame.height ?? 900) - Self.screenAllowance)
    }

    private func clamp(_ height: CGFloat) -> CGFloat {
        min(max(height.rounded(), 1), maxContentHeight)
    }

    /// The page has measured itself. Before the window is placed this only records the height, because
    /// `show()` is what sizes and centres; afterwards it resizes.
    private func pageReported(_ height: CGFloat) {
        let wanted = clamp(height)
        guard abs(wanted - contentHeight) > 0.5 else { return }
        contentHeight = wanted
        guard hasBeenPlaced else { return }
        scheduleResize()
    }

    /// The resize is taken on the next turn of the run loop rather than here: an animated `setFrame`
    /// does not return until the animation has run, and this is reached from inside a SwiftUI update.
    /// Coalesced, so a page that reports twice while settling is resized once.
    private func scheduleResize() {
        guard !resizePending else { return }
        resizePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizePending = false
            let target = self.frame(forContentHeight: self.contentHeight)
            guard target != self.window.frame else { return }
            self.window.setFrame(target, display: true, animate: self.window.isVisible)
        }
    }

    /// The window frame that holds `height` points of content, keeping the top-left corner where it is.
    ///
    /// The chrome is measured from the live window rather than computed: with a `.preference` toolbar
    /// the title bar and the toolbar are one band whose height is AppKit's business, and the content
    /// view's own frame is the one place that already accounts for it.
    private func frame(forContentHeight height: CGFloat) -> NSRect {
        let current = window.frame
        let content = window.contentView?.frame.size ?? current.size
        let chrome = NSSize(width: max(current.width - content.width, 0),
                            height: max(current.height - content.height, 0))
        var target = current
        target.size = NSSize(width: SettingsMetrics.contentWidth + chrome.width, height: height + chrome.height)
        target.origin.y = current.maxY - target.height
        return target
    }

    // MARK: - The toolbar

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "SnappySnapSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // After the toolbar is on the window, so the item it names already exists.
        toolbar.selectedItemIdentifier = identifier(for: selection.page)
    }

    private func identifier(for page: SettingsPageID) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(page.rawValue)
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsPageID.allCases.map(identifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    /// Every page, so that the one being shown is the one drawn as selected.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPageID(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.title
        item.paletteLabel = page.title
        item.image = image(for: page)
        item.target = self
        item.action = #selector(pagePicked(_:))
        return item
    }

    /// A symbol name this macOS does not know resolves to nil, and an item with no image in a
    /// `.preference` toolbar is a gap nobody can aim at. The stand-in costs a wrong picture rather than
    /// a page that cannot be reached, and the log says which name went missing.
    private func image(for page: SettingsPageID) -> NSImage? {
        if let image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title) {
            return image
        }
        Logger.app.error("settings: no SF Symbol named \(page.symbol, privacy: .public) on this macOS; the \(page.title, privacy: .public) page shows a stand-in")
        return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: page.title)
    }

    @objc private func pagePicked(_ sender: NSToolbarItem) {
        guard let page = SettingsPageID(rawValue: sender.itemIdentifier.rawValue) else { return }
        selection.page = page
        window.title = page.title
        // The Health page's own readings are taken when it is shown, never on a timer.
        if page == .health { health.read() }
    }

    // MARK: - Going away

    /// Hands focus back when the window goes away. An accessory app with no window left is still the
    /// active application, which would send the user's keystrokes nowhere.
    private func windowWentAway() {
        status.stopPolling()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    func windowWillClose(_ notification: Notification) { windowWentAway() }

    /// Miniaturising never fires `windowWillClose`, so without this the app would stay active with
    /// nothing on screen, the very state the hand-back exists to prevent, and the poll behind the
    /// System page would keep asking about a page nobody can see.
    func windowDidMiniaturize(_ notification: Notification) { windowWentAway() }

    func windowDidDeminiaturize(_ notification: Notification) { status.startPolling() }
}
