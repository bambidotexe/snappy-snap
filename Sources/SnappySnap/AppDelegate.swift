import AppKit
import Combine
import os
import SnapCore
import SystemAdapters

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    let screens = Screens()
    let ax = AccessibilityWindows()
    let mouse = MouseEvents()
    let state = SnapState()
    /// Every animated subsystem's window writes, off the main thread. **One** for the app, not one
    /// per feature — the writer's first invariant is that one element belongs to one pid queue for
    /// a whole gesture, and two writers would give a hung application two threads.
    /// `SteppingSnapEngine` writes every animated frame through it, which is every snap in the app
    /// — a zone drop, a snap-bar pair, a Snap Assist placement and the release of a pill or a knob
    /// — and the deck and the minimum-size probe write the rest.
    let writer = WindowWriter.live()
    /// Everything the app knows about how small windows go: one row per application, and each held
    /// window's own floor. One for the app, because it is persisted and every feature reads and
    /// writes the same list; a second instance would hold a stale copy of the same file.
    let minimums = MinimumSizeStore()

    private var engineStarted = false
    private var preview: ZonePreviewController?
    private var customZones: CustomZonesController?
    private var dragSession: DragSessionController?
    private var assist: SnapAssistController?
    private var handleBar: HandleBarController?
    private var junctions: JunctionHandleController?
    private var spaceWatcher: SpaceWatcher?
    private var oversize: OversizeWatcher?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindow?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// Held only while the icon is in the menu bar: releasing it to `NSStatusBar.system` is what takes
    /// it out, so `nil` here means no icon.
    private var statusItem: NSStatusItem?
    /// The Command (⌘) key's own state, read from the event tap's `flagsChanged` events — never inferred
    /// from mouse movement, because the pill has to disappear with the pointer standing still over it.
    private var commandDown = false

    /// Built on first use and kept: the window is cheap to hold and re-showing the one the user
    /// closed keeps whatever tab they were on.
    ///
    /// Nothing is cancelled here, deliberately. Every route in — the status item's menu, and a launch
    /// or re-launch of the bundle (§14) — needs the mouse button up, so no window drag and no handle
    /// drag can be live at this moment; a Snap Assist phase can be, and a click that opened the menu
    /// has already ended it through the tap (`route` → `handleGlobalMouseDown` → `.clickOutside`),
    /// which deals its parked windows back.
    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(store: settingsStore, minimums: minimums,
                                            othersNeedUsActive: { [weak self] in
                                                self?.assist?.isActive == true || self?.onboarding?.isUp == true
                                                    || UpdateController.shared.windowIsUp
                                            })
        }
        settingsWindow?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else can spend the event: `currentAppleEvent` is the launch's own, and
        // only until the first one the app handles itself.
        // A reinstall opens the bundle as well, and the window that got was one nobody asked for. The
        // installer says so with a marker, which this reads once and removes (`QuietLaunch`). An update
        // writes that marker too, and says so a second way as well: while its outcome is unread, this
        // launch is the update helper's, whatever version wrote what is in `updates/`.
        let openedByHand = !launchedAsLoginItem() && !QuietLaunch.consume()
            && !UpdateController.installOutcomeIsWaiting
        installMainMenu()
        followPrivateAPISetting()
        followShowInMenuBarSetting()
        if Permissions.accessibilityGranted { startEngine() } else { pollPermission() }
        // The wizard is the first run's window, whatever the grants are, and it wins over Settings: a
        // launch never shows two windows at once. Nothing here asks macOS for anything — every
        // permission dialog in this app follows a click of the user's, on a row of that window.
        if !OnboardingState.completed, !UpdateController.installOutcomeIsWaiting {
            showOnboarding()
        } else if openedByHand {
            showSettings()
        }
        startUpdates()
    }

    /// Last, so the launch that follows an Install and Relaunch finds the rest of the app in place
    /// when it opens Settings on the new version. The update window hands activation back like the
    /// Settings window does, and defers to the same windows.
    private func startUpdates() {
        let updates = UpdateController.shared
        updates.onShowSettings = { [weak self] in self?.showSettings() }
        updates.othersNeedUsActive = { [weak self] in
            self?.settingsWindow?.isUp == true || self?.assist?.isActive == true || self?.onboarding?.isUp == true
        }
        updates.start()
    }

    /// An accessory application never shows a menu bar of its own, so nothing here is ever seen. It
    /// exists for its key equivalents alone: ⌘Q and ⌘W reach a window only through the main menu, and
    /// the Settings window and the welcome window are both ordinary key windows.
    private func installMainMenu() {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit SnappySnap"), action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(windowItem)
        NSApplication.shared.mainMenu = main
    }

    /// Whether macOS started the app as a login item rather than a person opening it.
    ///
    /// The open-application Apple event carries `keyAELaunchedAsLogInItem` under `keyAEPropData` when
    /// `SMAppService` is what launched us, and carries nothing there when the Finder, Spotlight or
    /// `open` did. The absent case therefore reads as opened by hand, which is the safe way round:
    /// an event this cannot recognise shows the Settings window rather than swallowing the one route
    /// back in when the menu-bar icon is hidden.
    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The one way back into Settings once the icon is hidden: opening the bundle again from the
    /// Applications folder or Spotlight while the app is already running fires this rather than
    /// `applicationDidFinishLaunching`. Same branch as the cold launch — the wizard takes precedence
    /// while it is up, so a fresh install never shows two windows at once, and with no Dock icon this
    /// is how the user fetches it back from behind whatever they left in front of it. A login item
    /// cannot arrive here: it launches a process that is not running yet.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let wizard = onboarding?.window, wizard.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            wizard.makeKeyAndOrderFront(nil)
        } else {
            showSettings()
        }
        return true
    }

    /// Quitting is one of the routes out of a choosing phase, and the windows it parked must not be
    /// left off-screen because the user chose the menu's Quit item mid-phase. The handle bar is
    /// stopped rather than cancelled: its 10 Hz poll has no reason to outlive the decision to quit,
    /// and `stop()` is the only thing that ends it.
    func applicationWillTerminate(_ notification: Notification) {
        // `dismiss` reaches a deal back that has outlived its phase as well as a live one, so this
        // is the whole of it — and calling a second restore here would double the 0.40 s this is
        // already allowed to spend before the watchdog. Stopped first, and stopped rather than left
        // running: the restore below is bounded by a deadline, and a watcher still ticking into it
        // could fire one more interruption on top of a quit that is already putting every parked
        // window back. `handleBar.stop()` below is the same decision, and this is its sibling.
        spaceWatcher?.stop()
        // Same decision, same reason: a sweep that fired into the restore below would be writing
        // windows on an app that is going away.
        oversize?.stop()
        assist?.dismiss(.quit)
        junctions?.cancel()
        handleBar?.stop()
    }

    /// The one private-API switch, wired to the one shim that reads it.
    ///
    /// The value is mirrored rather than read where it is needed: `SnapCore.Settings` holds every user
    /// choice and knows nothing of `SystemAdapters`, and `PrivateAPI` resolves symbols and knows
    /// nothing of a settings file. This line is the whole of the coupling between them.
    ///
    /// Run **before** the engine, because the first `ax.window(at:)` of the session must already be
    /// on the route the user chose, and then on every change — which is what makes flipping the
    /// toggle take effect on the next call rather than on the next launch. It is deliberately not
    /// inside `startEngine`: that is skipped entirely while Accessibility is ungranted, and the
    /// switch has to be honoured from the first moment either way.
    private func followPrivateAPISetting() {
        PrivateAPI.shared.isEnabled = settingsStore.settings.usePrivateAPIs
        settingsStore.$settings
            .map(\.usePrivateAPIs)
            .removeDuplicates()
            .sink { on in MainActor.assumeIsolated { PrivateAPI.shared.isEnabled = on } }
            .store(in: &cancellables)
    }

    /// The status item follows `showInMenuBar`, on launch and on every change — the same pattern as
    /// `followPrivateAPISetting()`, and what makes the checkbox take effect without a relaunch.
    ///
    /// Nothing else follows this setting: hiding the icon takes away the icon and the menu on it, and
    /// no part of the engine, the event tap or any overlay reads it.
    private func followShowInMenuBarSetting() {
        apply(showInMenuBar: settingsStore.settings.showInMenuBar)
        settingsStore.$settings
            .map(\.showInMenuBar)
            .removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.apply(showInMenuBar: on) } }
            .store(in: &cancellables)
    }

    /// Logged on every change, because a missing icon and a missing app look the same from outside.
    private func apply(showInMenuBar on: Bool) {
        if on { addStatusItem() } else { removeStatusItem() }
        Logger.app.info("menu bar icon \(on ? "shown" : "hidden", privacy: .public)")
    }

    /// No pause item: a user who does not want snapping quits the app. The menu is Settings and Quit,
    /// with a separator between them so a mis-click costs a gap.
    private func addStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarMark()

        let menu = NSMenu()
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsFromMenu),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit SnappySnap"), action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApplication.shared
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    /// The side of the status item's image, in points. The mark is drawn to fill 15.5 pt of it and
    /// sits 0.5 pt below centre; those two numbers are baked into the PDF by `Scripts/svg-to-pdf.swift`,
    /// which states them against this same 18, so changing one means regenerating the other.
    private static let menuBarMarkSide: CGFloat = 18

    /// The brand mark: a vector PDF drawn in one flat opaque colour, so AppKit recolours it as a
    /// template for light and dark menu bars and for the highlighted state. A missing resource leaves
    /// the item with no image rather than falling back to a symbol — an empty slot that still opens
    /// the menu is a visible defect, where a stand-in glyph would quietly look like the real thing.
    private func menuBarMark() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "MenuBarMark", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            Logger.app.error("MenuBarMark.pdf is missing from the resource bundle; the status item has no image")
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: Self.menuBarMarkSide, height: Self.menuBarMarkSide)
        image.accessibilityDescription = "SnappySnap"
        return image
    }

    /// Releasing the item to `NSStatusBar.system` is the whole of it: an item merely hidden keeps its
    /// slot, and the icons to its left would not close up.
    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// The menu item needs an Objective-C selector, which `showSettings()` is not.
    @objc private func openSettingsFromMenu() { showSettings() }

    func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        guard mouse.start() else {
            Logger.app.error("event tap could not be created; is Accessibility granted?")
            engineStarted = false
            return
        }
        if !mouse.hearsDevicePresses {
            Logger.app.error("device-level event tap could not be created; a window-move gesture the window server runs (fn + drag) will arm no drag")
        }
        let preview = ZonePreviewController()
        self.preview = preview
        let customZones = CustomZonesController()
        self.customZones = customZones
        // One engine for every animated placement: the router's snaps, and the two windows a handle
        // release moves. The handle features drive the engine directly because they land frames
        // rather than zones.
        let stepping = SteppingSnapEngine(writer: writer)
        let router = EngineRouter(stepping: stepping, state: state, settingsStore: settingsStore,
                                  minimums: minimums, screens: screens)
        // `ax` for the pair partner, which the bar resolves once at drag confirmation.
        let snapBar = SnapBarController(layouts: Self.loadSnapBarLayouts(), ax: ax)
        // One for the drop and the Snap Assist pick alike: the correction pass is the same pass.
        let coordinator = ArrangementCoordinator(engines: router)
        dragSession = DragSessionController(ax: ax, writer: writer, screens: screens,
                                            settingsStore: settingsStore, state: state,
                                            minimums: minimums,
                                            preview: preview, engines: router, coordinator: coordinator,
                                            snapBar: snapBar, customOverlay: customZones)
        let assist = SnapAssistController(ax: ax, screens: screens, settingsStore: settingsStore,
                                          writer: writer, engines: router, coordinator: coordinator,
                                          minimums: minimums)
        self.assist = assist
        // Before anything else, put back any window an earlier run left parked off-screen.
        assist.restoreParkedFromPreviousRun()
        // No poll and no window list of its own: the handle bar's pairs are handed straight to it,
        // and `JunctionDetector` is pure arithmetic over them.
        let junctions = JunctionHandleController(ax: ax, engine: stepping, screens: screens,
                                                 settingsStore: settingsStore, minimums: minimums)
        self.junctions = junctions
        // It stands down for the whole of a Snap Assist phase: those surfaces cover the gaps a
        // handle would be offered in, and the windows parked behind them are off-screen. It also
        // stands down while a knob is moving three or four windows, two of which are its own, and
        // for the settling that follows its release — `isBusy` is `drag != nil`, and a knob's drag
        // outlives the mouse-up until every release animation has reported, which is precisely when
        // those windows stop moving — and while the Settings window is up, because the pill's panel
        // sits above ordinary windows and would otherwise draw over that window and swallow the
        // clicks meant for its sliders.
        //
        // Suspension is read on the poll, on a fresh press *and on every pass of a live drag*,
        // where it drops the gesture. That is why the Settings clause is safe rather than merely
        // convenient: the window can only be opened from the status item, which needs the mouse
        // button up, so no drag can be in flight when the clause first turns true.
        let handleBar = HandleBarController(ax: ax, engine: stepping, screens: screens,
                                            settingsStore: settingsStore, minimums: minimums,
                                            isSuspended: { [weak assist, weak junctions, weak self] in
                                                assist?.isActive == true || junctions?.isBusy == true
                                                    || self?.settingsWindow?.isUp == true
                                                    // For as long as Mission Control is up, not
                                                    // once. This poll would otherwise re-offer a
                                                    // pill a tenth of a second after the
                                                    // cancellation, drawn between two of Mission
                                                    // Control's scaled pictures of windows.
                                                    || self?.spaceWatcher?.isMissionControlShowing == true
                                                    // And for ~150 ms after it goes, while the
                                                    // windows are still growing back. A pill
                                                    // offered inside that window is drawn at a gap
                                                    // that is about to stop existing.
                                                    || self?.spaceWatcher?.isInReofferGrace(now: CACurrentMediaTime()) == true
                                                    // Command hides the pill so the window edge
                                                    // underneath can be resized natively.
                                                    || HandleSuppression.suppressed(
                                                        commandDown: self?.commandDown == true,
                                                        ownDragLive: self?.handleBar?.isDragging == true)
                                            })
        self.handleBar = handleBar
        // One poll feeds both features, and the junctions are computed from it before the pill
        // decides what it may offer — the knob's precedence is answered against this same snapshot.
        // The knobs are found from the snapshot, not from the pairs: a diagonal pair of windows is no
        // pair at all and the free end of a divider has no second divider to cross.
        handleBar.onPairs = { [weak junctions] _, windows, coverers in
            junctions?.update(windows: windows, coverers: coverers)
        }
        handleBar.claimsPoint = { [weak junctions] point in junctions?.claims(point) ?? false }
        // The dependency runs both ways, so this half is set once both exist.
        junctions.isSuspended = { [weak assist, weak handleBar, weak self] in
            assist?.isActive == true || handleBar?.isDragging == true
                || self?.settingsWindow?.isUp == true
                // For the reason the pill stands down: a knob is re-offered on the same poll.
                || self?.spaceWatcher?.isMissionControlShowing == true
                // The re-entry grace, for the pill's reason.
                || self?.spaceWatcher?.isInReofferGrace(now: CACurrentMediaTime()) == true
                // Command, for the pill's reason.
                || HandleSuppression.suppressed(commandDown: self?.commandDown == true,
                                                ownDragLive: self?.junctions?.isBusy == true)
        }
        // The pairs in hand describe where three or four windows used to be.
        junctions.onDragEnded = { [weak handleBar] in handleBar?.refresh() }
        // `WindowWriter.onOutcome` is one property on a shared writer, so its fan-out belongs here, the
        // same shape as `route(_:)`. Snap Assist's deck is its one consumer today: it is the only
        // subsystem that writes many windows at once and therefore the only one that has anything to
        // say about what a deal cost and how many of its posts the mailboxes replaced. The snap engine
        // and the reveal release still learn everything they need from the frame a `flush` reads back,
        // which is the per-window answer rather than the per-write one.
        writer.onOutcome = { [weak assist] outcome in assist?.writeOutcome(outcome) }
        handleBar.start()
        // The origin rides along from the resolution that chose the zone: Snap Assist runs after a
        // drop made from the snap bar and never after a plain edge, corner or top snap.
        dragSession?.onSnapped = { [weak assist] handle, zone, display, origin, limits in
            assist?.begin(after: zone, placed: handle, display: display, origin: origin, limits: limits)
        }
        // A display change drops the session and every overlay it put up, Snap Assist's areas
        // included — their cell frames were measured on a display that no longer exists, and the
        // windows it parked to clear that display have to come back.
        screens.onChange = { [weak self] in
            guard let self else { return }
            // Cancel first: it takes every preview down, so the prune that follows can never release a
            // panel that is still fading on a display the user can see.
            self.dragSession?.cancelSession()
            self.assist?.dismiss(.displayChange)
            // The handle bar's pairs and any live resize were measured against the old arrangement,
            // and the junctions were built out of those pairs.
            self.junctions?.cancel()
            self.handleBar?.cancel()
            self.preview?.pruneDisplays(keeping: self.screens.displays)
            self.customZones?.pruneDisplays(keeping: self.screens.displays)
        }
        // Nothing this app puts up survives the user leaving for another Space or for Mission
        // Control. Every surface is a `.moveToActiveSpace` panel and so leaves with its Space, but
        // leaving the panel behind is not enough: a pill or a knob merely on offer must not
        // outlive the arrangement it was measured against, and Snap Assist is the serious one — a
        // live phase holds real windows parked off-screen until something ends it, so a phase
        // abandoned on another Space strands them until the next drop or the next launch.
        //
        // `isLive` is what keeps the Mission Control poll off the idle path, and it asks the same
        // questions these features already ask each other above — with `isShowing` rather than
        // `isDragging`, because a pill nobody is holding still has to go.
        let spaceWatcher = SpaceWatcher(
            isLive: { [weak self] in
                guard let self else { return false }
                return self.assist?.isActive == true || self.dragSession?.isLive == true
                    || self.handleBar?.isShowing == true || self.junctions?.isShowing == true
            },
            displays: { [weak self] in self?.screens.displays.map(\.frame) ?? [] })
        spaceWatcher.onInterruption = { [weak self] interruption in self?.leftTheArrangement(interruption) }
        self.spaceWatcher = spaceWatcher
        spaceWatcher.start()
        // While the gap is on, a window that goes full-size — zoomed, or its title bar
        // double-clicked, or simply already full-size when the preference was turned on — is
        // brought back inside the working area with the gap around it. It stands down for exactly
        // the features the pill and the knob stand down for, plus the window drag itself: a
        // correction that landed in the middle of a gesture would be worse than the oversized
        // window it fixed.
        let oversize = OversizeWatcher(
            ax: ax, engine: stepping, writer: writer, screens: screens, settingsStore: settingsStore,
            minimums: minimums,
            isSuspended: { [weak self] in
                guard let self else { return true }
                return self.dragSession?.isLive == true || self.assist?.isActive == true
                    || self.handleBar?.isShowing == true || self.junctions?.isShowing == true
                    || self.settingsWindow?.isUp == true
                    || self.spaceWatcher?.isMissionControlShowing == true
                    || self.spaceWatcher?.isInReofferGrace(now: CACurrentMediaTime()) == true
            })
        self.oversize = oversize
        oversize.start()
        // The drag session stands down for the same level the two handle features do, and for a
        // symmetrical reason: the tap keeps delivering while Mission Control is up, so the one
        // cancellation could be undone by the next press. See `DragSessionController.isSuspended`.
        dragSession?.isSuspended = { [weak self] in self?.spaceWatcher?.isMissionControlShowing == true }
        mouse.handler = { [weak self] event in self?.route(event) }
        // The tap is re-enabled for us, but the events it missed are gone — a dropped drag event is
        // exactly the symptom this has to make visible.
        // The *reason* and a count. A timeout is this app holding the callback too long and is a
        // bug here; user input is the system interrupting a listening tap and is not. A line that
        // cannot tell them apart points at the wrong thing, and the count is what turns "it
        // happened" into "it is happening".
        mouse.onTapDisabled = { reason, count in
            switch reason {
            case .timeout:
                Logger.app.error("event tap disabled by TIMEOUT (\(count, privacy: .public)th this launch) and re-enabled; events lost")
            case .userInput:
                Logger.app.error("event tap disabled by USER INPUT (\(count, privacy: .public)th this launch) and re-enabled; events lost")
            }
        }
        Logger.app.info("engine started")
    }

    /// Layouts.json from the app resources, falling back to the compiled catalog. The file is
    /// hand-editable, so a failure has to name what is wrong with it: `DecodingError`
    /// already says which layout and why, and throwing that away would leave the user guessing.
    static func loadSnapBarLayouts() -> [Layout] {
        guard let url = Bundle.module.url(forResource: "Layouts", withExtension: "json") else {
            Logger.app.error("Layouts.json is not in the app resources; using the built-in layouts")
            return LayoutCatalog.snapBar
        }
        do {
            return try LayoutCatalog.decodeSnapBar(from: Data(contentsOf: url))
        } catch {
            Logger.app.error("Layouts.json could not be read: \(String(describing: error), privacy: .public); using the built-in layouts")
            return LayoutCatalog.snapBar
        }
    }

    /// Fan-out for mouse events, in the order the features may claim one. Command has its own branch and
    /// never reaches the mouse fan-out below: it is not a click and claims nothing on its own.
    func route(_ event: MouseEvents.Event) {
        // The drag session hears it too: during a window drag Command switches it to the custom areas
        // and Option grows the side halves to the middle of the display. Only Command reaches the
        // handles, so only Command is forwarded below.
        if case .flagsChanged(let command, _) = event {
            handleCommandChanged(command)
            dragSession?.handle(event)
            return
        }
        // Snap Assist first, and a click that ends a phase is consumed there: ending one puts every
        // parked window back, so passing that click on would arm a drag on whichever window the
        // restore just moved under the cursor rather than on anything the user aimed at.
        if case .down(let point) = event, assist?.handleGlobalMouseDown(at: point) == true { return }
        if case .moved(let point) = event { assist?.handleGlobalMouseMoved(at: point) }
        // Then the junction knobs, before the pills they take precedence over: at a crossing both
        // would otherwise answer for the same point and which windows moved depend on a pixel.
        if junctions?.handle(event) == true { return }
        // Then the handle bar. It consumes only the press that lands on a handle and the drag that
        // follows it; anything else travels on. Without that, a press on the pill would also
        // arm a window drag and the two state machines would run one gesture together.
        if handleBar?.handle(event) == true { return }
        dragSession?.handle(event)
    }

    /// Command (⌘) held down hides the pill and the knobs completely — no draw, no claim, no
    /// background cursor override — so a press on the divider underneath reaches the window itself
    /// and macOS's own native resize takes it from there. `HandleSuppression` is the rule; nothing
    /// else in the app reacts to Command.
    ///
    /// **Both halves of the key are needed.** The two `isSuspended` clauses wired above keep a handle
    /// from being *offered* again, but they are only read by a 10 Hz poll that stands still while the
    /// pointer has not moved for 2 seconds — so a handle already on screen under a motionless pointer
    /// would stay there. `hideForCommand()` is what takes it away on the keystroke itself, which is
    /// the whole reason Command is read from `flagsChanged` rather than from the next mouse event.
    ///
    /// On Command up nothing was cancelled to begin with, so only the pill needs telling: it
    /// recomputes at once and hands the junction knobs their pairs the way the poll always does.
    private func handleCommandChanged(_ command: Bool) {
        guard command != commandDown else { return }
        commandDown = command
        guard command else { handleBar?.refresh(); return }
        if HandleSuppression.suppressed(commandDown: true,
                                        ownDragLive: handleBar?.isDragging == true) {
            handleBar?.hideForCommand()
        }
        if HandleSuppression.suppressed(commandDown: true,
                                        ownDragLive: junctions?.isBusy == true) {
            junctions?.hideForCommand()
        }
    }

    /// The one way out, for both signals. The order is `screens.onChange`'s, and for the same
    /// reasons: the drag session goes first because it is what takes the preview and the snap bar
    /// down, then the phase, whose restore may write frames, then the two handle features, whose
    /// pairs describe an arrangement the user is no longer looking at.
    ///
    /// Nothing is put back afterwards, by design. Ending it is the whole requirement: the parked
    /// windows come home, the surfaces go, and the user starts again if they want it.
    ///
    /// Every call below is a no-op when that feature had nothing up — `dismiss` costs three boolean
    /// reads, `cancelSession` resets state that is already reset — which is what lets a Space change be
    /// answered unconditionally. The log line is not unconditional: a Space change arrives whether or
    /// not this app had anything on screen, and a line per Space change would bury the one that
    /// matters.
    private func leftTheArrangement(_ interruption: SpaceInterruption) {
        if dragSession?.isLive == true || assist?.isActive == true
            || handleBar?.isShowing == true || junctions?.isShowing == true {
            Logger.app.info("left the arrangement: \(interruption.rawValue, privacy: .public)")
        }
        // The cursor override stops on **both** interruptions, and first. It is a *global* override
        // asserted from an app that never activates, so a Space change that left it asserted would
        // put this app's resize cursor over somebody else's windows on the destination Space, with
        // nothing on screen to explain it and no pointer motion required to keep it there.
        // `stopCursorAssertion` does not take the panel down, which is why `cancel` follows: an
        // interruption means the handles are gone, not merely uncursored.
        handleBar?.stopCursorAssertion()
        junctions?.stopCursorAssertion()
        // Every surface leaves through the one 120 ms alpha fade, not through each feature's own
        // dismiss. The parked windows go straight home on this turn rather than fading, because
        // those writes are invisible.
        dragSession?.cancelSession(forInterruption: interruption)
        assist?.dismiss(SnapAssistController.EndReason(interruption))
        junctions?.cancel(forInterruption: true)
        handleBar?.cancel(forInterruption: true)
    }

    /// A fresh controller every time, so the pages re-read every grant and start at page one. The
    /// wizard is an ordinary window; activating the app here is the one thing that puts it in front, and
    /// it is in front only because it is the last window to open.
    func showOnboarding() {
        onboarding?.close()
        let wizard = OnboardingWindowController(onFinish: { OnboardingState.completed = true })
        wizard.othersNeedUsActive = { [weak self] in
            self?.settingsWindow?.isUp == true || self?.assist?.isActive == true
                || UpdateController.shared.windowIsUp
        }
        onboarding = wizard
        wizard.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Nothing tells an app that Accessibility was granted, so the engine waits on a poll. It does not
    /// touch the wizard: the grant ticks that row over on the wizard's own 2 s poll, and the window
    /// stays until the user finishes or closes it.
    private func pollPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.accessibilityGranted else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.startEngine()
            }
        }
    }
}
