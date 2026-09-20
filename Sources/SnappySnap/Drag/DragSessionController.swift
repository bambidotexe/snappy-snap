import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// State machine: idle → armed (mouse down on a window) → dragging (moved) → snap on mouse up.
@MainActor
final class DragSessionController {
    enum Phase {
        case idle
        case armed(WindowHandle, CGRect)
        case dragging(WindowHandle)
        /// A drag the user is still holding whose Space changed under it, with where the pointer
        /// stood when the change was caught and when that was. `DragResumption` says which drag
        /// event brings it back.
        case suspended(WindowHandle, pointer: CGPoint, since: CFTimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// Where the last drag event put the pointer. The interruption arrives from `SpaceWatcher`'s
    /// poll rather than from a mouse event, so this is the only pointer the suspension has to
    /// measure its travel from — and at 120 Hz it is at most 8 ms old.
    private var lastPointer: CGPoint = .zero

    /// The window this gesture holds, which is what its arrangements name the dragged box by.
    private var currentWindowID: CGWindowID? {
        switch phase {
        case .idle: nil
        case .armed(let handle, _), .dragging(let handle), .suspended(let handle, _, _): handle.windowID
        }
    }

    /// Whether there is a gesture to interrupt. `armed` counts: the button is down on a window, and
    /// the one gesture that can open Mission Control without letting go of it is a drag to the very
    /// top edge, which is this app's maximize zone. **`suspended` counts too**, and has to: the user
    /// still has the window in their hand, so the oversize watcher must stay down and the Space
    /// poll must stay at 60 Hz to catch the next slide as fast as it caught this one.
    var isLive: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// True while Mission Control or App Exposé has the screen. Set by `AppDelegate`, and **a level
    /// rather than the one cancellation**, for the reason the handle bar takes one: the event tap
    /// goes on delivering while those surfaces are up, so a press after the cancellation
    /// would arm a fresh session on a window the user is looking at a *picture* of, and the first
    /// frame change would put the preview and the snap bar back with no second rising edge left to
    /// take them down. Nothing here is interpretable while the arrangement on screen is a set of
    /// thumbnails, so the whole gesture is declined until they are gone.
    var isSuspended: @MainActor () -> Bool = { false }
    private let ax: AccessibilityWindows
    private let writer: WindowWriter
    private let screens: any ScreensProviding
    private let settingsStore: SettingsStore
    private let state: SnapState
    private let preview: ZonePreviewController
    private let engines: EngineRouter
    private let snapBar: SnapBarController
    private let minimums: MinimumSizeStore
    private let coordinator: ArrangementCoordinator
    private let customOverlay: CustomZonesController
    /// Whether Command is down, as the last `flagsChanged` said. Kept whatever the phase is, so a drag
    /// that begins with the key already held starts in the custom mode, and one that outlives a Space
    /// change or Mission Control still knows the key's state when it comes back.
    private var commandHeld = false
    /// Whether Option is down, as the last `flagsChanged` said. Recorded like `commandHeld`; it means
    /// something only while Command is not offering the custom areas.
    private var optionHeld = false
    /// Whether Command is offering the custom areas *right now*: the key is down and the feature is on.
    /// Read rather than `commandHeld` everywhere a decision is made, so that switching the feature off
    /// mid-drag is the same as letting go of the key.
    private var customModeActive: Bool { commandHeld && settingsStore.settings.customAreas }
    /// Whether Option is growing the side halves *right now*: the key is down, the feature and the side
    /// halves are on, and Command is not offering the custom areas. The snap bar is off the screen and
    /// out of the resolution for as long as this holds.
    private var optionModeActive: Bool {
        optionHeld && settingsStore.settings.optionHalves && settingsStore.settings.sideHalves
            && !customModeActive
    }
    /// The stored JSON as last parsed. The text cannot change under a drag, so this is one parse per
    /// edit and not one per event.
    private var parsedCustomZones: (json: String, zones: CustomZones?)?
    /// The previews of the windows this drop **also** moves — a neighbour giving room so the dragged
    /// window can have its minimum. The same panel type and level the zone preview uses, from the
    /// pool the handle drag draws its outcome with, rather than a second multi-window preview.
    private let neighbourPreviews = WindowPreviewGroup()
    /// Every other window on screen, read once at drag confirmation and held for the gesture. One
    /// `WindowList` call per gesture, no Accessibility at all, and nothing on the drag path but
    /// arithmetic.
    ///
    /// Held rather than re-read on every event, and the cost of that is a window snapped by something
    /// else *during* this drag — which cannot happen, because this app is the only thing snapping and
    /// the user has one mouse button down.
    private var occupants: [SnapOccupant] = []
    /// Which of `occupants` stand beside a drop on a given display (`NeighbourEvidence`), worked out
    /// the first time a zone of that display is resolved and kept for the gesture: the answer depends
    /// on the display's working area and on nothing that changes during a drag.
    private var neighboursByDisplay: [UInt32: [SnapOccupant]] = [:]
    /// The dragged window's floor — its application's row raised by its own floor — or nil when nobody knows it. Nil is what keeps the preview
    /// honest about its own limits: the arrangement is then solved with the presumed floor, and the
    /// landing may differ.
    private var draggedMinimum: CGSize?
    /// The pair partner's minimum, read at the same moment and for the same reason — a pair drop
    /// places both halves, so the divider between them has to stop where *either* window stops.
    private var partnerMinimum: CGSize?
    /// The last zone resolved, with what it resolved to. `resolveZone` runs on every drag event and
    /// the answer for one zone cannot change while `occupants` is held, so the arrangement is built
    /// and solved once per zone rather than once per event.
    private var lastResolved: ResolvedZone?
    /// How many times the user has left the arrangement — a Space change, Mission Control — since
    /// launch. A drop's corrections stop at the first one after it: everything this app does stands
    /// down when the screen is no longer the arrangement, and a correction is a new write.
    private var interruptions = 0
    private var currentZone: Zone?
    /// The companion half a pair drop also previews. Part of the preview's state, not a second
    /// zone: a pair hover and a plain halves hover resolve to the *identical* `Zone` (halves[0]),
    /// so `currentZone` alone cannot tell them apart and the partner's preview would be left on
    /// screen.
    private var currentCompanion: Zone?
    private var lastFrameCheck: CFTimeInterval = 0
    /// The dragged window's frame as of the last throttled read — the only Accessibility read on
    /// the drag path. The preview's appear-morph and the drop both use it instead of reading.
    private var lastKnownFrame: CGRect?
    /// The window whose drag-away restore is still in the writer's hands, from the post to the flush
    /// that answers it.
    ///
    /// **A restore in flight suspends this drag's Accessibility reads; it does not race them.** The
    /// global constraint is that the main thread makes no Accessibility read of a window with posts
    /// in flight — four such reads are measured to take the tap's thread from 121 Hz to 83.5 Hz —
    /// and the restore is the one moment in a drag when this controller has posts of its own
    /// outstanding. So `readFrame` declines for that window until the flush answers, and
    /// `lastKnownFrame` is fed from the writer's outcome instead of from a read. It costs the first
    /// ~100 ms of the preview's morph a slightly stale frame; `mouseUp` re-resolves at the release
    /// point regardless.
    private var restoringWindow: WindowHandle?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Called once a drop's arrangement has settled — the drag session is already back to idle by
    /// then. `AppDelegate` starts Snap Assist from here, and the `ZoneOrigin` is what tells it whether
    /// to: only a drop made from the snap bar starts a phase. The origin travels with the resolution
    /// that produced the zone; the bar is never asked again afterwards, because the bar is gone by the
    /// time the window lands. The `SizeLimits` are the dragged window's, with whatever its landing
    /// revealed: the phase's arrangement starts from them.
    var onSnapped: (@MainActor (WindowHandle, Zone, DisplayInfo, ZoneOrigin, SizeLimits) -> Void)?

    /// A zone the cursor resolved to, with where it came from and — for the pair cell — the facing
    /// half the same drop fills. They travel together from `resolveZone` to the drop so that the
    /// Snap Assist trigger and the pair's second placement both read the `SnapBarHit` that chose
    /// the zone, rather than re-deriving either from a bar that has since been hidden.
    private struct ResolvedZone {
        /// The **nominal** cell: it is the zone's identity, what `setZone` compares and what Snap
        /// Assist's layout is read from. Where the window actually goes is `frame`.
        let zone: Zone
        let origin: ZoneOrigin
        /// The nominal half of the pair partner, as the resolver gave it: part of this resolution's
        /// identity, beside `zone`.
        let nominalPartnerZone: Zone?
        /// The partner's half carrying the frame the arrangement gives it.
        let partnerZone: Zone?
        /// Every window this drop places, and the frame each is given.
        let arrangement: Arrangement
        let solution: ArrangementSolution
        let dragged: ArrangementBox.ID
        /// The zone after taking what is free, on a drop that does: a side edge or a corner. The top
        /// takes nothing and this is its zone unchanged.
        let freeFrame: CGRect?
        /// Windows other than the dragged one and the pair partner that this drop moves.
        let neighbours: [MovedNeighbour]

        /// The frame the dragged window is asked for.
        var frame: CGRect { solution.frames[dragged] ?? zone.frame }
    }

    /// A window standing beside the drop that the arrangement moves: from where, to where.
    private struct MovedNeighbour {
        let windowID: CGWindowID
        let pid: pid_t
        let from: CGRect
        let frame: CGRect
    }

    init(ax: AccessibilityWindows, writer: WindowWriter, screens: any ScreensProviding,
         settingsStore: SettingsStore, state: SnapState, minimums: MinimumSizeStore,
         preview: ZonePreviewController, engines: EngineRouter, coordinator: ArrangementCoordinator,
         snapBar: SnapBarController, customOverlay: CustomZonesController) {
        self.customOverlay = customOverlay
        self.ax = ax
        self.writer = writer
        self.screens = screens
        self.settingsStore = settingsStore
        self.state = state
        self.minimums = minimums
        self.preview = preview
        self.engines = engines
        self.coordinator = coordinator
        self.snapBar = snapBar
        snapBar.onShownByDwell = { [weak self] cursor in self?.barShownByDwell(at: cursor) }
    }

    /// The bar was put up by its arming clock rather than by an event, so no `update(cursor:)` ran to
    /// highlight the cell under the pointer and none will until the pointer next moves. Do it here,
    /// from where the pointer last was, by exactly the expression `update` uses.
    private func barShownByDwell(at cursor: CGPoint) {
        guard case .dragging = phase, !customModeActive else { return }
        snapBar.highlight(resolveZone(at: cursor) == nil || optionModeActive ? nil : snapBar.hit(at: cursor))
    }

    func handle(_ event: MouseEvents.Event) {
        // Recorded before anything can decline the event: the key's state is a fact about the keyboard,
        // and must not go stale because Mission Control had the screen when it changed.
        if case .flagsChanged(let command, let option) = event {
            commandHeld = command
            optionHeld = option
        }
        // A live gesture is dropped once — the session and its overlays go rather than freeze — and
        // every gesture after it is declined until the screen is the user's again.
        guard !isSuspended() else {
            switch phase {
            case .idle: return
            // Mission Control outranks a suspension: the drag does not come back. Only the phase is
            // dropped, because the Space change that suspended it already took every surface down
            // and `cancelSession` would cut short the 120 ms fade that is still playing.
            case .suspended: phase = .idle
            case .armed, .dragging: cancelSession()
            }
            return
        }
        switch event {
        case .down(let point): mouseDown(at: point)
        case .dragged(let point): mouseDragged(to: point)
        case .up(let point): mouseUp(at: point)
        case .moved: break
        case .flagsChanged: commandChanged()
        }
    }

    /// An interruption routes the two surfaces off the screen through the shared 120 ms fade instead
    /// of their own dismiss: Mission Control or a Space change takes every surface in the app down in
    /// one event, and surfaces leaving one event at three speeds read as three faults. The state
    /// reset below is identical whatever ended the session — everything the new Space's arrangement
    /// has to be re-read is dropped here, and the resumption re-reads it.
    ///
    /// The one difference is the phase. **A Space change suspends a confirmed drag instead of ending
    /// it**, because macOS's own hold-at-the-edge gesture switches Space with the button still down
    /// and the drag that lands is the same drag. Everything else — Mission Control, a display change,
    /// an ordinary cancel — goes to idle, and so does an `armed` press, which has no drag to bring
    /// back: a drag is confirmed by a moved origin and this one never moved.
    func cancelSession(forInterruption interruption: SpaceInterruption? = nil) {
        switch phase {
        case .dragging(let handle), .suspended(let handle, _, _):
            if interruption == .spaceChange {
                phase = .suspended(handle, pointer: lastPointer, since: CACurrentMediaTime())
                Logger.drag.debug("drag of window \(handle.windowID ?? 0) suspended by a Space change")
            } else {
                phase = .idle
            }
        case .idle, .armed:
            phase = .idle
        }
        currentZone = nil
        currentCompanion = nil
        lastKnownFrame = nil
        occupants = []
        neighboursByDisplay = [:]
        lastResolved = nil
        draggedMinimum = nil
        partnerMinimum = nil
        // Otherwise a drag starting within 1/120 s of the last session's read skips its first read.
        lastFrameCheck = 0
        if interruption != nil {
            interruptions &+= 1
            preview.dismissForInterruption()
            neighbourPreviews.dismissForInterruption()
            snapBar.endSessionForInterruption()
            customOverlay.dismissForInterruption()
            return
        }
        preview.show(nil)
        customOverlay.dismiss()
        neighbourPreviews.dismiss()
        // Not `hide()`: that runs whenever the cursor leaves the bar's band mid-drag, and the pair
        // partner has to survive that. The session's hold on it ends here and nowhere else.
        snapBar.endSession()
    }

    private func mouseDown(at point: CGPoint) {
        // A press means the button is down, so whatever the suspension was still holding for is over
        // — the mouse-up that would have ended it never reached the tap. Without this the suspension
        // would outlive the gesture and decline every press after it.
        if case .suspended(let handle, _, _) = phase {
            Logger.drag.debug("press while suspended: window \(handle.windowID ?? 0) never saw its mouse up")
            phase = .idle
        }
        guard case .idle = phase else { return }
        guard let handle = ax.window(at: point) else {
            Logger.drag.debug("press at \(point.x, format: .fixed(precision: 0)),\(point.y, format: .fixed(precision: 0)): no window under it; not arming")
            return
        }
        guard handle.pid != ownPID else { return }
        // The two Accessibility reads below run on the main thread inside the tap's own callback,
        // so if this window is one the writer is still writing — a snap animating, a deck dealing
        // back, a handle release — they queue behind its worker and can cost the tap up to the
        // 0.25 s messaging timeout. **The press is declined instead**: this is the one arming path,
        // there is no frame to arm from that is not either a read or already stale (the window is
        // mid-animation and moving), and the whole window of exposure is the tail of an animation
        // the press itself is about to stop. The user lets go and presses again.
        //
        // Asked *before* `engines.cancel`, and that ordering is the point: `cancel` makes the writer
        // forget the window while its current write is still inside Accessibility, so afterwards
        // `hasPending` answers false for a window that would still block the read.
        let busy = writer.hasPending(handle)
        engines.cancel(windowID: handle.windowID)
        guard !busy else {
            Logger.drag.debug("window \(handle.windowID ?? 0) has posts in flight; not arming this press")
            return
        }
        guard ax.isResizable(handle), let frame = ax.frame(of: handle) else {
            Logger.drag.debug("window \(handle.windowID ?? 0) of pid \(handle.pid) is not resizable or gave no frame; not arming")
            return
        }
        phase = .armed(handle, frame)
        lastKnownFrame = frame
    }

    private func mouseDragged(to point: CGPoint) {
        lastPointer = point
        switch phase {
        case .idle:
            return
        case .armed(let handle, let startFrame):
            // The one place the read has to come first: a moved origin is what confirms the drag,
            // and there is no preview to present before it.
            guard let frame = readFrame(of: handle), frame.origin != startFrame.origin else { return }
            // Dragging the left or top resize border moves the origin too; only a move keeps the size.
            guard frame.size == startFrame.size else {
                Logger.drag.debug("resize gesture on window \(handle.windowID ?? 0), not a move; ignoring")
                cancelSession()
                return
            }
            phase = .dragging(handle)
            Logger.drag.debug("drag confirmed, window \(handle.windowID ?? 0)")
            beginDrag(handle, startFrame: startFrame, frame: frame, cursor: point)
            // The pair partner is resolved here, once, and held for the rest of the drag. This is
            // the one event where an Accessibility sweep is affordable — it happens once per
            // gesture, not per event — and it is what keeps every later event free of one. Before
            // `update`, because `update` may arm the bar on this very event and the bar's width and
            // first cell depend on the answer.
            if let display = screens.display(containing: point) {
                snapBar.beginSession(draggedWindowID: handle.windowID, draggedPid: handle.pid,
                                     display: display, settings: settingsStore.settings)
                // In the same one-per-gesture breath and for the same reason: the window list and
                // the minimum store are read here, once, so every later event is arithmetic. After
                // `beginSession`, because the pair partner is what `partnerMinimum` is read for.
                captureFillEvidence(handle, frame: frame)
            }
            update(cursor: point)
        case .dragging(let handle):
            // Order matters: the preview is presented from the cache first, so no Accessibility
            // round trip ever sits in front of the frame that first shows it. The refresh then
            // happens after, for the next event's morph and for the drop.
            update(cursor: point)
            readFrame(of: handle)
        // The Space slid out from under this drag and the user never let go. It comes back on the
        // first event that is both late enough and far enough, rebuilt exactly as the `armed`
        // transition above builds a new one — the windows on this Space are not the ones the
        // session was holding, and every one of them was dropped by `cancelSession`.
        case .suspended(let handle, let origin, let since):
            let elapsed = CACurrentMediaTime() - since
            let travel = DragResumption.travel(from: origin, to: point)
            guard DragResumption.mayResume(elapsed: elapsed, travel: travel) else { return }
            // The window came across with the Space, so the cached frame is stale. A nil is the
            // 1/120 s gate and nothing else; the next drag event tries again.
            guard let frame = readFrame(of: handle) else { return }
            phase = .dragging(handle)
            Logger.drag.debug("drag of window \(handle.windowID ?? 0) resumed after \(elapsed, format: .fixed(precision: 3)) s, pointer moved \(travel, format: .fixed(precision: 1)) pt")
            // No `beginDrag`: the drag-away restore is a one-shot at the start of a gesture, and
            // this window was dragged away a Space ago.
            if let display = screens.display(containing: point) {
                snapBar.beginSession(draggedWindowID: handle.windowID, draggedPid: handle.pid,
                                     display: display, settings: settingsStore.settings)
                captureFillEvidence(handle, frame: frame)
            }
            update(cursor: point)
        }
    }

    /// Re-resolves at the release point, because a fast flick can skip the last drag event, but
    /// without presenting: showing the preview here would flash it for the frame before the drop.
    private func mouseUp(at point: CGPoint) {
        // Under Command the release goes to the custom area under the pointer, and to nothing when there
        // is none: Command never falls back to the ordinary zones.
        if case .dragging(let handle) = phase,
           let resolved = customModeActive ? resolveCustomArea(at: point) : resolveZone(at: point) {
            finish(handle, resolved: resolved)
        }
        // A release while suspended places nothing: there is no zone to resolve, because the session
        // was never rebuilt against this Space. Only the phase is dropped — the Space change already
        // took every surface down, and `cancelSession` would cut short the 120 ms fade doing it.
        if case .suspended = phase {
            phase = .idle
            return
        }
        cancelSession()
    }

    /// The one Accessibility read of the drag path, at most once per frame and bounded by the
    /// 0.25 s messaging timeout. It also refreshes `lastKnownFrame`, so the paths that must not
    /// call Accessibility — the preview's first appearance and the drop — always have a fresh frame.
    @discardableResult
    private func readFrame(of handle: WindowHandle) -> CGRect? {
        // A restore of this window is in the writer's mailbox: no main-thread read of it until the
        // flush has answered (see `restoringWindow`). Returning nil is what the 120 Hz gate below
        // already does on most events, so every caller here tolerates it.
        guard restoringWindow != handle else { return nil }
        let now = CACurrentMediaTime()
        guard now - lastFrameCheck >= 1.0 / 120 else { return nil }
        lastFrameCheck = now
        guard let frame = ax.frame(of: handle) else { return nil }
        lastKnownFrame = frame
        return frame
    }

    /// The drag-away restore: opt-in, immediate, cursor keeps its relative x. `startFrame` is where
    /// the window sat at mouse-down: the registry's ±2 pt check must run against it, not against
    /// `frame`, which the drag has already moved. `frame` only drives the cursor math.
    private func beginDrag(_ handle: WindowHandle, startFrame: CGRect, frame: CGRect, cursor: CGPoint) {
        guard settingsStore.settings.restoreOnDragAway, let id = handle.windowID,
              let entry = state.registry.entry(for: id, currentFrame: startFrame) else { return }
        let pre = entry.preSnapFrame
        let relativeX = (cursor.x - frame.minX) / max(frame.width, 1)
        let restored = CGRect(x: cursor.x - relativeX * pre.width, y: frame.minY, width: pre.width, height: pre.height)
        let asked = restored.roundedToPoints()
        // Through the writer. This runs inside the tap's own callback, where a synchronous
        // `setFrame` is four or five Accessibility round trips — measured at up to 1.25 s against
        // an application that has stopped answering, on the run loop that serves the tap. A `begin`
        // seeds the writer with this drag's current frame, which is what decides whether the size
        // or the position is written first; the post costs 0.01 ms and the drag goes on.
        writer.begin(handle, current: frame)
        writer.post(WindowWriter.Request(frame: asked, readBack: true), to: handle)
        // Optimistic: the very next thing this event does is present the preview's appear-morph
        // `from: lastKnownFrame`, and the window is about to be `asked` rather than the snapped
        // frame it still has. The read-back below corrects it.
        lastKnownFrame = asked
        restoringWindow = handle
        writer.flush(handle) { [weak self] outcome in
            guard let self, self.restoringWindow == handle else { return }
            // Cleared whatever the answer — a nil outcome is a cancel, and an outcome with no
            // `landedFrame` is an app that would not say where it ended up. Either way the writer owes
            // this window nothing more and the reads may resume.
            self.restoringWindow = nil
            // Only into the session that asked for it: by the time this answers the gesture may be
            // over, or a different window may be under the cursor.
            guard let landed = outcome?.landedFrame,
                  case .dragging(let current) = self.phase, current == handle else { return }
            self.lastKnownFrame = landed
        }
        state.registry.remove(id)
    }

    /// Everything the drag shows: the bar's own visibility first, so a bar that appears on this event
    /// can already be hit, then the zone it resolves to, then the highlight of the cell it came from.
    private func update(cursor: CGPoint) {
        if customModeActive {
            updateCustomAreas(cursor: cursor)
            return
        }
        // Costs a `guard` when nothing is up. It is what takes the areas away if the feature is
        // switched off with the key still held, which no `flagsChanged` would announce.
        customOverlay.dismiss()
        if optionModeActive {
            snapBar.standDown()
        } else if let display = screens.display(containing: cursor) {
            snapBar.update(cursor: cursor, display: display, settings: settingsStore.settings)
        } else {
            snapBar.hide()
        }
        let resolved = resolveZone(at: cursor)
        snapBar.highlight(resolved == nil || optionModeActive ? nil : snapBar.hit(at: cursor))
        setZone(resolved)
    }

    /// Command went down or up. Only a confirmed drag has anything to switch: pressing it earlier is
    /// picked up by `update` when the drag confirms. With the feature switched off this is a key that
    /// means nothing to a window drag, and the branch below leaves the ordinary zones exactly as they
    /// were.
    ///
    /// Down takes the ordinary preview, its neighbours' previews and the snap bar off the screen and
    /// draws the custom areas in their place; up takes the areas away and lets `update` bring the bar
    /// and the zone back exactly as a pointer move would — from where the pointer stands now, since
    /// the key can change with the pointer standing still.
    private func commandChanged() {
        guard case .dragging = phase else { return }
        if customModeActive {
            snapBar.highlight(nil)
            snapBar.standDown()
            setZone(nil)
        } else {
            customOverlay.dismiss()
        }
        update(cursor: lastPointer)
    }

    /// Draws every area that resolves on the display under the pointer, and fills the one it is in.
    /// Nothing at all when the text is empty or invalid, or nothing resolves on this display.
    private func updateCustomAreas(cursor: CGPoint) {
        guard let display = screens.display(containing: cursor),
              let areas = customAreas(on: display), !areas.rects.isEmpty else {
            customOverlay.dismiss()
            return
        }
        customOverlay.show(areas.rects, filled: areas.index(at: cursor), on: display)
    }

    private func customAreas(on display: DisplayInfo) -> CustomAreas? {
        let json = settingsStore.customZonesJSON
        if parsedCustomZones?.json != json {
            parsedCustomZones = (json, CustomZones.parse(json).zones)
        }
        return parsedCustomZones?.zones?.areas(on: display, gap: settingsStore.settings.gap)
    }

    /// The drop under Command: the area holding the pointer *at the release point*, as one box in an
    /// arrangement of its own, so it is placed by the same `finish` — the coordinator, the engine, the
    /// writer, the 0.25 s ease — as every other zone. `.screenEdge` because no Snap Assist follows.
    private func resolveCustomArea(at point: CGPoint) -> ResolvedZone? {
        guard let display = screens.display(containing: point),
              let rect = customAreas(on: display)?.area(at: point) else { return nil }
        let draggedID = currentWindowID ?? 0
        let limits = SizeLimits(minimum: MinimumSizePolicy.presumed(draggedMinimum))
        let dragged = ArrangementBox(id: .window(draggedID), preferred: rect, limits: limits)
        let arrangement = Arrangement(area: display.visibleFrame, gap: settingsStore.settings.gap,
                                      aligned: false, boxes: [dragged])
        let zone = Zone(displayID: display.id, layout: LayoutCatalog.fill, cellIndex: 0, frame: rect)
        return ResolvedZone(zone: zone, origin: .screenEdge, nominalPartnerZone: nil, partnerZone: nil,
                            arrangement: arrangement, solution: arrangement.solve(), dragged: dragged.id,
                            freeFrame: nil, neighbours: [])
    }

    /// Pure resolution, no overlay: `update` presents what this returns, mouse-up only snaps to it.
    /// `snapBar.hit` is a hit test against the bar's own geometry, with no side effect and no
    /// Accessibility call, so it belongs here; showing and highlighting the bar does not.
    private func resolveZone(at cursor: CGPoint) -> ResolvedZone? {
        guard let display = screens.display(containing: cursor) else { return nil }
        let settings = settingsStore.settings
        let resolution = ZoneResolver.resolve(
            cursor: cursor, display: display, sharedEdges: screens.sharedEdges(of: display),
            barHit: optionModeActive ? nil : snapBar.hit(at: cursor),
            snapBarLayouts: snapBar.layouts, pairCell: snapBar.pairCell,
            gap: settings.gap, settings: settings,
            stickyBand: currentZone == nil ? 0 : ZoneResolver.releaseHysteresis,
            optionHeld: optionModeActive
        )
        guard let resolution else { return nil }
        let zone = resolution.zone
        if let last = lastResolved, last.zone == zone, last.origin == resolution.origin,
           last.nominalPartnerZone == resolution.partnerZone {
            return last
        }
        let resolved = arrange(resolution, display: display, gap: settings.gap, fills: settings.snapFill)
        lastResolved = resolved
        return resolved
    }

    /// What this drop will *actually* place, as one arrangement — pure, against state read once at drag
    /// confirmation: no Accessibility, no window list, nothing but arithmetic.
    ///
    /// **Who is in the arrangement is the whole difference between the kinds of drop.** A cell of
    /// the snap bar is the user redoing the working area, so it holds the chosen layout and the dragged
    /// window and nothing that was on screen before: the two-thirds cell is the two-thirds cell
    /// whatever stands there. The pair cell is the halves layout with both windows in it. A drop on a
    /// side edge or a corner holds the dragged window and the tiled windows standing beside it
    /// (`EdgeDrop.plan`), takes what they leave free, and asks them for room when its own minimum needs
    /// it. A drop on the top edge holds the dragged window alone (`EdgeDrop.maximised`): it is a
    /// maximize whatever stands on the display, so the window list is not even read for it.
    private func arrange(_ resolution: ZoneResolution, display: DisplayInfo, gap: Double,
                         fills: Bool) -> ResolvedZone {
        let zone = resolution.zone
        let area = display.visibleFrame
        let draggedID = currentWindowID ?? 0
        let draggedLimits = SizeLimits(minimum: MinimumSizePolicy.presumed(draggedMinimum))
        let dragged = ArrangementBox.ID.window(draggedID)

        var arrangement: Arrangement
        var freeFrame: CGRect?
        var partnerID: ArrangementBox.ID?
        switch resolution.origin {
        case .snapBar, .pairCell:
            var members = [zone.cellIndex: LayoutArrangement.Member(windowID: draggedID, limits: draggedLimits)]
            if resolution.origin == .pairCell, let partnerZone = resolution.partnerZone, let partner = snapBar.partner {
                members[partnerZone.cellIndex] = LayoutArrangement.Member(
                    windowID: partner.id, limits: SizeLimits(minimum: MinimumSizePolicy.presumed(partnerMinimum)))
                partnerID = .window(partner.id)
            }
            arrangement = LayoutArrangement(layout: zone.layout, area: area, gap: gap, members: members).arrangement
        case .screenEdge:
            let plan = zone.isFill
                ? EdgeDrop.maximised(zone: zone.frame, area: area, gap: gap, draggedID: draggedID,
                                     draggedLimits: draggedLimits)
                : EdgeDrop.plan(zone: zone.frame, area: area, gap: gap, draggedID: draggedID,
                                draggedLimits: draggedLimits, neighbours: neighbours(on: display, gap: gap),
                                fills: fills)
            arrangement = plan.arrangement
            freeFrame = plan.freeFrame
        }

        let solution = arrangement.solve()
        var partnerZone = resolution.partnerZone
        if let partnerID, let frame = solution.frames[partnerID] { partnerZone?.frame = frame }
        let moved: [MovedNeighbour] = arrangement.boxes.compactMap { box in
            guard box.id != dragged, box.id != partnerID, case .window(let id) = box.id,
                  let frame = solution.frames[box.id],
                  !frame.isApproximatelyEqual(to: box.preferred, tolerance: 1),
                  let occupant = occupants.first(where: { $0.windowID == id }) else { return nil }
            return MovedNeighbour(windowID: id, pid: occupant.pid, from: box.preferred, frame: frame)
        }
        return ResolvedZone(zone: zone, origin: resolution.origin, nominalPartnerZone: resolution.partnerZone,
                            partnerZone: partnerZone, arrangement: arrangement, solution: solution,
                            dragged: dragged, freeFrame: freeFrame, neighbours: moved)
    }

    /// The windows standing beside a drop on `display`, decided once per gesture and per display. The
    /// windows left out are logged with the reason, once: a drop that ignores a window the user can
    /// see has to be explainable from the log.
    private func neighbours(on display: DisplayInfo, gap: Double) -> [SnapOccupant] {
        if let known = neighboursByDisplay[display.id] { return known }
        let result = NeighbourEvidence.neighbours(among: occupants, area: display.visibleFrame, gap: gap)
        // A window of another display is outside this one's working area by definition and is not
        // worth a line; one that reaches out of *this* working area is.
        for (window, reason) in result.rejected
        where reason != .outsideTheArea || display.visibleFrame.intersects(window.frame) {
            Logger.drag.debug("window \(window.windowID) does not stand beside this drop: \(reason.description, privacy: .public)")
        }
        neighboursByDisplay[display.id] = result.accepted
        return result.accepted
    }

    /// Every other window on screen, and the minimums of the two windows this gesture can place. Read
    /// **once**, at drag confirmation.
    ///
    /// **The registry is not asked.** A drop takes the space that is actually free, whoever put the
    /// windows there: requiring a record of our own would make a hand-placed window count for nothing,
    /// and a window snapping into its nominal half beside a hand-placed one leaves a hole the size of
    /// whatever that neighbour was given. What decides whether a window stands beside a drop is
    /// `NeighbourEvidence`, from its **current** frame and the stacking order: it looks tiled and it
    /// can be seen.
    ///
    /// The evidence is `WindowList.snapshot` — visible, layer 0, regular applications, never a window
    /// name. Every display's windows are kept: the drag may end on another display, and the windows
    /// in front of a neighbour are what says whether it can be seen. No Accessibility here and none on
    /// the drag path: this is cached window-list geometry, read at confirmation and not looked at
    /// again until the next drag.
    ///
    /// The dragged window is left out by its id, and where it has none — the public route could not
    /// match it — by being the window of its application with the very size the drag is holding: a
    /// drag moves a window and never resizes it.
    private func captureFillEvidence(_ handle: WindowHandle, frame: CGRect) {
        let dragged = handle.windowID
        let snapshot = WindowList.snapshot()
        // A drag start is a free look at two windows' sizes (§6): the dragged one, whose frame the read
        // that confirmed the drag just gave, and the pair partner, whose frame the window list has.
        // Either may lower its application's row, so both are looked at before the minimums are read.
        MinimumProbe.logLowering(minimums.observe(handle, size: frame.size), window: dragged ?? 0,
                                 size: frame.size, log: Logger.drag)
        if let partner = snapBar.partner, let seen = snapshot.first(where: { $0.id == partner.id }) {
            MinimumProbe.logLowering(minimums.observe(partner.handle, size: seen.frame.size),
                                     window: partner.id, size: seen.frame.size, log: Logger.drag)
        }
        draggedMinimum = minimums.minimum(for: handle)
        partnerMinimum = snapBar.partner.flatMap { minimums.minimum(for: $0.handle) }
        occupants = snapshot
            .filter { info in
                if let dragged { return info.id != dragged }
                return !(info.pid == handle.pid && abs(info.frame.width - frame.width) <= 1
                            && abs(info.frame.height - frame.height) <= 1)
            }
            .map { info in
                SnapOccupant(windowID: info.id, pid: info.pid, frame: info.frame,
                             minimum: minimums.minimum(forWindowID: info.id, pid: info.pid),
                             zIndex: info.zIndex)
            }
    }

    /// `companion` is the pair's other half, previewed beside `zone` so a pair drop shows its whole
    /// outcome.
    ///
    /// Both are compared before anything is presented, and that is the guard against the pair cell
    /// replaying its appear animation as the cursor crosses the gap between its halves: every point of
    /// the cell resolves to the same zone *and* the same companion, so this returns early. It also covers
    /// the one case the zone alone cannot — moving from the pair cell to the bar's plain halves cell,
    /// where the zone is literally the same value and only the companion has to go.
    private func setZone(_ resolved: ResolvedZone?) {
        let zone = resolved?.zone
        let companion = resolved?.partnerZone
        guard zone != currentZone || companion != currentCompanion else { return }
        let appearing = currentZone == nil && zone != nil
        currentZone = zone
        currentCompanion = companion
        // **The preview draws the arrangement, not the cell.** `resolved.frame` is the frame the
        // engine is going to be handed at the drop, computed by the one function that decides it, from
        // the state this gesture cached at its start.
        //
        // The one thing it cannot be honest about is a minimum nobody has measured: the arrangement
        // is then solved with the presumed floor and the landing may still be larger, because the
        // only way to learn a macOS window's minimum is to write a size and read back what was
        // accepted — measured across 5 applications and 4 toolkits, not one publishes `AXMinSize` —
        // and doing that mid-drag is a visible blink on the window the user is holding. The correction
        // pass puts the arrangement right after the landing.
        var shown = zone
        if let resolved { shown?.frame = resolved.frame }
        // The morph departs from the dragged window, slid onto the zone's own display: a preview
        // panel is planted on one display's Space and clipped there, so a departure rectangle lying
        // across a seam would play half its journey on a screen this panel cannot draw on. The slide
        // is a translation and never a resize, and an axis already inside the display does not move
        // at all — a window held across two displays leaves from its own size and its own height.
        let from = appearing ? lastKnownFrame.map { frame in
            guard let display = zone.flatMap({ z in screens.displays.first { $0.id == z.displayID } })
            else { return frame }
            return Geometry.slid(frame, inside: display.frame)
        } : nil
        preview.show(shown, companion: companion, from: from)
        let neighbours = resolved?.neighbours ?? []
        if neighbours.isEmpty {
            neighbourPreviews.dismiss()
        } else {
            neighbourPreviews.track(neighbours.map(\.frame), appearingFrom: neighbours.map(\.from))
        }
    }

    /// A drop is never discarded because Accessibility was slow: the cached frame is what the
    /// animation starts from, and a read is only attempted when there is nothing cached at all.
    ///
    /// Every window the arrangement places — the dragged one, a pair partner, the neighbours that give
    /// room — is handed to the coordinator in one go, so they animate together and the correction pass
    /// sees all of their landings. `onSnapped` fires once the arrangement has settled, with what the
    /// dragged window's own landing revealed about its limits: that is what a Snap Assist phase is
    /// started from.
    private func finish(_ handle: WindowHandle, resolved: ResolvedZone) {
        let zone = resolved.zone
        guard let frame = lastKnownFrame ?? ax.frame(of: handle) else {
            // Names the count for the same reason its neighbour below does: on a pair drop this
            // discards *both* placements, and a whole gesture doing nothing is the hardest thing
            // here to diagnose from a log.
            let placements = resolved.partnerZone == nil ? 1 : 2
            Logger.drag.error("no known frame for window \(handle.windowID ?? 0); dropping \(placements) placement(s)")
            return
        }
        guard let display = screens.displays.first(where: { $0.id == zone.displayID }) else {
            // Reachable when the display configuration changes between the resolution and the drop. It
            // discards *two* placements on a pair drop, so it says so rather than returning in
            // silence: a whole gesture doing nothing is the hardest thing here to diagnose from a log.
            let placements = resolved.partnerZone == nil ? 1 : 2
            Logger.drag.error("display \(zone.displayID) is gone; dropping \(placements) placement(s)")
            return
        }
        report(resolved, display: display, windowID: handle.windowID)

        // Every window of the arrangement is a member, moved by the first solution or not: what the
        // dragged window's landing reveals may make a correction move one that the first solution left
        // alone. A neighbour's handle is only asked for when it has to be written.
        var members = [ArrangementCoordinator.Member(id: resolved.dragged, handle: handle, current: frame, zone: zone)]
        // A drop in the pair cell fills the facing half with the partner, in the same gesture.
        var partnerID: ArrangementBox.ID?
        if let partnerZone = resolved.partnerZone, let partner = partnerMember(into: partnerZone) {
            members.append(partner)
            partnerID = partner.id
        }
        for box in resolved.arrangement.boxes where box.id != resolved.dragged && box.id != partnerID {
            guard case .window(let id) = box.id, let occupant = occupants.first(where: { $0.windowID == id }) else { continue }
            members.append(member(for: occupant, display: display))
        }

        let dragged = resolved.dragged
        let origin = resolved.origin
        let interruptions = self.interruptions
        // Nothing but leaving the arrangement supersedes a drop as a whole. A window the user picks up
        // again mid-correction loses its own write, and the coordinator leaves a window it has lost
        // alone.
        coordinator.run(
            resolved.arrangement, members: members, display: display,
            isCurrent: { [weak self] in self?.interruptions == interruptions && self?.isSuspended() == false },
            onSolved: { _ in },
            // Snap Assist starts from the first landing, with what that landing revealed of the dragged
            // window's limits: the choosing phase has no part in a correction and does not wait for one.
            afterFirstLandings: { [weak self] outcome in
                guard let self else { return }
                guard let landed = outcome.landed[dragged] else {
                    Logger.drag.debug("window \(handle.windowID ?? 0) did not land (cancelled or refused)")
                    return
                }
                Logger.drag.info("snapped window \(handle.windowID ?? 0) into \(zone.layout.id, privacy: .public)[\(zone.cellIndex)]")
                var placed = zone
                placed.frame = landed
                let limits = outcome.arrangement.boxes.first { $0.id == dragged }?.limits
                    ?? SizeLimits(minimum: MinimumSizePolicy.presumedFloor)
                self.onSnapped?(handle, placed, display, origin, limits)
            },
            completion: { outcome in
                guard let partnerID else { return }
                if outcome.landed[partnerID] == nil {
                    Logger.drag.error("pair partner did not land; the dragged window keeps its half")
                } else {
                    Logger.drag.info("paired the partner into \(zone.layout.id, privacy: .public)")
                }
            })
    }

    /// One window standing beside the drop, as the coordinator may write it. Its `Zone` is the one it
    /// was snapped into, so `EngineRouter` re-records it and the *next* drop finds it where it ended up.
    ///
    /// **A neighbour need not be a window we snapped**, and one we did not snap has no recorded zone to
    /// carry. It gets a one-cell zone of its own frame: what the engine reads off a `Zone` is its
    /// frame, and what the registry then holds for that window is the frame it had *before* this drop
    /// moved it — which is exactly the pre-snap frame a drag-away restore wants.
    ///
    /// Its handle costs two Accessibility calls, bounded by the 0.25 s messaging timeout, and they are
    /// made only if the window has to be written. Every way this can fail leaves the dragged window's
    /// own snap alone; the worst case is an overlap, and the coordinator logs it.
    private func member(for neighbour: SnapOccupant, display: DisplayInfo) -> ArrangementCoordinator.Member {
        let zone = state.registry.recordedEntry(for: neighbour.windowID)?.zone
            ?? Zone(displayID: display.id, layout: LayoutCatalog.fill, cellIndex: 0, frame: neighbour.frame)
        let ax = self.ax
        return ArrangementCoordinator.Member(id: .window(neighbour.windowID), current: neighbour.frame, zone: zone) {
            guard let handle = ax.handle(forWindowID: neighbour.windowID, pid: neighbour.pid),
                  !ax.isMinimized(handle) else { return nil }
            return handle
        }
    }

    /// One line per drop that did something other than take its nominal cell, with the numbers. A drop
    /// that took its cell says nothing — that is every ordinary snap, and a line for it would bury these.
    private func report(_ resolved: ResolvedZone, display: DisplayInfo, windowID: CGWindowID?) {
        let id = windowID ?? 0
        let nominal = resolved.zone.frame
        if let free = resolved.freeFrame, !free.isApproximatelyEqual(to: nominal, tolerance: 1) {
            Logger.drag.info("took what is free: window \(id) is offered \(free.width, format: .fixed(precision: 0))×\(free.height, format: .fixed(precision: 0)) at \(free.minX, format: .fixed(precision: 0)),\(free.minY, format: .fixed(precision: 0)) for a \(nominal.width, format: .fixed(precision: 0))×\(nominal.height, format: .fixed(precision: 0)) cell")
        }
        for neighbour in resolved.neighbours {
            Logger.drag.info("window \(id) needs more than is free: neighbour \(neighbour.windowID) gives \(neighbour.from.width - neighbour.frame.width, format: .fixed(precision: 0))×\(neighbour.from.height - neighbour.frame.height, format: .fixed(precision: 0)) pt and moves \(neighbour.frame.minX - neighbour.from.minX, format: .fixed(precision: 0)),\(neighbour.frame.minY - neighbour.from.minY, format: .fixed(precision: 0))")
        }
        for box in resolved.arrangement.boxes {
            let over = resolved.solution.overflow(of: box.id, in: display.visibleFrame, gap: resolved.arrangement.gap)
            guard over.width > 1 || over.height > 1 else { continue }
            Logger.drag.info("minimums do not fit: \(String(describing: box.id), privacy: .public) runs \(over.width, format: .fixed(precision: 0))×\(over.height, format: .fixed(precision: 0)) pt past the right/bottom edge")
        }
    }

    /// The second half of a pair drop, as the coordinator writes it.
    ///
    /// It can fail four ways — the partner is gone from the session, it was minimized during the
    /// drag, Accessibility will not say where it is, or the engine refuses the placement — and
    /// **none of them undoes the first half**. The dragged window stays where the user's own
    /// gesture put it. Rolling it back would discard the drop they made and leave that window
    /// wherever the mouse was released, mid-screen, which is plainly worse than a half-built pair
    /// they can finish with one more drag; and by the time the second placement can be known to
    /// have failed the first is already animating, so "atomic" is not on offer. Every failure is
    /// logged, and nothing else happens: `SnapRegistry` simply gets no entry for a window that
    /// never moved, so no drag-away restore is offered for it either.
    ///
    /// The partner is deliberately **not** raised. It is by definition the frontmost eligible window, so
    /// nothing offerable is covering it, and raising it would activate its app and take focus off the
    /// window the user has just dragged.
    private func partnerMember(into zone: Zone) -> ArrangementCoordinator.Member? {
        guard let partner = snapBar.partner else {
            Logger.drag.error("pair drop with no partner in the session; snapped the dragged window alone")
            return nil
        }
        // The partner passed the eligibility rule when the drag was confirmed, and a drag lasts as
        // long as the user wants it to. `isMinimized` is re-asked here because it is the one part
        // of that rule that realistically changes mid-drag, and because a minimized window does
        // *not* fail the frame read below — Accessibility answers for it happily, so the app would
        // place a window nobody can see and the user would find it in the right half the next time
        // they un-minimized it. One bounded round trip, asked before the frame read so the
        // minimized case costs less rather than more.
        //
        // The rest of the rule is not re-asked: `isResizable` does not change under a window, and
        // if it somehow did, `setFrame` simply fails to resize — which degrades safely. Adding
        // calls here buys nothing and this runs inside the tap's callback.
        guard !ax.isMinimized(partner.handle) else {
            Logger.drag.info("pair partner \(partner.id) was minimized during the drag; snapped the dragged window alone")
            return nil
        }
        // One Accessibility read, and it is at mouse-up rather than on the drag path, bounded by
        // the same 0.25 s messaging timeout as every other. A window closed mid-drag answers
        // nothing here, which is exactly the "partner has vanished" case this has to survive.
        guard let from = ax.frame(of: partner.handle) else {
            Logger.drag.error("no frame for pair partner \(partner.id); snapped the dragged window alone")
            return nil
        }
        return ArrangementCoordinator.Member(id: .window(partner.id), handle: partner.handle, current: from, zone: zone)
    }
}
