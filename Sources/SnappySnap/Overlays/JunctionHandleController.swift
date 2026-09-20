import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// Where two of the handle bar's dividers cross, a knob moves **three windows (a T) or four (a
/// cross) at once**, dragged in both axes.
///
/// **It extends the handle bar rather than repeating it.** There is no second window-list poll: the
/// snapshot `HandleBarController` already takes on its 100 ms tick is handed here through
/// `update(windows:coverers:)`, and `JunctionDetector` turns it into junctions with no Accessibility traffic
/// at all. There is no second minimum rule: `MinimumProbe` answers for the pill and the
/// knob alike. There is no second release: both animate through the one `SteppingSnapEngine`. And
/// there is no second hit-test path: presses come off the global mouse stream through
/// `AppDelegate.route`, tested in CG space against `JunctionGeometry.band(at:)` — the same function
/// that positions the panel.
///
/// **Nothing is resized while the knob moves.** The drag draws its own outcome — one zone preview
/// per member, at the frame that member will take, glued to the pointer through
/// `WindowPreviewGroup`, over a `DimGroup` that takes the rest of the screen back 30 % — and on the
/// mouse-up every member animates to that frame through `SteppingSnapEngine`, the same engine and
/// the same `animationDuration` as every snap.
///
/// Three or four frames a gesture therefore reach Accessibility, rather than three or four a
/// display frame, and they reach it after the button is up, so a slow application costs an
/// animation that lags rather than a knob that fights the pointer.
///
/// **Minimum sizes.** A drag that writes nothing has nothing to read a refusal back from, so the
/// minimum arrives before the first `.dragged` event: `MinimumProbe.minimum` returns what
/// `MinimumSizeStore` holds for the application and the window, or probes it once (set 1 × 1, read
/// back, restore) if it does not. `JunctionDragMath.frames` then clamps **each axis on its own** — a
/// crossing blocked by a minimum horizontally still moves vertically — and because every pass is a
/// pure function of the pointer, the knob and all the previews simply **stop** while the pointer
/// carries on and pick it up again with no jump when it comes back.
///
/// **What the release still corrects.** A stored minimum is a floor, not a grid, so a window can land
/// larger than it was asked for anyway. When one does, by more than a point on an axis it was asked to
/// change, the release learns that size and re-fits the members on the **other side of that divider**
/// against the frame the refuser actually took (`JunctionDragMath.refit`) — one further round of
/// `SteppingSnapEngine.snap`, after every first-round animation has finished, so the arrangement
/// cannot end overlapping. The re-fit is not itself corrected.
///
/// **What a drag costs the run loop.** Nothing that can be measured. The gesture's whole Accessibility
/// cost is paid at the press — one window lookup, one resizable check and one frame read per member,
/// plus a probe for any application with no row — and between the
/// press and the mouse-up the main thread only ever runs `JunctionDragMath`, which is pure, and moves
/// a handful of panels. Two consequences, and they are what this class is:
///
/// - **The overlay is authoritative.** The knob and the previews follow the pointer on *every*
///   `.dragged` event, at whatever rate the tap delivers them, because moving a panel is free. Nothing
///   about a window can feed back into where they are drawn, because no window is asked anything.
/// - **A drag cannot outlive the button.** A lost mouse-up would otherwise leave the gesture
///   latched. A 10 Hz watchdog asks the window server whether the left button is still down and
///   cancels the gesture — writing nothing — once `OrphanDetector` says the mouse-up is *lost*
///   rather than merely made: the button up on two consecutive polls, and no mouse event in the
///   last one. It is this class's own timer rather than the handle bar's poll, because the handle
///   bar stands down for the whole of a knob drag and its tick returns before the button is ever
///   looked at.
@MainActor
final class JunctionHandleController {

    /// One window of the junction, for the length of one gesture.
    private struct Member {
        let id: UInt32
        let handle: WindowHandle
        /// The frame the press read. The pivot of the whole gesture — every pass computes every target
        /// from these, so nothing can drift a point per frame — and where the release animation starts.
        let pressFrame: CGRect
        /// This window's floor, resolved once at the press: stored, probed, or `MinimumProbe.fallback`.
        /// It is what clamps the crossing, and what a re-fit clamps this window's size to.
        let minSize: CGSize
        /// Where the crossing's current position puts this window: what its preview is drawn at, and on
        /// the release what it is animated to. Seeded with the press frame, so a press that never moves
        /// has a target that asks for nothing.
        var target: CGRect
        /// Whether this window's release animation is still running. The gesture is not over — and the
        /// pill and the poll do not come back — until every member has answered.
        var animating = false
        /// Where this window actually ended up, once its animation has reported.
        var landed: CGRect?

        /// Does this window give ground on either axis? The ones that do are animated first.
        var shrinks: Bool {
            target.width < pressFrame.width || target.height < pressFrame.height
        }
    }

    /// A drag in progress, and then — between the mouse-up and the last animation finishing — one that
    /// is settling.
    private struct Drag {
        /// The junction as the press read it, and never written to: its member frames are the far edges
        /// the whole gesture pivots on, and its point is the crossing they imply.
        let junction: Junction
        /// In the junction's own member order (window id).
        var members: [Member]
        /// The gap the drag normalizes to — the gap setting, read once when the press landed.
        let gap: Double
        /// The working area of the display under the crossing, read once when the press landed. What
        /// keeps a one-sided axis — the members' shared edge growing outwards with nothing else to
        /// stop it — from being dragged over the menu bar or behind the Dock.
        let visibleFrame: CGRect
        /// Whether a drag event has arrived at all. The gap is normalized on the first movement,
        /// so a press and release that never moved must leave every window exactly as it was.
        var moved = false
        let began: CFTimeInterval
        /// When this drag last saw a mouse event — the press, then every `.dragged`. It is half of
        /// the cancel rule (`OrphanDetector`): a stream that was alive a moment ago means the `.up`
        /// is on its way behind it.
        var lastEventAt: CFTimeInterval
        /// Consecutive watchdog polls that have read the left button up, reset by any poll that reads
        /// it down. The other half of the rule.
        var ticksButtonUp = 0
        /// Set at mouse-up. From here on the gesture is over on screen — the knob narrows back, the
        /// previews and the dim fade — and the only thing left is the animations; the button watchdog
        /// stands down, and `endDrag` runs when every member has reported.
        var released = false
        /// Refusals gathered from the release animations, run once they have all answered. Held rather
        /// than acted on at the moment they are found: starting a snap on a window the engine is still
        /// animating cancels that animation, and a cancelled animation reports nil through the very
        /// completion that is deciding this.
        var refusals: [JunctionDragMath.Refusal] = []
        /// The one re-fit round has been started. What makes a second impossible.
        var refitting = false

        var isLive: Bool { !released }
        var settled: Bool { members.allSatisfy { !$0.animating } }
        var minSizes: [UInt32: CGSize] {
            Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.minSize) })
        }

        func index(of handle: WindowHandle) -> Int? { members.firstIndex { $0.handle == handle } }
    }

    private let ax: AccessibilityWindows
    /// The release animation, every member through it. The one engine every snap already uses,
    /// called directly rather than through `EngineRouter`: a knob drag lands a window on a frame
    /// and not in a `Zone`, so there is nothing for `SnapRegistry` to record and no unsnap to offer.
    private let engine: SteppingSnapEngine
    private let screens: any ScreensProviding
    private let settingsStore: SettingsStore
    /// What each application will not shrink below. Owned by `AppDelegate` and shared with the pill,
    /// because it is a fact about other applications and not about either feature.
    private let minimums: MinimumSizeStore
    /// One zone preview per member, at the frame that member will take. This is what the drag moves
    /// instead of the windows.
    private let previews = WindowPreviewGroup()
    /// The rest of the screen, taken back 30 % for the length of the gesture.
    private let dim = DimGroup()

    /// True while another feature owns the screen: Snap Assist's phase, or a pair-handle drag that
    /// is already moving two of the windows a knob would claim. Set by `AppDelegate` after both
    /// controllers exist, because the dependency runs both ways.
    var isSuspended: @MainActor () -> Bool = { false }
    /// Called when a gesture is completely finished — the last animation answered, or it was cancelled
    /// or orphaned — so the handle bar can poll again.
    var onDragEnded: (@MainActor () -> Void)?

    private let panel = JunctionPanel()
    private var junctions: [Junction] = []
    private var hovered: Junction?
    private var drag: Drag?
    private var hideWork: DispatchWorkItem?
    /// The button watchdog, alive only while a drag is. See `startWatchdog`.
    private var watchdog: Timer?
    /// The verdict lines last logged, as an unordered set, so "once per change" holds across the
    /// 10 Hz poll rather than repeating a crossing's rejection on every tick it stays rejected.
    private var lastVerdictLines: Set<String> = []

    init(ax: AccessibilityWindows, engine: SteppingSnapEngine,
         screens: any ScreensProviding,
         settingsStore: SettingsStore, minimums: MinimumSizeStore) {
        self.ax = ax
        self.engine = engine
        self.screens = screens
        self.settingsStore = settingsStore
        self.minimums = minimums
    }

    /// True while this feature owns a gesture — including the settling period after the mouse-up, when
    /// the button is already up but three or four windows are still animating to the frames the
    /// previews showed. The handle bar stands down for all of it: during the drag because the knob owns
    /// the same windows, and during the settling because a gesture begun there would read the frame of
    /// a window that is mid-animation and pivot on it.
    ///
    /// It cannot latch. The drag ends on the mouse-up, on the watchdog, on a cancel, or — in the
    /// settling state — when every animation has reported, and `SteppingSnapEngine` reports whatever
    /// the applications are doing: each animation is bounded by `animationDuration` plus one
    /// `setFrame`, whose own worst case against a hung application is 1.25 s.
    var isBusy: Bool { drag != nil }

    /// `isBusy` plus the knob that is merely on offer. An interruption has to take that one away
    /// too, for the reason `HandleBarController.isShowing` gives: a hovered knob is holding nothing
    /// and would otherwise stay up over Mission Control.
    var isShowing: Bool { isBusy || hovered != nil }

    /// The window snapshot of one poll, turned into junctions. `JunctionDetector.evaluate` runs once —
    /// clustering corners, resolving occupancy and applying the covering rule — its verdicts are
    /// logged, and the junctions are derived from those same verdicts. Pure arithmetic: nothing here
    /// touches Accessibility, and no window list is fetched a second time.
    func update(windows: [WindowInfo], coverers: [WindowInfo]) {
        // A live drag owns its own geometry: the members' frames are the ones the press read, and a
        // snapshot taken while the release is still moving them describes neither.
        guard !isBusy else { return }
        guard active else { junctions = []; lastVerdictLines = []; hidePanel(); return }
        let verdicts = JunctionDetector.evaluate(in: windows, coverers: coverers,
                                                 maxGap: settingsStore.settings.handleMaxGap)
        logVerdictChanges(verdicts)
        junctions = JunctionDetector.junctions(from: verdicts)
        // Re-hovered from the new junctions, not only from cursor movement: the windows may have
        // moved under a cursor that did not.
        updateHover(at: CoordinateSpace.cgPoint(fromCocoa: NSEvent.mouseLocation))
    }

    /// Silence is a defect: logs every rejected crossing's reason and every accepted one, but only
    /// when the *set* of verdicts has changed since the last poll, never on every 10 Hz tick.
    private func logVerdictChanges(_ verdicts: [JunctionDetector.Verdict]) {
        let lines: Set<String> = Set(verdicts.map { verdict in
            switch verdict {
            case .accepted(let junction):
                let kind = Self.kind(of: junction)
                return "accepted \(kind) of \(junction.members.count) at " +
                    "(\(Int(junction.point.x)),\(Int(junction.point.y)))"
            case .rejected(let point, let reason):
                return "rejected at (\(Int(point.x)),\(Int(point.y))): \(reason.description)"
            }
        })
        guard lines != lastVerdictLines else { return }
        lastVerdictLines = lines
        for line in lines.sorted() {
            Logger.junction.debug("\(line, privacy: .public)")
        }
    }

    /// The knob's precedence over the pill, asked by the handle bar before it offers a pill or
    /// takes a press. Two targets at one point would make which windows move depend on a pixel.
    func claims(_ point: CGPoint) -> Bool {
        guard active else { return false }
        return junctions.contains { JunctionGeometry.band(at: JunctionGeometry.knobCentre(for: $0)).contains(point) }
    }

    /// Returns true when the event belongs to a junction drag and must not travel on — neither to the
    /// handle bar nor to the window-drag session, both of which would otherwise run a second state
    /// machine over the same gesture.
    @discardableResult
    func handle(_ event: MouseEvents.Event) -> Bool {
        switch event {
        case .moved(let point):
            if drag == nil { updateHover(at: point) }
            return false
        case .down(let point):
            // A press inside a band this feature claimed is **ours whether or not a gesture starts**.
            // Everything below can decline — nothing hovered, no Accessibility window, a window that
            // will not resize, a revalidation that finds the crossing gone — and if the event then
            // travelled on it would reach neither the pill (which declines a claimed point by the
            // same rule) nor nothing at all, but `DragSessionController`, which would arm a *window
            // drag* on whatever sits under the crossing. A press on a handle must never do that.
            guard active, claims(point) else { return false }
            guard !isBusy else {
                // The button is up and the previous gesture's windows are still animating to the
                // frames it left them. Beginning here would read a frame that is mid-flight and pivot
                // this gesture's outer edges on it.
                Logger.junction.debug("press at a crossing while the previous gesture is still settling; swallowed")
                return true
            }
            guard let junction = hovered,
                  JunctionGeometry.band(at: JunctionGeometry.knobCentre(for: junction)).contains(point) else {
                Logger.junction.debug("press inside a claimed crossing with nothing hovered; swallowed")
                return true
            }
            if !beginDrag(junction) {
                Logger.junction.debug("junction press declined; swallowed so it cannot arm a window drag")
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
            // A `.up` that finds no drag at all writes nothing — that is the one that follows a
            // drag the watchdog has already orphaned, and it belongs to nobody.
            guard let live = drag else { return false }
            // One that finds a settling drag is the release of the press swallowed above. Ours, and
            // still nothing to write.
            guard live.isLive else { return true }
            // The release point is resolved once more *if the knob was ever moved*: the frames the user
            // let go on are the ones that have to land — the window drag re-resolves at mouse-up
            // for the same reason — and `.up` can carry a point no `.dragged` reported. A press and
            // release with no movement resolves nothing at all, because the gap is normalized on
            // the first movement and a bare click is not one.
            if live.moved { updateDrag(to: point) }
            release()
            return true
        // Never reaches this controller — `AppDelegate.route` answers Command on its own branch, before the
        // mouse fan-out this method is part of — but the switch is exhaustive.
        case .flagsChanged: return false
        }
    }

    /// Drops a live or settling drag and the knob. Displays changing ends the session and every
    /// overlay with it — the frames the drag pivots on were measured on a display that may not
    /// exist any more.
    ///
    /// A cancelled gesture writes nothing at all: while the knob is moving there is nothing to undo,
    /// because no window has been touched since the press. A gesture cancelled *after* the mouse-up is
    /// the one case with something in flight, and its animations are stopped where they are — the
    /// frames they were heading for were measured on a display the cancel is saying may be gone.
    ///
    /// `drag` is cleared **before** the engine is told, because `SteppingSnapEngine.cancel` answers
    /// every completion it tears down: with the gesture already gone they find nothing to report
    /// against, which is what keeps the teardown out of `endDrag`.
    /// `forInterruption` sends the knob, the previews and the dim off through the shared 120 ms
    /// interruption fade rather than each surface's own dismiss. See `HandleBarController.cancel`.
    func cancel(forInterruption: Bool = false) {
        let wasLive = drag != nil
        if let live = drag {
            Logger.junction.debug("junction drag cancelled; \(live.members.count) windows, nothing further written")
            drag = nil
            if live.released {
                for member in live.members { engine.cancel(windowID: member.handle.windowID) }
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
        stopWatchdog()
        junctions = []
        lastVerdictLines = []
        hidePanel(forInterruption: forInterruption)
        // `onDragEnded` is documented as "called when a gesture is completely finished", and a
        // cancelled gesture is finished. Without this the handle bar waits for its own 100 ms tick to
        // notice — recoverable, but the contract would be a lie.
        if wasLive { announceDragEnded() }
    }

    /// Stops the background cursor at once, leaving everything else alone. The assertion must stop
    /// on Mission Control and on a Space change, and neither of those is detected here — they
    /// belong to the interruption fan-out, which calls this. Idempotent, and safe to call when no
    /// cursor is being asserted.
    ///
    /// Stopping is not setting a cursor: the application under the pointer gets its own back. If the
    /// pointer is still in the band afterwards, the next `show` starts a fresh keepalive.
    func stopCursorAssertion() {
        panel.stopAsserting()
    }

    /// See `HandleBarController.hideForCommand`. `AppDelegate` calls this only while `isBusy` is false.
    func hideForCommand() {
        hideWork?.cancel()
        hideWork = nil
        hovered = nil
        panel.hideAtOnce()
    }

    private var active: Bool {
        let settings = settingsStore.settings
        return settings.handleBar && !isSuspended()
    }

    private func updateHover(at point: CGPoint) {
        guard active else { hidePanel(); return }
        let hit = junctions.first { JunctionGeometry.band(at: JunctionGeometry.knobCentre(for: $0)).contains(point) }
        // A junction carries its members' frames, so this is also how the knob follows windows that
        // moved: a junction whose geometry changed is a different junction and gets a fresh layout.
        guard hit != hovered else { return }
        hovered = hit
        if let hit {
            hideWork?.cancel()
            hideWork = nil
            panel.show(at: JunctionGeometry.knobCentre(for: hit))
        } else {
            scheduleHide()
        }
    }

    /// The same grace as the pill's, so a jitter at the edge of the band does not flicker the knob.
    private func scheduleHide() {
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                guard self.hovered == nil, self.drag == nil else { return }
                self.panel.dismiss()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HandleBarController.hideGrace, execute: work)
    }

    private func hidePanel(forInterruption: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        hovered = nil
        if forInterruption { panel.fadeOutForInterruption() } else { panel.dismiss() }
    }

    // MARK: - The gesture

    /// The whole Accessibility cost of the gesture until the release, paid once, on the press: one
    /// window lookup, one resizable check and one frame read per member, and then a probe for any
    /// member whose application has no row and which has not been probed this session (§6).
    /// **These are the last Accessibility calls before the mouse-up** — everything between them and it
    /// is pure arithmetic and a handful of panels — and the frames read here are what every target
    /// frame of the drag is computed from and what the release animation starts from.
    ///
    /// It is the handle bar's concern with one or two more windows on it: `handle(forWindowID:pid:)`
    /// enumerates an application's window list, so this is unbounded in the *number* of windows a
    /// responsive application has open, though cheap in each and bounded against a hung one by the
    /// 0.25 s messaging timeout. Recorded rather than optimised; the fix is a way to find a window by
    /// id without walking the list, and it would take every call site with it.
    private func beginDrag(_ junction: Junction) -> Bool {
        var handles: [UInt32: WindowHandle] = [:]
        var frames: [UInt32: CGRect] = [:]
        for member in junction.members {
            let id = member.window.id
            guard let handle = ax.handle(forWindowID: id, pid: member.window.pid) else {
                Logger.junction.error("no Accessibility window for \(id); no junction resize")
                return false
            }
            guard ax.isResizable(handle) else {
                Logger.junction.info("window \(id) cannot be resized; no junction resize")
                return false
            }
            // Refused rather than fallen back on, unlike the pair handle: falling back means
            // revalidating that member against a `WindowList` frame up to 100 ms old, and the window
            // whose Accessibility read just failed is the one most likely to be moving. With three or
            // four members the odds of one being stale are three or four times the pair's, and the
            // cost of being wrong is a window thrown across the screen.
            guard let frame = ax.frame(of: handle) else {
                Logger.junction.error("no frame from window \(id); no junction resize")
                return false
            }
            handles[id] = handle
            frames[id] = frame
        }
        // The junction was offered against a snapshot up to 100 ms old; the reads above are the truth.
        // Three or four windows that have shifted since are not a junction any more, and resizing them
        // to a crossing derived from where they used to be would throw one of them across the screen.
        guard let fresh = JunctionDetector.revalidate(junction, frames: frames,
                                                      maxGap: settingsStore.settings.handleMaxGap) else {
            Logger.junction.debug("the windows at the crossing moved since the snapshot; no junction resize")
            return false
        }
        // After the revalidation, so a press this class is about to decline never costs a window its
        // blink — and after the frame reads, because the probe restores each window to the size read
        // there.
        var members: [Member] = []
        for member in fresh.members {
            guard let handle = handles[member.window.id] else { continue }
            // The member's own working area, so a floor claiming most of the display is disbelieved
            // on its face (`MinimumSizePolicy.implausibleFloorShare`).
            let area = screens.display(containing: member.window.frame.center)?.visibleFrame.size
            let minSize = MinimumProbe.minimum(of: handle, currentSize: member.window.frame.size,
                                               area: area, ax: ax, store: minimums,
                                               log: Logger.junction,
                                               probingAllowed: settingsStore.settings.probeMinimumSizes)
            members.append(Member(id: member.window.id, handle: handle, pressFrame: member.window.frame,
                                  minSize: minSize, target: member.window.frame))
        }
        guard members.count == fresh.members.count else {
            Logger.junction.error("a member lost its Accessibility window at the press; no junction resize")
            return false
        }
        guard let pressDisplay = screens.display(containing: fresh.point) else {
            Logger.junction.error("no display under the crossing at press; no junction resize")
            return false
        }
        let knobCentre = JunctionGeometry.knobCentre(for: fresh)
        drag = Drag(junction: fresh, members: members, gap: settingsStore.settings.gap,
                    visibleFrame: pressDisplay.visibleFrame,
                    began: CACurrentMediaTime(), lastEventAt: CACurrentMediaTime())
        hovered = fresh
        hideWork?.cancel()
        hideWork = nil
        panel.show(at: knobCentre)
        panel.setDragging(true)
        // Every display, and only once the gesture is certain to run: the dim is the picture that says
        // nothing on screen is true until the button comes up.
        dim.fadeIn(over: screens.displays)
        startWatchdog()
        // `privacy: .public` on the shape: `os.Logger` redacts an interpolated `String` by default,
        // and a line that reads "a <private> of 4 windows" answers nothing.
        let kind = Self.kind(of: fresh)
        let minimums = members
            .map { "\($0.id) \(Int($0.minSize.width))×\(Int($0.minSize.height))" }
            .joined(separator: ", ")
        Logger.junction.debug("""
            junction drag started: a \(kind, privacy: .public) of \(fresh.members.count) windows at \
            \(Int(fresh.point.x)),\(Int(fresh.point.y)); previewing only — every window moves on \
            release; minimums \(minimums, privacy: .public)
            """)
        return true
    }

    /// One `.dragged` event, or the re-resolution at mouse-up.
    ///
    /// Everything moves on **every** event, because everything that moves is a panel: the knob, and one
    /// preview per member standing where that window will be. The arithmetic between them is
    /// `JunctionDragMath` and is pure, and it is computed from the frames the *press* read rather than
    /// from the last pass's targets, so the outer edges cannot drift and a pass is a function of the
    /// pointer alone.
    ///
    /// `minSizes` is the gesture's, fixed at the press and never revised: nothing during the drag could
    /// revise it, because nothing during the drag asks a window anything. The per-axis clamp inside
    /// `JunctionDragMath.frames` is what stops the crossing at a window's floor while the pointer
    /// carries on, and because the whole pass is a pure function of `point` there is nothing to unwind
    /// when the pointer comes back — the crossing simply follows it again from the limit.
    private func updateDrag(to point: CGPoint) {
        guard var live = drag, live.isLive else { return }
        // Pausing or suspending mid-drag drops the gesture rather than freezing it, exactly as the
        // window drag does.
        guard active else { cancel(); return }
        let result = JunctionDragMath.frames(for: live.junction, to: point, gap: live.gap,
                                             visibleFrame: live.visibleFrame, minSizes: live.minSizes)
        for index in live.members.indices {
            if let frame = result.frames[live.members[index].id] { live.members[index].target = frame }
        }
        // The previews are glued to the targets with no animation of their own: at 120 Hz a 0.15 s ease
        // would put them a tenth of a second behind the knob the user is holding. They morph out of the
        // members' own frames on the first event, which is the way a snap preview leaves the window
        // being dragged — and here it is nearly a no-op, because a window's frame and its first
        // target differ only by the gap normalization.
        previews.track(live.members.map(\.target), appearingFrom: live.members.map(\.pressFrame))
        drag = live
        // The knob is centred on the crossing, save for the push a T gives it, which `knobCentre`
        // applies here exactly as it did at the press. The crossing is read back
        // off the very frames the previews above were given — `result.frames`, rounded to whole
        // points — and not off `result.point`, which is not rounded: the two would disagree by up
        // to half a point and disagree *differently* on every pointer event, which is the knob
        // jiggling inside its gap. One sample, one pass, one rounding. Nothing about a window feeds
        // back into this: these are the overlay's own frames, a pure function of the pointer.
        panel.move(to: JunctionGeometry.knobCentre(for: live.junction, frames: result.frames))
    }

    // MARK: - Release and settling

    /// Mouse-up, and the only moment of the gesture at which a window is touched at all.
    ///
    /// The previews and the dim go out on their own fades while the windows start moving underneath
    /// them: the previews are standing exactly where the windows are going, so there is nothing to wait
    /// for and no hand-off to arrange. Every member then animates through `SteppingSnapEngine` over
    /// `animationDuration`, from the frame the press read to the frame its preview showed.
    ///
    /// **The shrinking windows are started first**: the crossing moves two shared edges, so a
    /// growing window's target overlaps where a shrinking one still is.
    /// The animations then run together on the display link, and because they all interpolate
    /// linearly between two frames over the same duration, the gap between any two facing edges
    /// interpolates between the gap at the press and the gap setting — never less than either, so the
    /// asked-for frames cannot cross. What can still cross is a window that *refuses* to shrink while
    /// its neighbours grow into where it is; that is what the re-fit round below is for.
    ///
    /// Until every animation has answered this class keeps its `Drag`, so `isBusy` stays true and
    /// neither the poll, nor the pill, nor a fresh press begins anything on windows that are moving.
    private func release() {
        guard var live = drag, live.isLive else { return }
        live.released = true
        panel.setDragging(false)
        stopWatchdog()
        previews.dismiss()
        // With the previews, and for the same reason: the button is up, so the picture the dim was
        // framing is over. The windows animate to place on a screen that is already coming back.
        dim.fadeOut()
        guard live.moved else {
            // A press and release that never moved: the gap is normalized on the first movement
            // and a bare click is not one, so every window is left exactly as it was.
            drag = live
            endDrag()
            return
        }
        guard let display = screens.display(containing: live.junction.point),
              let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else {
            Logger.junction.error("no display under the crossing at release; no window moved")
            drag = live
            endDrag()
            return
        }
        // Flags set and `drag` stored *before* the first write starts: a completion can arrive
        // synchronously, and it must find the gesture it belongs to.
        for index in live.members.indices { live.members[index].animating = true }
        drag = live
        let duration = settingsStore.settings.animationDuration
        // Shrinking first, then by id so the order is the same every gesture and a log line can state
        // it. The same key `JunctionDragMath` sorts its own changes by.
        let order = live.members.indices.sorted {
            (live.members[$0].shrinks ? 0 : 1, live.members[$0].id)
                < (live.members[$1].shrinks ? 0 : 1, live.members[$1].id)
        }
        for index in order {
            let member = live.members[index]
            engine.snap(member.handle, from: member.pressFrame, to: member.target,
                        within: display.visibleFrame, duration: duration, on: screen, refusal: .anchorInward) { [weak self] landed in
                self?.animated(member.handle, id: member.id, asked: member.target, landed: landed)
            }
        }
        Logger.junction.debug("""
            knob released: animating \(live.members.count) windows over \(Int(duration * 1000)) ms, \
            \(order.map { String(live.members[$0].id) }.joined(separator: ","), privacy: .public) in that order
            """)
    }

    /// One of the release animations has finished: with the frame the window took, or with nil because
    /// it was cancelled or had no screen. Both end this window's part of the gesture.
    ///
    /// A window that landed **larger than it was asked for on an axis this gesture resized** is a window
    /// whose application refused the size, and two things follow from it. The refusal raises **this
    /// window's own floor** (§6), never its application's row, so the next gesture on this window
    /// stops the crossing there rather than promising the same size
    /// again; and the members on the other side of that divider are re-fitted against the frame this
    /// window actually took, so the arrangement does not end overlapping. Anything else it landed
    /// differently — a position an application adjusted, a size smaller than asked — is logged and left.
    ///
    /// The re-fit is only **recorded** here and runs from `startRefit`, once every animation has
    /// answered: a `SteppingSnapEngine.snap` on a window the engine is still animating cancels that
    /// animation, and a cancelled animation reports nil through the very completion this is.
    private func animated(_ handle: WindowHandle, id: UInt32, asked: CGRect, landed: CGRect?) {
        guard var live = drag, live.released, let index = live.index(of: handle) else { return }
        live.members[index].animating = false
        live.members[index].landed = landed
        if let landed {
            // Every landing is a free look at the window's size, which may lower its row (§6).
            MinimumProbe.logLowering(minimums.observe(handle, size: landed.size), window: id,
                                     size: landed.size, log: Logger.junction)
            if landed != asked {
                Logger.junction.debug("""
                    window \(id) landed \(String(describing: landed), privacy: .public) for \
                    \(String(describing: asked), privacy: .public)
                    """)
            }
            if let member = live.junction.member(id) {
                // Only an axis this gesture actually asked to change. A spanning member is not resized
                // on its spanning axis, so a size it came back with there is not evidence of a floor —
                // and a zero says nothing to `MinimumSizeStore.refused`, which is exactly what is wanted.
                let revealed = MinimumSizePolicy.revealedFloor(landed: landed.size, asked: asked.size)
                var refused = CGSize.zero
                let overshootX = Double(landed.width - asked.width)
                if member.x != .spanning, overshootX > HandleBarController.refusalTolerance {
                    refused.width = revealed.width
                    live.refusals.append(JunctionDragMath.Refusal(
                        id: id, axis: .x, role: member.x,
                        edge: member.x == .low ? landed.maxX : landed.minX, overshoot: overshootX))
                }
                let overshootY = Double(landed.height - asked.height)
                if member.y != .spanning, overshootY > HandleBarController.refusalTolerance {
                    refused.height = revealed.height
                    live.refusals.append(JunctionDragMath.Refusal(
                        id: id, axis: .y, role: member.y,
                        edge: member.y == .low ? landed.maxY : landed.minY, overshoot: overshootY))
                }
                // A floor is learned only past what an application rounds by
                // (`MinimumSizePolicy.revealedFloor`), and only from a landing that proves the write
                // happened — an application that has not applied the write yet answers with the frame
                // it had at the press, which reads as a total refusal
                // (`MinimumSizePolicy.landingIsEvidence`). The **re-fit above is gated by neither**: it
                // is about where the window actually is.
                if refused != .zero,
                   MinimumSizePolicy.landingIsEvidence(landed: landed,
                                                       before: live.members[index].pressFrame) {
                    let own = minimums.refused(refused, for: handle) ?? refused
                    Logger.junction.info("""
                        window \(id) refused by \(overshootX, format: .fixed(precision: 1))×\
                        \(overshootY, format: .fixed(precision: 1)) pt; its own floor is now \
                        \(own.width, format: .fixed(precision: 0))×\
                        \(own.height, format: .fixed(precision: 0)); the row for \
                        \(HandleBarController.appKey(for: handle), privacy: .public) stands
                        """)
                }
            }
        } else {
            Logger.junction.error("""
                window \(id) did not answer its release animation; it may not be where the drag left \
                it (asked \(String(describing: asked), privacy: .public))
                """)
        }
        drag = live
        guard live.settled else { return }
        if !live.refusals.isEmpty, !live.refitting { startRefit(); return }
        endDrag()
    }

    /// Every window has stopped, and at least one stopped somewhere it was not asked to. The members on
    /// the other side of each divider a refusal moved are animated once more, against the frames the
    /// refusers actually took rather than against the ones the crossing asked for, so the arrangement
    /// cannot be left overlapping.
    ///
    /// One pass and no more: `refitted` does not look at its own outcome. A member that refuses the
    /// re-fit as well is an arrangement that genuinely does not fit at this crossing, and a second round
    /// would only be a third frame nobody chose.
    private func startRefit() {
        guard var live = drag, !live.refusals.isEmpty else { return }
        let refusals = live.refusals
        live.refusals = []
        live.refitting = true
        // Where each member is believed to be *now*: what it landed on where that is known, so an
        // application that repositioned itself while answering is not fought back into place.
        var current: [UInt32: CGRect] = [:]
        for member in live.members { current[member.id] = member.landed ?? member.target }
        let fitted = JunctionDragMath.refit(live.junction, current: current, refusals: refusals,
                                            gap: live.gap, minSizes: live.minSizes)
        guard !fitted.isEmpty,
              let display = screens.display(containing: live.junction.point),
              let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else {
            // Nothing to move, or no display to move it on. Either way the gesture is over; the log in
            // `animated` already recorded what the windows did.
            drag = live
            endDrag()
            return
        }
        var moving: [(member: Member, from: CGRect, to: CGRect)] = []
        for index in live.members.indices {
            guard let frame = fitted[live.members[index].id] else { continue }
            let from = live.members[index].landed ?? live.members[index].target
            live.members[index].target = frame
            live.members[index].animating = true
            moving.append((live.members[index], from, frame))
        }
        // Stored before the snaps, for the reason `release` stores before its own: a duration at or
        // below the engine's 0.01 s threshold reports synchronously.
        drag = live
        Logger.junction.info("""
            re-fitting \(moving.count) window(s) against the frames the refusers actually took: \
            \(moving.map { String($0.member.id) }.joined(separator: ","), privacy: .public)
            """)
        let duration = settingsStore.settings.animationDuration
        for step in moving {
            engine.snap(step.member.handle, from: step.from, to: step.to, within: display.visibleFrame,
                        duration: duration, on: screen, refusal: .anchorInward) { [weak self] landed in
                self?.refitted(step.member.handle, id: step.member.id, asked: step.to, landed: landed)
            }
        }
    }

    /// One re-fit has finished. Logged, not corrected — see `startRefit`.
    private func refitted(_ handle: WindowHandle, id: UInt32, asked: CGRect, landed: CGRect?) {
        guard var live = drag, live.released, let index = live.index(of: handle) else { return }
        live.members[index].animating = false
        live.members[index].landed = landed
        drag = live
        if let landed, landed != asked {
            Logger.junction.debug("""
                re-fitted window \(id) landed \(String(describing: landed), privacy: .public) for \
                \(String(describing: asked), privacy: .public); not corrected again
                """)
        }
        guard live.settled else { return }
        endDrag()
    }

    /// Every window has stopped moving. One line per drag: what shape it was, how long the knob was
    /// held, and what the release did.
    private func endDrag() {
        guard let live = drag else { return }
        drag = nil
        panel.setDragging(false)
        stopWatchdog()
        let wall = max(CACurrentMediaTime() - live.began, 0.001)
        Logger.junction.info("""
            knob drag (\(Self.kind(of: live.junction), privacy: .public)) over \(Int(wall * 1000)) ms: \
            \(live.moved ? "\(live.members.count) windows animated to the previewed frames" : "no movement, nothing written", privacy: .public)
            """)
        announceDragEnded()
    }

    /// The mouse-up never arrived. Whatever is pending is dropped and nothing is written; the
    /// gesture is not completed — the release frame is precisely the one nobody can prove.
    private func orphan(_ live: Drag) {
        drag = nil
        stopWatchdog()
        previews.dismiss()
        dim.fadeOut()
        panel.setDragging(false)
        // Taken down rather than merely narrowed. Everything that would put the knob back on screen
        // runs off a mouse-moved event or the handle bar's poll, and the orphan path is by definition
        // the one where neither is arriving — a knob left up over an arrangement nobody is holding
        // is the state this path exists to prevent. `announceDragEnded` re-offers it on the next
        // turn if the crossing is still there and the pointer is still on it.
        hidePanel()
        Logger.junction.error("junction drag orphaned: button up for two polls with no events; nothing written")
        announceDragEnded()
    }

    /// Tells the handle bar the gesture is over — **on the next turn of the run loop, never inline.**
    ///
    /// The callback repolls `WindowList` and can put a pill or a knob straight back on screen, and one
    /// of the callers is `cancel()`, which runs inside `screens.onChange` between two other teardown
    /// steps. Called inline from there it would re-show the knob against an arrangement the next
    /// line is about to invalidate, leaving correctness resting on an ordering a future edit would
    /// break silently. Deferring costs nothing: the callback is a convenience over the 100 ms poll,
    /// not a correctness step.
    private func announceDragEnded() {
        guard onDragEnded != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onDragEnded?() }
        }
    }

    // MARK: - The button watchdog

    /// The button watchdog, alive only while a drag is live.
    ///
    /// The pill's watchdog rides `HandleBarController`'s 100 ms poll; this one cannot, because that
    /// poll stands down for the whole of a knob drag — `isSuspended` includes `junctions.isBusy` and
    /// its tick returns at the suspension guard, before the button is ever looked at. So this feature
    /// owns a timer for exactly as long as it owns a gesture, at the same 10 Hz, and one
    /// `CGEventSource` call per tick.
    private func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: HandleBarController.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkButton() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// A mouse-up lost to a Space change, a Mission Control gesture or a tap the window server
    /// disabled leaves the gesture latched — the handle bar stays suspended and the next click moves
    /// three or four windows to wherever it landed. The window server's own button state is the
    /// authority on the button, and it costs one call per tick.
    ///
    /// **But the button being up is not evidence of a lost mouse-up**, and reading it as though it were
    /// would orphan ordinary releases: the bit flips at the physical release, milliseconds before
    /// the session tap delivers `.up`, and a due `Timer` runs before a mach-port source in the same
    /// run-loop pass. `OrphanDetector` is the rule that tells the two apart — two consecutive polls
    /// reading up *and* a mouse stream that has been silent for one. The state it needs is kept per
    /// drag, because it is a fact about this gesture and not about this class.
    private func checkButton() {
        guard var live = drag, live.isLive else { stopWatchdog(); return }
        let up = !HandleBarController.leftButtonIsDown()
        live.ticksButtonUp = up ? live.ticksButtonUp + 1 : 0
        drag = live
        guard OrphanDetector.shouldCancel(buttonUp: up, ticksUp: live.ticksButtonUp,
                                          lastEventAt: live.lastEventAt, now: CACurrentMediaTime(),
                                          quietFor: HandleBarController.pollInterval) else { return }
        orphan(live)
    }

    /// The shape, for a log line. A member count of its own says nothing — three windows are a T when
    /// one of them spans a divider and an L when none does — so the two are always printed together.
    private static func kind(of junction: Junction) -> String {
        junction.spanningMember == nil ? "junction" : "T"
    }
}
