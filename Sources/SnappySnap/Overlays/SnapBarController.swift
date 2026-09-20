import AppKit
import os
import SnapCore
import SystemAdapters

/// Shows the snap bar near the top of the display under the cursor while a drag is in progress.
@MainActor
final class SnapBarController {
    let layouts: [Layout]
    private let eligible: EligibleWindows
    private var panel: SnapBarPanel?
    /// What `panel` was built under. A panel is replaced, not reconfigured, when either changes: the
    /// elevated Space keeps a window until the window is gone, so a new window is the only way off it
    /// — which is what the private-interfaces switch going off has to mean, and what keeps the
    /// floating bar from inheriting the notch shape's Space — even within one drag, when the notch
    /// shape on one display and the floating bar on the next are the same setting. An island has one
    /// panel per display: the one on the display the drag left plays its departure while another
    /// arrives.
    private var panelRoute: PanelRoute?
    private struct PanelRoute: Hashable {
        var surface: SnapBarSurface
        var usesPrivateAPIs: Bool
        /// The display an island's panel was built on, nil for the floating bar and the notch shape.
        /// Those have one panel that moves between displays. An island leaves the display it is on
        /// through its own motion while another arrives elsewhere, which one panel cannot do.
        var islandDisplayID: UInt32?
    }
    /// Non-nil exactly while the bar is up: it is both the bar's layout and its visibility.
    private var shown: SnapBarGeometry?
    /// The island, up and collapsed: the notch appearance on a display with no camera housing, for as
    /// long as the drag is over that display, so there is something to aim at. Never set while
    /// `shown` is — a grown island is the bar — and never hit-tested.
    private var island: SnapBarGeometry?
    /// Every island panel built, by the route it was built under, kept for the life of the process.
    /// A drag that crosses between displays with no housing therefore pays a lookup however often it
    /// crosses — not a hosting view and a blur mask, on the main thread, inside the drag — and a
    /// display never holds two islands: the panel still departing there is the one presented again,
    /// and it retargets from what it is showing. Keyed by the whole route, so a panel built with
    /// private interfaces is never handed to a drag without them.
    private var islandPanels: [PanelRoute: SnapBarPanel] = [:]
    /// The pair partner, the dragged application's icon and the display the partner was found on.
    /// Resolved once per drag, in `beginSession`, and held until `endSession` — see there for why it
    /// is not re-asked per event. The icon is held rather than looked up when the bar is shown because
    /// the bar is shown again on every display change, and the dragged application cannot change
    /// mid-drag.
    private var session: (partner: SnapAssistController.Candidate,
                          draggedIcon: NSImage?,
                          displayID: UInt32)?

    /// Whether the bar is waiting out its arming dwell, and for which display. The rule; `dwellTask`
    /// is the clock that measures it.
    private var arming = SnapBarArming()
    /// The clock in flight, cancelled by everything that drops the dwell.
    private var dwellTask: Task<Void, Never>?
    /// What the clock will show the bar for when it runs out: the last event that passed the arming
    /// band. The clock has to carry it because no event arrives while the pointer holds still, which
    /// is exactly the gesture the dwell is waiting for.
    private var awaited: (cursor: CGPoint, display: DisplayInfo, settings: Settings)?
    /// Called with the cursor when the clock, not an event, showed the bar — the owner's chance to
    /// highlight the cell under the pointer, which no event will do until the pointer next moves.
    var onShownByDwell: ((CGPoint) -> Void)?

    /// The actuator a summoned bar taps. Held rather than reached for per tap so the one call site
    /// stays a line, and so a test can hand in a performer of its own.
    private let haptics: Haptics

    init(layouts: [Layout], ax: AccessibilityWindows, haptics: Haptics = Haptics()) {
        self.layouts = layouts
        self.eligible = EligibleWindows(ax: ax)
        self.haptics = haptics
    }

    /// The window a pair drop would place in the facing half, or nil when this drag has no partner.
    var partner: SnapAssistController.Candidate? { session?.partner }

    /// The pair cell the bar is currently showing, for the resolver. Nil whenever the bar is down, which
    /// is also when no hit can report one.
    var pairCell: PairCell? { shown?.pairCell }

    /// Finds the pair partner for a drag that has just been confirmed and holds it for the whole
    /// session.
    ///
    /// Called once per drag and never per event, which is the rule this feature turns on: it costs a
    /// `WindowList` snapshot and a bounded Accessibility scan — see
    /// `EligibleWindows.frontmostCandidate` for exactly how bounded — and none of that belongs on the
    /// path that serves the event tap while a button is down. Everything afterwards — arming the bar,
    /// moving it between displays, hit-testing it, drawing it — is pure arithmetic over this answer.
    ///
    /// The price is that a window focused *during* the drag is not the partner until the next drag.
    ///
    /// **A dragged window with no `windowID` gets no pair cell at all.** The id is the only key
    /// `WindowList`'s rule and the engine share, so without one the app cannot show that the partner it
    /// picked is a *different* window — the frontmost window during a drag is usually the dragged one,
    /// so an empty exclusion set pairs it with itself, and `SteppingSnapEngine.cancel` cannot dedupe two
    /// animations of a window it cannot name: two display links would write conflicting frames to one
    /// window for the length of the snap. Excluding by AX element identity would stop that particular
    /// collision and still leave the drop unrecordable, since `SnapRegistry` is keyed by id too. The
    /// cell is a convenience with a state the user already sees — no partner, no cell — so degrading to
    /// it costs nothing and is honest about what the app does not know.
    func beginSession(draggedWindowID: CGWindowID?, draggedPid: pid_t,
                      display: DisplayInfo, settings: Settings) {
        session = nil
        cancelDwell()
        guard settings.snapBar else { return }
        // The notch appearance's private pieces — the notch shape's and the island's alike — resolved
        // here — once per drag, before anything animates — rather than on the event that starts the
        // shape growing.
        if settings.snapBarAppearance != .bar {
            ElevatedSpace.shared.prepare()
            _ = BackdropLayers.isAvailable
        }
        guard let draggedWindowID else {
            Logger.drag.debug("the dragged window has no id; no pair cell this drag")
            return
        }
        guard let partner = eligible.frontmostCandidate(on: display, excluding: [draggedWindowID]) else {
            Logger.drag.debug("no window to pair with on display \(display.id); the bar has no pair cell")
            return
        }
        // The dragged application's icon, read here and only here: after the partner guard, so a drag
        // that will show no cell pays nothing for it, and once per drag, so no later event does.
        session = (partner, NSRunningApplication(processIdentifier: draggedPid)?.icon, display.id)
        Logger.drag.debug("pair partner for this drag: window \(partner.id)")
    }

    /// Ends the drag's hold on the partner and takes the bar and the island down. `hide()` alone is
    /// not enough — it runs whenever the cursor leaves the band mid-drag, and the partner has to
    /// survive that.
    func endSession() {
        session = nil
        standDown()
    }

    /// `endSession`, with the bar leaving through the shared 120 ms interruption fade instead of its
    /// own dismiss — except the island, which departs through its own motion: it is drawn to pass for
    /// the island it sits above, and that one plays the same departure at the same moment.
    func endSessionForInterruption() {
        session = nil
        cancelDwell()
        shown = nil
        island = nil
        panel?.model.highlighted = nil
        // What the panel is, not what was last recorded as shown: an island already departing has
        // been cleared from `shown` and `island` and must still not be faded.
        if panelRoute?.islandDisplayID != nil {
            panel?.departIsland(interrupted: true)
            Logger.drag.debug("interruption: the island departs")
        } else {
            panel?.fadeOutForInterruption()
        }
    }

    /// Takes the bar off the screen, and the island with it, keeping the session: ⌥ or ⌘ went down,
    /// the feature was switched off, or the drag ended. A grown island leaves in one transition —
    /// collapse, then departure — rather than being hidden and then removed, which would start the
    /// departure under a collapse still in flight.
    func standDown() {
        guard shown?.island != nil || island != nil else {
            hide()
            return
        }
        cancelDwell()
        shown = nil
        island = nil
        panel?.model.highlighted = nil
        panel?.departIsland(interrupted: false)
        Logger.drag.debug("island down")
    }

    /// Arms or hides the bar for this cursor position. A bar already up on this display keeps its
    /// geometry, so it never jitters; every other case is built from the display under the cursor,
    /// which is also what moves the bar to another display.
    ///
    /// Arming is not immediate: the pointer has to hold the arming band for
    /// `Settings.Fixed.snapBarArmingDwell` before the bar appears, so a drag that only crosses the
    /// band on its way to the top edge never flashes it. `SnapBarArming` is the rule and the `Task`
    /// below is the clock. The zone under the pointer is untouched by the wait — the top edge still
    /// resolves to Fill on the same event it always did.
    ///
    /// This runs on every drag event, so it builds nothing it does not need: while the bar is down,
    /// only the arming band matters, and that test needs no panel. Keep this path clear.
    func update(cursor: CGPoint, display: DisplayInfo, settings: Settings) {
        guard settings.snapBar else { standDown(); return }
        if let current = shown, current.displayID == display.id {
            if !current.shouldShow(cursor: cursor, display: display, visible: true) { hide() }
            return
        }
        let armed = SnapBarGeometry.isWithinArmingBand(cursor: cursor, display: display, settings: settings)
        switch arming.step(armed: armed, displayID: display.id, barShown: shown != nil) {
        case .cancel:
            hide()
            restIsland(on: display, settings: settings)
        case .showNow:
            showBar(on: display, settings: settings)
        case .startDwell:
            // The island is up while the dwell is waited out: the dwell decides only when it grows.
            restIsland(on: display, settings: settings)
            awaited = (cursor, display, settings)
            dwellTask?.cancel()
            let displayID = display.id
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Settings.Fixed.snapBarArmingDwell))
                guard !Task.isCancelled else { return }
                self?.dwellElapsed(for: displayID)
            }
        case .keepWaiting:
            restIsland(on: display, settings: settings)
            // The pointer moved within the region. The clock runs on; only what it will show the bar
            // for is refreshed, so the bar arrives built for where the pointer actually is.
            awaited = (cursor, display, settings)
        }
    }

    /// A clock ran out. `arming` decides whether it is still the clock being waited on: the pointer
    /// may have left the region or crossed to another display since, and either drops the wait.
    private func dwellElapsed(for displayID: UInt32) {
        dwellTask = nil
        guard arming.elapsed(displayID: displayID), let awaited else { return }
        showBar(on: awaited.display, settings: awaited.settings)
        // The tap lives here rather than in `showBar` because `showBar` is also where a bar already up
        // arrives when it follows the pointer onto another display, and that move is silent: moving a
        // bar is not summoning one. Only a clock that ran out means a bar that was not there.
        //
        // Asked for, never confirmed: a Mac with no Force Touch trackpad has no actuator, and macOS
        // will not say so. The log records the request, which is all there is to record.
        let wanted = awaited.settings.hapticFeedback
        haptics.tap(enabled: wanted)
        Logger.drag.debug("snap bar summoned on display \(displayID); haptic \(wanted ? "requested" : "off")")
        onShownByDwell?(awaited.cursor)
    }

    /// Builds the bar for this display and puts it up. The pair cell's condition is re-read here, so
    /// a bar shown by the clock is built exactly as one shown by an event.
    private func showBar(on display: DisplayInfo, settings: Settings) {
        show(SnapBarGeometry(layouts: layouts, display: display, settings: settings,
                             pairCell: pairCell(for: display, settings: settings)), settings: settings)
    }

    /// Drops the arming dwell, clock and all. `hide()` does this before its own early return, because
    /// a pending dwell is exactly the state in which there is no bar for `hide()` to take down.
    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        awaited = nil
        arming.cancel()
    }

    /// Keeps the island up on a display that has no camera housing, and takes it down anywhere else.
    /// On the hidden path of every drag event, so the common answers come first and build nothing:
    /// the floating bar and a display with a housing have no island, and an island already on this
    /// display is left alone.
    private func restIsland(on display: DisplayInfo, settings: Settings) {
        guard settings.snapBarAppearance.surface(on: display) == .island else { removeIsland(); return }
        guard island?.displayID != display.id else { return }
        let geometry = SnapBarGeometry(layouts: layouts, display: display, settings: settings,
                                       pairCell: pairCell(for: display, settings: settings))
        island = geometry
        let panel = panel(for: settings, geometry: geometry)
        panel.model.geometry = geometry
        panel.model.highlighted = nil
        panel.presentIsland(geometry, expanded: false)
        Logger.drag.debug("island up on display \(display.id)")
    }

    private func removeIsland() {
        guard island != nil else { return }
        island = nil
        // The panel absorbs a repeat: departing twice does nothing, and presenting a departing panel
        // again retargets it.
        panel?.departIsland(interrupted: false)
        Logger.drag.debug("island down: the display under the pointer has a housing")
    }

    /// The pair cell's condition, read from the answer `beginSession` took: another eligible window
    /// **on the display under the cursor**.
    ///
    /// The partner was found on the display the drag was confirmed on, so a drag that crosses to another
    /// display gets no pair cell there. That is the honest answer and the cheap one: the alternative is
    /// either to offer a pairing with a window that is not on the display the user is looking at, or to
    /// run an Accessibility sweep mid-drag to find one that is, which this path may not do.
    private func pairCell(for display: DisplayInfo, settings: Settings) -> PairCell? {
        // `session?.displayID == display.id` is false when there is no session at all, which is the
        // other half of "no partner, no cell".
        PairCell(hasPartner: session?.displayID == display.id, display: display, gap: settings.gap)
    }

    /// Pure: what the cursor is over, nil while the bar is hidden. Safe on the resolution path.
    func hit(at point: CGPoint) -> SnapBarHit? { shown?.hit(point) }

    func highlight(_ hit: SnapBarHit?) {
        panel?.model.highlighted = hit
    }

    func hide() {
        cancelDwell()
        guard let g = shown else { return }
        shown = nil
        panel?.model.highlighted = nil
        if g.island != nil {
            // The island goes back to its capsule and stays for the rest of the drag.
            panel?.collapseIsland()
            island = g
            Logger.drag.debug("island collapsed on display \(g.displayID)")
        } else if g.notch != nil {
            panel?.collapseNotch()
        } else {
            panel?.dismiss()
        }
    }

    /// The panel for this route. The floating bar's and the notch shape's is replaced when the route
    /// has changed since it was built; an island's is looked up, and built the first time.
    private func panel(for settings: Settings, geometry: SnapBarGeometry) -> SnapBarPanel {
        let route = PanelRoute(surface: geometry.surface, usesPrivateAPIs: settings.usePrivateAPIs,
                               islandDisplayID: geometry.island == nil ? nil : geometry.displayID)
        if let panel, panelRoute == route { return panel }
        if let old = panel { leave(old) }
        let next = islandPanels[route] ?? SnapBarPanel(model: SnapBarModel(geometry: geometry))
        if route.islandDisplayID != nil { islandPanels[route] = next }
        panel = next
        panelRoute = route
        return next
    }

    /// Takes the panel being left off the screen: at once, unless it holds an island, which departs
    /// through its own motion on the display it is on and stays in `islandPanels` for next time.
    private func leave(_ old: SnapBarPanel) {
        if panelRoute?.islandDisplayID != nil {
            old.departIsland(interrupted: false)
        } else {
            old.orderOut(nil)
        }
    }

    private func show(_ g: SnapBarGeometry, settings: Settings) {
        shown = g
        island = nil
        let panel = panel(for: settings, geometry: g)
        panel.model.geometry = g
        // Read once here, with the geometry they belong to: both icons are already in hand from
        // `beginSession`, so drawing them costs nothing further. Icons, never live thumbnails. They
        // are cleared together with the cell — a bar without a pair cell draws neither.
        panel.model.draggedIcon = g.pairCell == nil ? nil : session?.draggedIcon
        panel.model.partnerIcon = g.pairCell == nil ? nil : partner?.icon
        panel.model.highlighted = nil
        if g.island != nil {
            panel.presentIsland(g, expanded: true)
        } else if g.notch != nil {
            panel.presentNotch(g, expanded: true)
        } else {
            panel.present(frame: CoordinateSpace.cocoaRect(fromCG: g.frame))
        }
    }
}
