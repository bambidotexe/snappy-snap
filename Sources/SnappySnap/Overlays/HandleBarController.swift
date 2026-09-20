import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// While the cursor is live the window list is polled every 100 ms, `AdjacencyDetector` turns each
/// snapshot into the pairs of windows whose facing edges nearly touch, and a pill is shown over the
/// gap the cursor is in. Pressing that pill drags the divider: the far edges stay put and the gap
/// between them becomes the gap setting.
///
/// **Nothing is resized while the divider moves.** The drag draws its own outcome — one zone preview
/// per window, at the frame that window will take, glued to the pointer through `WindowPreviewGroup`
/// — and on the mouse-up both windows animate to those frames through `SteppingSnapEngine`, the same
/// engine and the same `animationDuration` as every snap. Two frames a gesture reach Accessibility,
/// and they reach it after the button is up, so a slow application costs an animation that lags
/// rather than a divider that fights the pointer.
///
/// **Minimum sizes, and why they are probed.** A drag that writes nothing has nothing to read a
/// refusal back from, so the preview would happily draw a window narrower than its application allows
/// and the release would land it wider than the preview showed. The minimum therefore arrives from
/// somewhere else: `MinimumSizeStore` holds each application's row and each window's own floor, and
/// when it holds nothing measured against the version that application is running, the **press** asks
/// it directly through `MinimumProbe` — set 1 × 1, read back what the window actually took, set the
/// original size again. Three round trips, once per application, and one visible blink of
/// that window: the price of a divider that stops where the window stops.
///
/// With a minimum in hand the divider is clamped inside `HandleDragMath.frames`, and because the frames
/// are a pure function of the pointer the pill and both previews simply **stop** while the pointer
/// carries on, then pick it up again with no jump when it comes back. A window whose minimum could not
/// be probed at all — no bundle identifier, or a read-back that failed — is given `MinimumProbe.fallback` for
/// that gesture.
///
/// **What the release still corrects.** A stored minimum is a floor, not a grid, so a window can land
/// larger than it was asked for anyway. When it does, on the divider's own axis and by more than a
/// point, the release learns the size it actually took and re-fits the **neighbour** against that
/// landed frame — one further `SteppingSnapEngine.snap`, after both animations have finished, so the
/// pair cannot end overlapping. The re-fit is not itself corrected.
///
/// **How the press reaches this class.** The pill lives on an `OverlayPanel` — a
/// `.nonactivatingPanel` belonging to an app that never activates — so AppKit delivers a click to it
/// only through a view that answers `acceptsFirstMouse`, and a SwiftUI gesture on such a panel never
/// fires at all. Every overlay in this app is therefore hit-tested in its controller against the
/// global mouse stream: `AppDelegate.route` hands this class every `.moved`, `.down`, `.dragged` and
/// `.up` the listen-only event tap produces, and the band is hit-tested here, in CG space, against
/// the very geometry that positioned the panel. Nothing depends on AppKit routing an event into a
/// panel. The panel takes mouse events all the same, but for the cursor and not for the click — see
/// `HandlePanel`.
///
/// **What a drag costs the run loop.** Nothing that can be measured. The gesture's whole
/// Accessibility cost is paid at the press — two window lookups, two resizable checks, two frame reads
/// — and between the press and the mouse-up the main thread only ever runs `HandleDragMath`, which is
/// pure, and moves three panels. Two consequences, and they are what this class is:
///
/// - **The overlay is authoritative.** The pill and the two previews follow the pointer on *every*
///   `.dragged` event, at whatever rate the tap delivers them, because moving a panel is free. Nothing
///   about a window can feed back into where they are drawn, because no window is asked anything.
/// - **A drag cannot outlive the button.** A lost mouse-up leaves the gesture latched: the handles
///   stay suspended and the next click writes both windows to wherever it landed. The 10 Hz poll asks
///   the window server whether the left button is still down and cancels the gesture — writing
///   nothing — once `OrphanDetector` says the mouse-up is *lost* rather than merely made: the button
///   up on two consecutive polls, and no mouse event in the last one. A bare button test orphans
///   ordinary releases, because the button bit flips before the tap delivers. It matters rather more
///   here: an orphaned gesture is one whose windows never move at all.
@MainActor
final class HandleBarController {
    /// How often the window list is polled while the cursor is live…
    static let pollInterval: TimeInterval = 0.1
    /// …and how long after the last cursor movement polling stops.
    static let cursorIdleTimeout: CFTimeInterval = 2
    /// Grace between the cursor leaving the band and the pill fading, so a jitter does not flicker it.
    static let hideGrace: TimeInterval = 0.1

    /// How much larger than the frame it was asked for a window may land before its neighbour is
    /// re-fitted against it. A point: a window that came back even a grid cell larger is a window
    /// whose neighbour now overlaps it, whatever the reason. **It decides the re-fit and never a
    /// floor** — whether the landing reveals a minimum is `MinimumSizePolicy.revealedFloor`'s
    /// question, which allows for an application that rounds its own frame.
    static let refusalTolerance: Double = 1

    /// One of the two windows the divider moves.
    private struct Side {
        let handle: WindowHandle
        /// Where the divider's current position puts this window: what its preview is drawn at, and on
        /// the release what it is animated to. Seeded with the frame the press read, so a press that
        /// never moves has a target that asks for nothing.
        var target: CGRect
        /// Whether this window's release animation is still running. The gesture is not over — and the
        /// knobs and the poll do not come back — until both have answered.
        var animating = false
        /// Where this window actually ended up, once its release animation has reported. It is where a
        /// re-fit of this side has to animate *from*: the target is what was asked for, and the whole
        /// reason a re-fit exists is that the two differ.
        var landed: CGRect?
    }

    /// The correction a release owes once one of the two windows has landed somewhere other than the
    /// frame it was asked for. Held until **both** animations have finished rather than run on the
    /// spot: starting a snap on a window the engine is still animating would cancel that animation, and
    /// a cancelled animation reports nil through the very completion that is deciding this.
    private struct Refit {
        /// Which side has to move — the *neighbour* of the window that refused.
        let neighbourIsB: Bool
        /// The frame the refusing window actually took, which the neighbour is fitted against.
        let against: CGRect
        /// How far past its asked size the refusing window landed, on the divider's axis. Only used to
        /// pick between two refusals: a pair where both windows refuse cannot be made to fit, and the
        /// larger overshoot is the one worth clearing.
        let overshoot: Double
    }

    /// A drag in progress, and then — between the mouse-up and the two animations finishing — one that
    /// is settling. `pair`'s two frames are the ones the **press** read and are never written to: the
    /// far edges are the pivot of the whole gesture, and every pass computes both targets from them,
    /// so nothing can drift a point per frame. Only `pair.gap` is touched, and only to the normalized
    /// gap, because that is what the pill's own geometry is drawn from.
    private struct Drag {
        var pair: HandlePair
        var a: Side
        var b: Side
        /// The gap the drag normalizes to — the gap setting, read once when the press landed.
        let gap: Double
        /// Each window's floor, resolved once at the press — stored, probed, or `MinimumProbe.fallback` —
        /// and constant for the gesture. It is what clamps the divider, and it is also what a re-fit
        /// clamps the neighbour's size to.
        let minSizes: HandleDragMath.MinSizes
        /// Whether a drag event has arrived at all. The gap is normalized on the first movement, so a
        /// press and release that never moved must leave both windows exactly as they were.
        var moved = false
        let began: CFTimeInterval
        /// When this drag last saw a mouse event — the press, then every `.dragged`. It is half of the
        /// cancel rule (`OrphanDetector`): a stream that was alive a moment ago means the `.up` is on
        /// its way behind it.
        var lastEventAt: CFTimeInterval
        /// Consecutive watchdog polls that have read the left button up, reset by any poll that reads
        /// it down. The other half of the rule.
        var ticksButtonUp = 0
        /// Set at mouse-up. From here on the gesture is over on screen — the pill narrows back, the
        /// previews fade — and the only thing left is the two animations; the button watchdog stands
        /// down, and `endDrag` runs when both windows have reported.
        var released = false
        /// Set by whichever animation reported a refusal; run once both have, then cleared.
        var refit: Refit?

        var isLive: Bool { !released }
    }

    private let ax: AccessibilityWindows
    /// The release animation, both windows through it. The one engine every snap uses, called
    /// directly rather than through `EngineRouter`: a divider drag lands a window on a frame and not
    /// in a `Zone`, so there is nothing for `SnapRegistry` to record and no unsnap for it to offer.
    private let engine: SteppingSnapEngine
    /// One zone preview per window, at the frame that window will take. This is what the drag moves
    /// instead of the windows.
    private let previews = WindowPreviewGroup()
    /// The rest of the screen, taken back 30 % for the length of the gesture.
    private let dim = DimGroup()
    /// What each application will not shrink below. Owned by `AppDelegate` and shared, because it is a
    /// fact about other applications and not about this feature.
    private let minimums: MinimumSizeStore
    private let screens: any ScreensProviding
    private let settingsStore: SettingsStore
    /// True while another feature owns the screen. Snap Assist is the one that does: its surfaces
    /// cover the very gaps a handle would be offered in, and the windows it parked are off-screen, so
    /// a handle over what is left would be a handle between two windows the user is not looking at.
    private let isSuspended: @MainActor () -> Bool

    /// The pairs and the window snapshot of each poll, handed on so the junction knobs are found from
    /// the same snapshot rather than from a second window list; the full snapshot travels with them
    /// because judging whether something covers a crossing needs it. Called with two empty arrays
    /// whenever this feature stands down, so nothing downstream keeps an arrangement that is no longer
    /// offered.
    var onPairs: (@MainActor ([HandlePair], [WindowInfo], [WindowInfo]) -> Void)?
    /// A junction handle replaces the pair pills that meet at it for as long as it is shown, because
    /// two targets at one point would make which windows move depend on a pixel. Only the band around
    /// the crossing is claimed — the rest of each divider is still the pill's.
    var claimsPoint: (@MainActor (CGPoint) -> Bool)?

    /// True while this feature owns a gesture — including the settling period after the mouse-up, when
    /// the button is already up but the two windows are still animating to the frames the previews
    /// showed. The junction knobs stand down for all of it: a knob gesture beginning there would read
    /// the frame of a window that is mid-animation and pivot three or four windows on it.
    var isDragging: Bool { drag != nil }

    /// True while there is anything on screen to take away, which `isDragging` does not answer. The
    /// handles have to go when a Space changes or Mission Control opens, and the pill that is left
    /// there is the *hovered* one, which no gesture is holding and which would otherwise float over
    /// Mission Control on its own.
    var isShowing: Bool { hovered != nil || drag != nil }

    private let panel = HandlePanel()
    private var timer: Timer?
    /// Stamped at construction, not left at zero: `CACurrentMediaTime()` is time since boot, and an
    /// idle boundary measured against zero reports the age of the machine rather than the length of
    /// the pause. Before the first mouse-moved event the poll is live, then stands down 2 s later —
    /// which is exactly what it does for any other pause.
    private var lastMouseMove: CFTimeInterval = CACurrentMediaTime()
    private var pairs: [HandlePair] = []
    /// The full snapshot the current `pairs` came from: occlusion is judged at the pill against the
    /// whole window list, not only the two members of a pair.
    private var lastWindows: [WindowInfo] = []
    /// The windows of the same poll that take no part and can still sit over a pill (`CoveringSurface`).
    private var lastCoverers: [WindowInfo] = []
    private var hovered: HandlePair?
    /// The pair/occluder combination last logged, so "once per change" holds across the 10 Hz poll
    /// rather than repeating on every tick a pair stays covered.
    private var lastOcclusion: (pair: HandlePair, occluderID: UInt32)?
    private var drag: Drag?
    private var hideWork: DispatchWorkItem?
    /// Logged on change: why this feature is standing down and since when. `since` is the start of the
    /// *whole* suspension, so a clause that changes while it lasts does not restart the clock.
    private var suspension: (clause: String, since: CFTimeInterval)?
    /// Logged on change: whether the poll has stood down for want of a mouse-moved event, and the
    /// stamp of the last one before it did — which is what makes the resumed line report the true gap
    /// rather than the time spent in the idle state.
    private var pollIsIdle = false
    private var lastMoveBeforeIdle: CFTimeInterval = 0

    init(ax: AccessibilityWindows, engine: SteppingSnapEngine,
         screens: any ScreensProviding,
         settingsStore: SettingsStore, minimums: MinimumSizeStore,
         isSuspended: @escaping @MainActor () -> Bool) {
        self.ax = ax
        self.engine = engine
        self.minimums = minimums
        self.screens = screens
        self.settingsStore = settingsStore
        self.isSuspended = isSuspended
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancel()
    }

    /// Drops a live drag and takes the pill down. Displays changing ends the session and every overlay
    /// with it — the frames a drag pivots on were measured on a display that may not exist any more,
    /// and the pairs came from a window list arranged around it.
    ///
    /// A cancelled gesture writes nothing at all: while the divider is moving there is nothing to
    /// undo, because no window has been touched since the press. A gesture cancelled *after* the
    /// mouse-up is the one case with something in flight, and its two animations are stopped where
    /// they are — the frames they were heading for were measured on a display the cancel is telling us
    /// may no longer exist.
    ///
    /// `drag` is cleared **before** the engine is told, because `SteppingSnapEngine.cancel` answers
    /// every completion it tears down: with the gesture already gone they find nothing to report
    /// against, which is what keeps the teardown out of `endDrag`.
    /// `forInterruption` sends the pill, the previews and the dim off through the shared 120 ms fade
    /// rather than each surface's own dismiss, and is the only difference between the two calls: what
    /// is cancelled, and what is written (nothing), are the same either way.
    func cancel(forInterruption: Bool = false) {
        if let live = drag {
            Logger.handle.debug("handle drag cancelled; nothing further written")
            drag = nil
            if live.released {
                engine.cancel(windowID: live.a.handle.windowID)
                engine.cancel(windowID: live.b.handle.windowID)
            }
            if forInterruption {
                previews.dismissForInterruption()
                dim.fadeOutForInterruption()
            } else {
                previews.dismiss()
                dim.fadeOut()
            }
            panel.setDragging(false)
        }
        // Idempotent from here down, because `tick` calls this on *every* suspended poll: a feature
        // that is switched off would otherwise tell the junction knobs it has no pairs ten times a
        // second for as long as it stays off. `hidePanel` already answers nothing when there is
        // nothing up.
        if !pairs.isEmpty || !lastWindows.isEmpty || lastOcclusion != nil {
            pairs = []
            lastWindows = []
            lastCoverers = []
            lastOcclusion = nil
            onPairs?(pairs, lastWindows, lastCoverers)
        }
        hidePanel(forInterruption: forInterruption)
    }

    /// Recomputes the pairs at once rather than waiting for the next tick. The junction handles use
    /// it when a gesture of theirs has finished moving the very windows these pairs describe.
    ///
    /// It does **not** touch `lastMouseMove`. Stamping it to get past `tick`'s cursor-idle guard would
    /// be a lie about the cursor: a gesture ending — or being cancelled — would restart the 100 ms
    /// poll for a further two seconds with the pointer motionless, which is exactly the idle pause the
    /// guard exists for. The guard is bypassed explicitly instead.
    func refresh() {
        tick(ignoringCursorIdle: true)
    }

    /// Stops the background cursor at once, leaving everything else alone. The assertion must stop on
    /// Mission Control and on a Space change, and neither of those is detected here — they belong to
    /// the interruption fan-out, which calls this. Idempotent, and safe to call when no cursor is
    /// being asserted.
    ///
    /// Stopping is not setting a cursor: the application under the pointer gets its own back. If the
    /// pointer is still in the band afterwards, the next `show` starts a fresh keepalive.
    func stopCursorAssertion() {
        panel.stopAsserting()
    }

    /// Takes the pill down at once, with no fade: for Command, where the mouse-down right behind it has to
    /// land on the window underneath rather than on a pill still fading out. `AppDelegate` calls this
    /// only while `isDragging` is false — a live drag's pill is the divider itself, not a hover to take
    /// away, and Command must never touch a gesture already in flight.
    func hideForCommand() {
        hideWork?.cancel()
        hideWork = nil
        hovered = nil
        panel.hideAtOnce()
    }

    /// Returns true when the event belongs to a handle drag and must not travel on to the window-drag
    /// session: a press on the pill would otherwise arm a drag on whatever `AccessibilityWindows`
    /// finds under the gap, and the two state machines would both be live on one gesture.
    @discardableResult
    func handle(_ event: MouseEvents.Event) -> Bool {
        switch event {
        case .moved(let point):
            noteMouseMoved()
            if drag == nil { updateHover(at: point) }
            return false
        case .down(let point):
            guard active, claimsPoint?(point) != true, let pair = hovered,
                  HandleBarGeometry.band(for: pair).contains(point) else { return false }
            // A press inside the band this feature offered is **ours whether or not a gesture
            // starts**, which is the rule `JunctionHandleController` states at its own `.down`.
            // `beginDrag` declines four ways — no Accessibility window either side, a window that
            // will not resize, a pair that moved past `handleMaxGap` since the 100 ms snapshot — and
            // a declined press travelling on would reach `DragSessionController`, which would arm a
            // *window drag* on whatever sits under the pill. The panel covering exactly the band does
            // make `mouseDown` reject the press as our own pid, but that depends on
            // `AXUIElementCopyElementAtPosition` returning a borderless `.nonactivatingPanel` of a
            // never-activating app, which nothing here tests. This is the direct guarantee; that one
            // stays as the belt to these braces.
            guard drag == nil else {
                // The button is up and the previous gesture's two windows are still animating to the
                // frames it left them. Beginning here would read a frame that is mid-flight and pivot
                // this gesture's far edges on it.
                Logger.handle.debug("pill press ignored: the last drag's windows are still settling")
                return true
            }
            if !beginDrag(pair) {
                Logger.handle.debug("pill press declined; swallowed so it cannot arm a window drag")
            }
            return true
        case .dragged(let point):
            guard let live = drag else { return false }
            // Settling: the press this follows was swallowed above, so this is ours too. One rule for
            // all three events of a gesture, rather than two that happen to agree today.
            guard live.isLive else { return true }
            drag?.moved = true
            // Stamped for every drag event: the cancel rule asks whether the *stream* is alive, and
            // every event of a gesture is evidence of that.
            drag?.lastEventAt = CACurrentMediaTime()
            updateDrag(to: point)
            return true
        case .up(let point):
            // A `.up` that finds no drag at all writes nothing — that is the one that follows a drag
            // the watchdog has already orphaned, and it belongs to nobody.
            guard let live = drag else { return false }
            // One that finds a settling drag is the release of the press swallowed above. Ours, and
            // still nothing to write.
            guard live.isLive else { return true }
            // The release point is resolved once more *if the handle was ever moved*: the frame the
            // user let go on is the one that has to land, as at the window drag's own mouse-up, and
            // `.up` can carry a point no `.dragged` reported. A press and release with no movement
            // resolves nothing at all, because the gap is normalized on the first movement and a bare
            // click is not one.
            if live.moved { updateDrag(to: point) }
            release()
            return true
        // Never reaches this controller — `AppDelegate.route` answers Command on its own branch, before the
        // mouse fan-out this method is part of — but the switch is exhaustive.
        case .flagsChanged: return false
        }
    }

    /// Why this feature is standing down, or nil while it is live. One string per clause, so that
    /// standing down can log a reason at all: `isSuspended` is a Bool the app builds from several
    /// conditions of its own, and the most this class can honestly say about it is which of *its*
    /// three tests failed. The reasons it names have to stay in step with what `AppDelegate` actually
    /// builds that Bool from, or a reader is sent looking in the wrong place.
    private func suspensionClause() -> String? {
        let settings = settingsStore.settings
        if !settings.handleBar { return "the handle bar is switched off" }
        if isSuspended() {
            return "another feature owns the screen, or Command is held (Snap Assist, a junction drag, the Settings window, Mission Control, the Command key)"
        }
        return nil
    }

    private var active: Bool { suspensionClause() == nil }

    private func tick(ignoringCursorIdle: Bool = false) {
        let clause = suspensionClause()
        noteSuspension(clause)
        guard clause == nil else { cancel(); return }
        // The button watchdog. A mouse-up lost to a Space change, a Mission Control gesture or a tap
        // the window server disabled leaves the gesture latched — the handles stay suspended and the
        // next click writes both windows to wherever it landed. The window server's own button state
        // is the authority on the button, and it costs one call per tick.
        //
        // **The button being up is not by itself evidence of a lost mouse-up.** The bit flips at the
        // physical release, milliseconds before the session tap delivers `.up`, and a due `Timer` runs
        // before a mach-port source in the same run-loop pass — so a bare test here orphans ordinary
        // releases. `OrphanDetector` is the rule that tells the two apart.
        if var live = drag, live.isLive {
            let up = !Self.leftButtonIsDown()
            live.ticksButtonUp = up ? live.ticksButtonUp + 1 : 0
            drag = live
            if OrphanDetector.shouldCancel(buttonUp: up, ticksUp: live.ticksButtonUp,
                                           lastEventAt: live.lastEventAt, now: CACurrentMediaTime(),
                                           quietFor: Self.pollInterval) {
                orphan(live)
            }
            return
        }
        // A drag — live or settling — owns the arrangement. Polling now would build the pairs from an
        // arrangement the app itself knows is in motion: the pill would fade for a poll and come back,
        // and worse, a press in it would start a gesture from frames that are about to change under
        // it, on windows a release animation is still moving.
        guard drag == nil else { return }
        let now = CACurrentMediaTime()
        noteIdle(at: now)
        guard ignoringCursorIdle || now - lastMouseMove < Self.cursorIdleTimeout else { return }
        let settings = settingsStore.settings
        let displays = screens.displays
        // `WindowList` needs no permission and reads no window names (Screen Recording), and
        // `AdjacencyDetector` is pure. Nothing on this path touches Accessibility.
        let (windows, coverers) = WindowList.snapshotWithCoverers()
        lastWindows = windows
        lastCoverers = coverers
        pairs = AdjacencyDetector.pairs(in: windows,
                                        maxGap: settings.handleMaxGap,
                                        minOverlap: settings.handleMinOverlap)
            .filter { HandleBarGeometry.isWithinOneDisplay($0, displays: displays) }
        // Before the hover, because the junction knobs come out of these pairs and take precedence
        // over the pill at the crossings: `claimsPoint` below has to be answering for this snapshot.
        onPairs?(pairs, windows, coverers)
        // Re-hovered from the new pairs, not only from cursor movement: the windows may have moved
        // under a cursor that did not.
        updateHover(at: CoordinateSpace.cgPoint(fromCocoa: NSEvent.mouseLocation))
    }

    /// On change only: the suspension boundary and what it was for.
    private func noteSuspension(_ clause: String?) {
        switch (suspension, clause) {
        case (nil, .some(let clause)):
            suspension = (clause, CACurrentMediaTime())
            Logger.handle.info("handle bar suspended: \(clause, privacy: .public)")
        case (.some(let current), .some(let clause)) where current.clause != clause:
            suspension = (clause, current.since)
            Logger.handle.info("handle bar suspended: \(clause, privacy: .public)")
        case (.some(let current), nil):
            suspension = nil
            Logger.handle.info("handle bar active again after \(CACurrentMediaTime() - current.since, format: .fixed(precision: 1)) s")
        default:
            break
        }
    }

    /// On change only: the falling edge of the mouse-moved poll. The rising edge is in
    /// `noteMouseMoved`, where the true gap is known to the event rather than to the next tick.
    private func noteIdle(at now: CFTimeInterval) {
        guard !pollIsIdle, now - lastMouseMove >= Self.cursorIdleTimeout else { return }
        pollIsIdle = true
        lastMoveBeforeIdle = lastMouseMove
        Logger.handle.info("poll idle: no mouse-moved event for \(Self.cursorIdleTimeout, format: .fixed(precision: 1)) s")
    }

    private func noteMouseMoved() {
        let now = CACurrentMediaTime()
        if pollIsIdle {
            pollIsIdle = false
            Logger.handle.info("poll resumed after \(now - self.lastMoveBeforeIdle, format: .fixed(precision: 1)) s without a mouse-moved event")
        }
        lastMouseMove = now
    }

    private func updateHover(at point: CGPoint) {
        guard active else { hidePanel(); return }
        // Inside the band around a crossing the junction knob is the target, and the two pills that
        // meet there are not offered at all. Everywhere else along the divider they still are.
        let candidate = claimsPoint?(point) == true
            ? nil
            : pairs.first { HandleBarGeometry.band(for: $0).contains(point) }
        // A pair whose drawn pill is covered is refused, same as a pair whose band the cursor never
        // entered — the covering window is what the user sees over the gap either way.
        let hit = candidate.flatMap { occlusionFilter($0) }
        // `HandlePair` carries both windows' frames, so this is also how the pill follows two windows
        // that moved: a pair whose geometry changed is a different pair and gets a fresh layout.
        guard hit != hovered else { return }
        hovered = hit
        if let hit {
            hideWork?.cancel()
            hideWork = nil
            panel.show(pair: hit)
        } else {
            scheduleHide()
        }
    }

    /// Occlusion is judged where the pill is actually drawn, not along the whole divider.
    /// `HandleBarGeometry.panelRect(for:divider:)` is used rather than `band(for:)` because it is
    /// exactly the rect `HandlePanel.layout` gives the panel — at rest (never dragging here, since this
    /// runs only while `drag == nil`) the two are numerically identical, but `panelRect` is the one
    /// that is actually the drawn frame and stays correct if that ever changes.
    ///
    /// Logged once per change, not on every 10 Hz poll: `lastOcclusion` remembers the pair and
    /// occluder last reported, so a pair that stays covered for several ticks logs once.
    private func occlusionFilter(_ pair: HandlePair) -> HandlePair? {
        let pillRect = HandleBarGeometry.panelRect(for: pair, divider: pair.divider)
        guard let occluder = AdjacencyDetector.occluder(of: pair, pillRect: pillRect,
                                                        in: lastWindows + lastCoverers) else {
            lastOcclusion = nil
            return pair
        }
        if lastOcclusion?.pair != pair || lastOcclusion?.occluderID != occluder.id {
            Logger.handle.debug("""
                pair \(pair.a.id)|\(pair.b.id) occluded by \(occluder.id) (pid \(occluder.pid), \
                z \(occluder.zIndex)) at \(String(describing: pillRect), privacy: .public)
                """)
        }
        lastOcclusion = (pair, occluder.id)
        return nil
    }

    private func scheduleHide() {
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                // The cursor may have come back, or a drag may have started, in the meantime.
                guard self.hovered == nil, self.drag == nil else { return }
                self.panel.dismiss()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: work)
    }

    private func hidePanel(forInterruption: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        hovered = nil
        if forInterruption { panel.fadeOutForInterruption() } else { panel.dismiss() }
    }

    /// The whole Accessibility cost of the gesture until the release, paid once, on the press: two
    /// window lookups, two resizable checks and two frame reads. **These are the last Accessibility
    /// calls before the mouse-up** — everything between them and it is pure arithmetic and three
    /// panels — and the two frames read here are what every target frame of the drag is computed from
    /// and what the release animation starts from.
    private func beginDrag(_ pair: HandlePair) -> Bool {
        guard let a = ax.handle(forWindowID: pair.a.id, pid: pair.a.pid),
              let b = ax.handle(forWindowID: pair.b.id, pid: pair.b.pid) else {
            Logger.handle.error("no Accessibility window for \(pair.a.id) or \(pair.b.id); no resize")
            return false
        }
        guard ax.isResizable(a), ax.isResizable(b) else {
            Logger.handle.info("window \(pair.a.id) or \(pair.b.id) cannot be resized; no resize")
            return false
        }
        var pair = pair
        // The snapshot is up to 100 ms old and the far edges are what the gesture pivots on, so both
        // frames are re-read once, here — and never again while the divider moves.
        if let frame = ax.frame(of: a) { pair.a.frame = frame }
        if let frame = ax.frame(of: b) { pair.b.frame = frame }
        let gap = pair.orientation == .horizontal
            ? pair.b.frame.minX - pair.a.frame.maxX
            : pair.b.frame.minY - pair.a.frame.maxY
        // The pair was offered against a snapshot; the read above is the truth. A pair that no longer
        // passes its own rule is two windows that moved since, and resizing them to a divider derived
        // from where they used to be would throw one of them across the screen.
        guard gap >= AdjacencyDetector.minGap, gap <= settingsStore.settings.handleMaxGap else {
            Logger.handle.debug("""
                pair \(pair.a.id)/\(pair.b.id) moved since the snapshot: gap \(gap, format: .fixed(precision: 1)) pt \
                is outside \(AdjacencyDetector.minGap, format: .fixed(precision: 1))…\
                \(self.settingsStore.settings.handleMaxGap, format: .fixed(precision: 1)); no resize
                """)
            return false
        }
        pair.gap = gap
        // After the gap check, so a press this class is about to decline never costs a window its
        // blink — and after the frame reads, because the probe restores each window to the size read
        // there.
        // The window's own working area travels with the probe so that a floor claiming most of the
        // display can be disbelieved on its face (`MinimumSizePolicy.implausibleFloorShare`). A window
        // on no display at all passes nil, which simply skips that test.
        let areaA = screens.display(containing: pair.a.frame.center)?.visibleFrame.size
        let areaB = screens.display(containing: pair.b.frame.center)?.visibleFrame.size
        let minSizes = HandleDragMath.MinSizes(
            a: MinimumProbe.minimum(of: a, currentSize: pair.a.frame.size, area: areaA, ax: ax,
                                    store: minimums, log: Logger.handle,
                                    probingAllowed: settingsStore.settings.probeMinimumSizes),
            b: MinimumProbe.minimum(of: b, currentSize: pair.b.frame.size, area: areaB, ax: ax,
                                    store: minimums, log: Logger.handle,
                                    probingAllowed: settingsStore.settings.probeMinimumSizes))
        drag = Drag(pair: pair,
                    a: Side(handle: a, target: pair.a.frame),
                    b: Side(handle: b, target: pair.b.frame),
                    gap: settingsStore.settings.gap, minSizes: minSizes, began: CACurrentMediaTime(),
                    lastEventAt: CACurrentMediaTime())
        hovered = pair
        hideWork?.cancel()
        hideWork = nil
        panel.show(pair: pair)
        panel.setDragging(true)
        // Every display, and only once the gesture is certain to run: the dim is the picture that says
        // nothing on screen is true until the button comes up.
        dim.fadeIn(over: screens.displays)
        Logger.handle.debug("""
            handle drag started between \(pair.a.id) and \(pair.b.id), gap \(gap, format: .fixed(precision: 1)); \
            previewing only — both windows move on release; minimums \
            \(minSizes.a.width, format: .fixed(precision: 0))×\(minSizes.a.height, format: .fixed(precision: 0)) / \
            \(minSizes.b.width, format: .fixed(precision: 0))×\(minSizes.b.height, format: .fixed(precision: 0))
            """)
        return true
    }

    /// One `.dragged` event, or the re-resolution at mouse-up.
    ///
    /// Everything moves on **every** event, because everything that moves is a panel: the pill, and
    /// the two previews standing where the two windows will be. The arithmetic between them is
    /// `HandleDragMath` and is pure, and it is computed from the frames the *press* read rather than
    /// from the last pass's targets, so the far edges cannot drift and a pass is a function of the
    /// pointer alone.
    ///
    /// `minSizes` is the pair's, fixed at the press and never revised: nothing during the drag could
    /// revise it, because nothing during the drag asks a window anything. The clamp inside
    /// `HandleDragMath.frames` is what stops the divider at a window's floor while the pointer carries
    /// on, and because the whole pass is a pure function of `point` there is nothing to unwind when the
    /// pointer comes back — the divider simply follows it again from the limit.
    private func updateDrag(to point: CGPoint) {
        guard var live = drag, live.isLive else { return }
        // Pausing or suspending mid-drag drops the gesture rather than freezing it, exactly as the
        // window drag does.
        guard active else { cancel(); return }
        let requested = live.pair.orientation == .horizontal ? point.x : point.y
        let result = HandleDragMath.frames(for: live.pair, divider: requested, gap: live.gap,
                                           minSizes: live.minSizes)
        live.a.target = result.a.roundedToPoints()
        live.b.target = result.b.roundedToPoints()
        // The previews are glued to the targets with no animation of their own: at 120 Hz a 0.15 s
        // ease would put them a tenth of a second behind the divider the user is holding. They morph
        // out of the two windows on the first event, the way a snap preview leaves the window being
        // dragged — and here it is nearly a no-op, because a window's frame and its first target
        // differ only by the gap normalization.
        previews.track([live.a.target, live.b.target],
                       appearingFrom: [live.pair.a.frame, live.pair.b.frame])
        // The gap is normalized on the first movement, and the band thickens or thins with it. The
        // frames in `pair` stay as the press read them; only the gap the pill is drawn from moves,
        // and the divider travels as an argument.
        live.pair.gap = live.gap
        drag = live
        // The divider the pill is drawn at is read back off the very frames the previews above were
        // given, not off `result.divider`: those are rounded to whole points and that is not, so the
        // two would otherwise disagree by up to half a point, and *differently* on every pointer
        // event. One sample, one pass, one rounding: the overlay is authoritative, and these are the
        // overlay's own frames — no window is asked anything.
        panel.move(divider: HandleBarGeometry.divider(between: live.a.target, and: live.b.target,
                                                      orientation: live.pair.orientation),
                   pair: live.pair)
    }

    /// Does this frame give ground on either axis? The window that does is the one whose release
    /// animation is started first.
    private static func shrinks(_ wanted: CGSize, from current: CGSize) -> Bool {
        wanted.width < current.width || wanted.height < current.height
    }

    /// Mouse-up, and the only moment of the gesture at which a window is touched at all.
    ///
    /// The previews go out on their own fade while the windows start moving underneath them: they are
    /// standing exactly where the windows are going, so there is nothing to wait for and no hand-off
    /// to arrange. Both windows then animate through `SteppingSnapEngine` over `animationDuration`,
    /// from the frame the press read to the frame the preview showed.
    ///
    /// **The shrinking window is started first**: a divider drag moves one shared edge, so the growing
    /// window's target overlaps where the shrinking one still is. The two animations then run
    /// together on the display link, and because both
    /// interpolate linearly between two frames of the same duration, the gap between the facing edges
    /// interpolates between the gap at the press and the gap setting — never less than either, so the
    /// asked-for frames cannot cross. What can still cross is a window that *refuses* to shrink while
    /// its neighbour grows into where it is; that is the same refusal the release logs and does not
    /// correct.
    ///
    /// Until both animations have answered this class keeps its `Drag`, so `isDragging` stays true and
    /// neither the poll, nor the junction knobs, nor a fresh press begins anything on two windows that
    /// are still moving.
    private func release() {
        guard var live = drag, live.isLive else { return }
        live.released = true
        panel.setDragging(false)
        previews.dismiss()
        // With the previews, and for the same reason: the button is up, so the picture the dim was
        // framing is over. The windows animate to place on a screen that is already coming back.
        dim.fadeOut()
        guard live.moved else {
            // A press and release that never moved: the gap is normalized on the first movement and
            // a bare click is not one, so the two windows are left exactly as they were.
            drag = live
            endDrag()
            return
        }
        // The pair is on one display by construction (`HandleBarGeometry.isWithinOneDisplay`), so one
        // lookup answers for both windows. The working area travels with each animation because the
        // minimum-size anchoring needs to know which edges are the display's own.
        guard let display = screens.display(containing: live.pair.a.frame.center),
              let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else {
            Logger.handle.error("no display under the pair at release; neither window moved")
            drag = live
            endDrag()
            return
        }
        // Flags set and `drag` stored *before* the first write starts: a completion can arrive
        // synchronously, and it must find the gesture it belongs to.
        live.a.animating = true
        live.b.animating = true
        drag = live
        let duration = settingsStore.settings.animationDuration
        let aFirst = Self.shrinks(live.a.target.size, from: live.pair.a.frame.size)
        for isA in (aFirst ? [true, false] : [false, true]) {
            let side = isA ? live.a : live.b
            let window = isA ? live.pair.a : live.pair.b
            let target = side.target
            engine.snap(side.handle, from: window.frame, to: target, within: display.visibleFrame,
                        duration: duration, on: screen, refusal: .anchorInward) { [weak self] landed in
                self?.animated(side.handle, id: window.id, asked: target, landed: landed)
            }
        }
        Logger.handle.debug("""
            handle released: animating \(live.pair.a.id) and \(live.pair.b.id) over \
            \(Int(duration * 1000)) ms, \(aFirst ? "a" : "b", privacy: .public) first
            """)
    }

    /// One of the two release animations has finished: with the frame the window took, or with nil
    /// because it was cancelled or had no screen. Both end this window's part of the gesture.
    ///
    /// A window that landed **larger on the divider's axis** than it was asked for is a window whose
    /// application refused the size, and two things follow from it. The refusal raises **this
    /// window's own floor** (§6) — never its application's row — so the next gesture on this window
    /// stops the divider there rather than promising the same size again; and the neighbour is
    /// re-fitted against the frame this window actually took, so the pair
    /// does not end overlapping. Anything else it landed differently — a position an application
    /// adjusted, a size smaller than asked — is logged and left.
    ///
    /// The re-fit is only **recorded** here. It runs from `startRefit`, once both animations have
    /// answered: a `SteppingSnapEngine.snap` on a window the engine is still animating cancels that
    /// animation, and a cancelled animation reports nil through the very completion this is.
    private func animated(_ handle: WindowHandle, id: UInt32, asked: CGRect, landed: CGRect?) {
        guard var live = drag, live.released else { return }
        let isA: Bool
        if handle == live.a.handle {
            isA = true
            live.a.animating = false
            live.a.landed = landed
        } else if handle == live.b.handle {
            isA = false
            live.b.animating = false
            live.b.landed = landed
        } else {
            return
        }
        if let landed {
            // Every landing is a free look at the window's size, which may lower its row (§6).
            MinimumProbe.logLowering(minimums.observe(handle, size: landed.size), window: id,
                                     size: landed.size, log: Logger.handle)
            if landed != asked {
                Logger.handle.debug("""
                    window \(id) landed \(String(describing: landed), privacy: .public) for \
                    \(String(describing: asked), privacy: .public)
                    """)
            }
            let horizontal = live.pair.orientation == .horizontal
            let overshoot = horizontal ? landed.width - asked.width : landed.height - asked.height
            if overshoot > Self.refusalTolerance {
                // Only the divider's axis. The other one was never asked to change, so the size it came
                // back with is not evidence of a floor — and a zero says nothing to
                // `MinimumSizeStore.refused`, which is exactly what is wanted there.
                let revealed = MinimumSizePolicy.revealedFloor(landed: landed.size, asked: asked.size)
                let refused = horizontal ? CGSize(width: revealed.width, height: 0)
                                         : CGSize(width: 0, height: revealed.height)
                // A landing is evidence of a floor only once it is evidence that the write happened at
                // all. `landed` is read back after the last write, and an application that has not
                // applied it yet answers with the frame it had at the press — which looks exactly like
                // a total refusal and would raise a floor this window can then never get below.
                // A release moves the window's origin as well as its size, so a real refusal still
                // passes on its position alone. The **re-fit below is not gated** by either test: it
                // is about where the window actually is, which is true whatever it means.
                let pressFrame = isA ? live.pair.a.frame : live.pair.b.frame
                if refused != .zero, MinimumSizePolicy.landingIsEvidence(landed: landed, before: pressFrame) {
                    let own = minimums.refused(refused, for: handle) ?? refused
                    Logger.handle.info("""
                        window \(id) refused by \(overshoot, format: .fixed(precision: 1)) pt; its own floor \
                        is now \(own.width, format: .fixed(precision: 0))×\(own.height, format: .fixed(precision: 0)); \
                        the row for \(Self.appKey(for: handle), privacy: .public) stands
                        """)
                } else if refused == .zero {
                    Logger.handle.debug("""
                        window \(id) landed \(overshoot, format: .fixed(precision: 1)) pt over its ask, \
                        within what an application rounds by; no minimum learned
                        """)
                }
                // The neighbour of the refuser is the side that moves. Two refusals cannot both be
                // cleared — the pair does not fit — so the larger one wins.
                if live.refit.map({ overshoot > $0.overshoot }) ?? true {
                    live.refit = Refit(neighbourIsB: isA, against: landed, overshoot: overshoot)
                }
            }
        } else {
            Logger.handle.error("""
                window \(id) did not answer its release animation; it may not be where the drag left \
                it (asked \(String(describing: asked), privacy: .public))
                """)
        }
        drag = live
        guard !live.a.animating, !live.b.animating else { return }
        if live.refit != nil { startRefit(); return }
        endDrag()
    }

    /// Both windows have stopped, and one of them stopped somewhere it was not asked to. The neighbour
    /// is animated once more, against the frame the refuser actually took rather than against the one
    /// the divider asked for, so the two cannot be left overlapping.
    ///
    /// One pass and no more: `refitted` does not look at its own outcome. A neighbour that refuses the
    /// re-fit as well is a pair that genuinely does not fit at this divider, and a second round would
    /// only be a third frame nobody chose.
    private func startRefit() {
        guard var live = drag, let refit = live.refit else { return }
        live.refit = nil
        let neighbour = refit.neighbourIsB ? live.b : live.a
        let minimum = refit.neighbourIsB ? live.minSizes.b : live.minSizes.a
        let fitted = HandleDragMath.refit(neighbour.target, after: refit.against,
                                          orientation: live.pair.orientation,
                                          neighbourIsB: refit.neighbourIsB,
                                          gap: live.gap, minimum: minimum).roundedToPoints()
        let from = neighbour.landed ?? neighbour.target
        let id = refit.neighbourIsB ? live.pair.b.id : live.pair.a.id
        // A pair with no display under it is a gesture whose arithmetic was measured on a display
        // that may be gone, and nothing should be corrected against that.
        guard fitted != from,
              let display = screens.display(containing: live.pair.a.frame.center),
              let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else {
            // Nothing to move, or no display to move it on. Either way the gesture is over; the log in
            // `animated` already recorded what the windows did.
            drag = live
            endDrag()
            return
        }
        if refit.neighbourIsB {
            live.b.target = fitted
            live.b.animating = true
        } else {
            live.a.target = fitted
            live.a.animating = true
        }
        // Stored before the snap, for the reason `release` stores before its own: a duration at or
        // below the engine's 0.01 s threshold reports synchronously.
        drag = live
        Logger.handle.info("""
            re-fitting window \(id) to \(String(describing: fitted), privacy: .public) against its \
            neighbour's landed \(String(describing: refit.against), privacy: .public)
            """)
        engine.snap(neighbour.handle, from: from, to: fitted, within: display.visibleFrame,
                    duration: settingsStore.settings.animationDuration, on: screen, refusal: .anchorInward) { [weak self] landed in
            self?.refitted(neighbour.handle, id: id, asked: fitted, landed: landed)
        }
    }

    /// The re-fit has finished. Logged, not corrected — see `startRefit`.
    private func refitted(_ handle: WindowHandle, id: UInt32, asked: CGRect, landed: CGRect?) {
        guard var live = drag, live.released else { return }
        if handle == live.a.handle {
            live.a.animating = false
            live.a.landed = landed
        } else if handle == live.b.handle {
            live.b.animating = false
            live.b.landed = landed
        } else {
            return
        }
        drag = live
        if let landed, landed != asked {
            Logger.handle.debug("""
                re-fitted window \(id) landed \(String(describing: landed), privacy: .public) for \
                \(String(describing: asked), privacy: .public); not corrected again
                """)
        }
        guard !live.a.animating, !live.b.animating else { return }
        endDrag()
    }

    /// Both windows have stopped moving. One line per drag: how long the divider was held, and what
    /// the release did.
    private func endDrag() {
        guard let live = drag else { return }
        drag = nil
        let wall = max(CACurrentMediaTime() - live.began, 0.001)
        Logger.handle.info("""
            pill drag over \(Int(wall * 1000)) ms: \
            \(live.moved ? "both windows animated to the previewed frames"
                         : "no movement, nothing written", privacy: .public)
            """)
        // Both windows have new frames; the pairs in hand describe where they used to be.
        lastMouseMove = CACurrentMediaTime()
        tick()
    }

    /// The mouse-up never arrived. Whatever is pending is dropped and nothing further is written; the
    /// writes that already landed stand, because they happened and the user watched them happen. The
    /// gesture is not completed — the release frame is precisely the one nobody can prove.
    private func orphan(_ live: Drag) {
        drag = nil
        previews.dismiss()
        dim.fadeOut()
        panel.setDragging(false)
        Logger.handle.error("handle drag orphaned: button up for two polls with no events; nothing written")
        // The pointer was moving a moment ago, whatever swallowed the mouse-up, so the poll is due —
        // the same stamp `endDrag` makes, and for the same reason: the pairs in hand are stale.
        lastMouseMove = CACurrentMediaTime()
    }

    /// Is the left button still down? The authority on it is the window server's own combined state,
    /// not this app's event stream — the whole point is that the event stream lost something.
    ///
    /// Both handle features ask it — the pill on this class's 100 ms poll, the knob on a timer of its
    /// own, because this poll stands down for the whole of a knob drag. Which authority answers "is
    /// the button down" is one decision and belongs in one place.
    static func leftButtonIsDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// How an application is named in a log line. The bundle identifier where there is one, so a line
    /// about an application survives it being relaunched inside a session; the pid otherwise, which
    /// at least holds for the life of that process.
    static func appKey(for handle: WindowHandle) -> String {
        NSRunningApplication(processIdentifier: handle.pid)?.bundleIdentifier ?? "pid:\(handle.pid)"
    }

}
