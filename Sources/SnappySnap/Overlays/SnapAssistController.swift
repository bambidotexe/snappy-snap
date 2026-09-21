import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// The eligible-window rule, and the card model built from what passes it: on the given display by
/// center point, regular app, layer 0, resizable, not minimized, not ours, not excluded.
///
/// A unit of its own rather than private to Snap Assist: the snap-bar pair cell asks the same
/// question about a window the user is *not* dragging, and there must be one answer to it.
@MainActor
struct EligibleWindows {
    /// One offerable window, also reachable as `SnapAssistController.Candidate`.
    struct Candidate: Identifiable {
        let id: CGWindowID
        let handle: WindowHandle
        let title: String
        let appName: String
        let icon: NSImage?
    }

    private let ax: AccessibilityWindows

    init(ax: AccessibilityWindows) {
        self.ax = ax
    }

    /// How many windows deep the pair-partner scan goes before giving up. It runs on the
    /// drag-confirmation turn, with a button down, on the run loop that serves the event tap, so it
    /// needs a ceiling that does not depend on how many windows the user happens to have open.
    ///
    /// Eight because the partner is "the most recently focused *other* window": a window that is not in
    /// the front eight of its display has not been touched recently enough for that phrase to mean
    /// anything to the person dragging. Giving up yields the state they already know — no partner, no
    /// cell — so the cost of the cap being wrong is one missing convenience, never a wrong window.
    static let partnerScanLimit = 8

    /// The **most recently focused** eligible window on `display`: front to back, stopping at the first
    /// one that passes. The pair partner, which is exactly one window.
    ///
    /// Bounded rather than a `first` on `candidates(from:handles:excluding:)`, and bounded twice over, because
    /// this is the one part of the pair cell that runs while a button is down:
    ///
    /// - **Handles are memoised per pid.** `ax.handle(forWindowID:pid:)` is
    ///   `windows(ofPid:).first { … }` — a whole `kAXWindows` copy plus, per window of that app, one
    ///   `_AXUIElementGetWindow` on the private route or **two** reads (position and size) plus one
    ///   `CGWindowListCopyWindowInfo` copy on the public one — *every time it is called*. Calling it
    ///   per examined window re-enumerates the same app once for each of its windows: measured at
    ///   **117 round trips** on a 17-window, 7-app desktop when nothing passed, on the private route,
    ///   and the public route roughly doubles the per-window half of it. Reusing `handles(for:)` —
    ///   Snap Assist's own per-pid enumeration, not a second copy of it — makes that one enumeration
    ///   per app instead, on either route.
    /// - **The scan stops after `partnerScanLimit` windows** it had to ask Accessibility about. Windows
    ///   skipped by `excluded` cost nothing and are not counted.
    ///
    /// The common case is unchanged and already cheap: the frontmost window that is not the one being
    /// dragged nearly always passes, so the scan stops at the first window it looks at — **6 round
    /// trips**, measured on that same desktop, on the private route.
    ///
    /// What it is *not* is a second copy of the rule: `candidate(for:handle:)` below is the single
    /// copy, and both callers go through it.
    func frontmostCandidate(on display: DisplayInfo, excluding excluded: Set<CGWindowID> = []) -> Candidate? {
        var handlesByPID: [pid_t: [CGWindowID: WindowHandle]] = [:]
        var examined = 0
        for info in WindowList.snapshot() where display.frame.contains(info.frame.center) {
            guard !excluded.contains(info.id) else { continue }
            guard examined < Self.partnerScanLimit else {
                Logger.assist.debug("pair partner scan gave up after \(Self.partnerScanLimit) windows")
                break
            }
            examined += 1
            // `??` is lazy, so an app is enumerated the first time one of its windows is examined and
            // never again; the result is cached even when it does not contain this window, so an app
            // Accessibility cannot reach is not re-asked either.
            let handles = handlesByPID[info.pid] ?? handles(for: [info])
            handlesByPID[info.pid] = handles
            guard let handle = handles[info.id] else {
                // Not "ineligible": Accessibility could not reach the window at all.
                Logger.assist.debug("no Accessibility handle for window \(info.id); not pairing with it")
                continue
            }
            if let candidate = candidate(for: info, handle: handle) { return candidate }
        }
        return nil
    }

    /// The Accessibility windows of `infos`, by window id — one enumeration per app, not per window:
    /// `handle(forWindowID:pid:)` walks an app's whole window list, and an app with five windows on
    /// screen would walk it five times for the same answer. This is the feature's only AX sweep.
    ///
    /// One walk costs `kAXWindows` plus, per window, one round trip on the private route or two plus
    /// a window-list copy on the public one. Saving four of five walks matters on either.
    func handles(for infos: [WindowInfo]) -> [CGWindowID: WindowHandle] {
        var handles: [CGWindowID: WindowHandle] = [:]
        for pid in Set(infos.map(\.pid)) {
            for handle in ax.windows(ofPid: pid) {
                if let id = handle.windowID { handles[id] = handle }
            }
        }
        return handles
    }

    /// The rule applied to a snapshot and its handles, keeping `infos`' front-to-back order.
    func candidates(from infos: [WindowInfo], handles: [CGWindowID: WindowHandle],
                    excluding excluded: Set<CGWindowID>) -> [Candidate] {
        infos.compactMap { info in
            guard !excluded.contains(info.id) else { return nil }
            guard let handle = handles[info.id] else {
                // Not "ineligible": Accessibility could not reach the window at all.
                Logger.assist.debug("no Accessibility handle for window \(info.id); not offering it")
                return nil
            }
            return candidate(for: info, handle: handle)
        }
    }

    /// **The single copy of the rule**, applied to one window whose handle is already in hand: resizable
    /// and not minimized (the display, layer, regular-app and not-ours parts are `WindowList`'s). Both
    /// callers above go through it — the sweep Snap Assist needs and the one-window question the pair
    /// cell asks — because two versions of "is this window offerable" would drift.
    private func candidate(for info: WindowInfo, handle: WindowHandle) -> Candidate? {
        guard ax.isResizable(handle), !ax.isMinimized(handle) else { return nil }
        let app = NSRunningApplication(processIdentifier: info.pid)
        let appName = app?.localizedName ?? ""
        let title = ax.title(of: handle).flatMap { $0.isEmpty ? nil : $0 } ?? appName
        return Candidate(id: info.id, handle: handle, title: title, appName: appName, icon: app?.icon)
    }
}

/// After a drop made **from the snap bar** — and after nothing else — offer every other cell of that
/// layout at once, so the user arranges the whole thing instead of being walked through it. Each area
/// is a zone preview drawn on its own cell with the cards inside, over a desktop cleared
/// by *dealing* every other window into a deck in the bottom-right corner with `AXPosition`, where
/// minimizing would cost a genie animation each. Everything dealt is put back when the phase ends, by
/// any route, which is why every exit goes through `dismiss(_:)`, and the dealt windows' home frames
/// are on disk the whole time in case the app never gets there.
///
/// **The deck is `DeckAnimator`'s; the promise is this class's.** Which windows are recorded, in what
/// order relative to the first write, and what is on disk at every instant stay here and nowhere else.
/// The animator is handed cards and moves windows; it never touches `parked` or `parkedStore`.
///
/// There is no queue and no order. An area that has been filled stops offering cards and its surface
/// goes away, uncovering the window that just landed in it; the phase ends when the last one does.
///
/// The expensive parts run after the drop, never during a drag: `begin` is called from the engine's
/// completion, once the dragged window has landed and the drag session is back to idle, so the
/// Accessibility sweep in `EligibleWindows` and the parking are nowhere near the path that serves the
/// event tap while a button is down.
///
/// The restore is the exception worth stating plainly: the commonest way out of a phase is a click
/// outside the surface, and `handleGlobalMouseDown` runs *inside* the tap's callback, so the way home
/// runs there too. Which way home it is depends on the reason (`EndReason.dealsBack`), and both are
/// bounded:
///
/// - **Dealt back**, for a deliberate end. `dealBack` makes no Accessibility call at all on the tap's
///   callback, and none on any turn of the main thread: it starts a display link that posts each
///   card's position to `WindowWriter`, which writes them on one queue per application.
/// - **Straight home**, for the interruptions. `restorePass` writes on the callback, but bounded:
///   the deadline is checked before each remaining window, so the callback costs at most
///   `restoreDeadline + messagingTimeout` = 0.40 s against the 1.0 s stall that disables the tap, and
///   what it does not reach is paid one window per turn of the run loop.
///
/// Deferring the tail of a restore does **not** put the promise behind an async hop, and that is the
/// whole reason it is allowed to be deferred: a window leaves `parked` only when it is home, the file
/// is rewritten every pass, and `restoreParkedFromPreviousRun` is the retry. So even
/// `applicationWillTerminate`, which has no next turn to defer into, is covered — what it cannot write
/// in one deadline is on disk, and the next launch writes it.
@MainActor
final class SnapAssistController {
    typealias Candidate = EligibleWindows.Candidate

    /// Why a phase ended. Logged: the dismissal routes are otherwise the only invisible transitions
    /// here, and "did the desktop come back, and why" is the question this feature has to answer.
    enum EndReason: String {
        case picked, cancelled, escape, clickOutside, displayChange, quit, superseded, noWindows
        /// The windows placed so far have left no cell that still fits on the display.
        case noRoom
        /// Kept apart from each other and from `.displayChange` on purpose: they are the only routes
        /// out that leave no trace on screen, so the log line is the whole of the diagnosis later.
        /// Which one it was is also the difference between "the user chose to be somewhere else" and
        /// "the system covered the screen", and those are answered differently.
        case spaceChange, missionControl

        init(_ interruption: SpaceInterruption) {
            switch interruption {
            case .spaceChange: self = .spaceChange
            case .missionControl: self = .missionControl
            }
        }

        /// Whether the cards are **dealt back** or sent straight home without animation.
        ///
        /// A drag or a display change during either animation cancels it and sends every card
        /// straight home: correctness outranks the effect. Quitting and being superseded join them
        /// for the same reason and a stronger one — neither has a next frame to animate in.
        ///
        /// Everything else is a deliberate end, and a deliberate end that lands *during* the deal-out
        /// reverses it rather than teleporting: `dealBack` starts each card from wherever it actually
        /// is, so an Escape half way through the deal simply turns the cards round.
        var dealsBack: Bool {
            switch self {
            case .picked, .noWindows, .noRoom, .cancelled, .escape, .clickOutside: true
            // A Space change and Mission Control are in the second list, and not marginally: the
            // cards would be dealt back onto a Space the user is not looking at, or underneath
            // Mission Control's own backdrop, on a display link the window server has every right to
            // stop feeding. Correctness outranks the effect, and here there is no effect to lose.
            case .displayChange, .quit, .superseded, .spaceChange, .missionControl: false
            }
        }
    }

    /// How long after a pick the surfaces ask for key a second time — long enough for the app
    /// activation `ax.raise` starts to have landed, short enough that Escape is never really gone.
    private static let keyReassertDelay: TimeInterval = 0.12

    /// How long `restorePass` may spend writing before it defers the rest to the next turn of the run
    /// loop. One window is one `setPosition` and the deadline is checked before each remaining one, so
    /// a callback is bounded by this plus `AccessibilityWindows.messagingTimeout` = **0.40 s**,
    /// against the measured 1.00–1.05 s single stall that has the window server disable the tap.
    ///
    /// **The last main-thread write pass in the app.** Every other animated write goes through
    /// `WindowWriter`; `restorePass` is the straight-home path and deliberately does *not*: it runs on
    /// the quit path and on the launch path, where there is no animation to pace and what matters is
    /// that the window is home before the process is, and its own deferral — one window a turn, with
    /// the file rewritten each pass — is what makes a kill part way through safe.
    private static let restoreDeadline: CFTimeInterval = 0.15

    /// A window moved out of the way, with the handle needed to move it back. `entry` is the part that
    /// survives the process.
    private struct Parked {
        let entry: ParkedWindowsStore.Entry
        let handle: WindowHandle
        /// Where the window was **observed** to be when it was recorded, which is usually its recorded
        /// home and is not the same thing.
        ///
        /// They differ for a window an earlier phase could not bring back: `park` carries its true
        /// home forward from `stranded` while the window itself is still standing in the deck corner.
        /// Both facts are needed and neither substitutes for the other — the recorded one is where the
        /// window belongs, this one is where it is. Giving the deck the recorded frame as a starting
        /// point would animate such a card from a place it is not standing at, and, far worse, would
        /// make `Deck.mayForgetRecord` see a window "still at its recorded home" when it is nothing of
        /// the kind, so one refused write would delete the only record of where it belonged.
        let observedOrigin: CGPoint

        /// The deck card for this window. **The one place `from` and `home` are paired**, so the two
        /// cannot be crossed at a call site: `home` is always the recorded frame and `from` is always
        /// a reading of where the window is — the caller has to supply that reading and cannot reach
        /// the record through this method at all.
        @MainActor
        func card(depth: Int, observedAt from: CGPoint, to: CGPoint) -> DeckAnimator.Card {
            DeckAnimator.Card(id: entry.windowID, handle: handle, depth: depth,
                              from: from, to: to, home: entry.frame.origin)
        }
    }

    /// One cell on offer: the zone it covers and the card list drawn on it. The model is what makes
    /// the removal animation possible — it outlives every pick, so SwiftUI keeps the cards'
    /// identities and animates the list instead of rebuilding it. It is also what says whether this
    /// area is on screen, since there is no panel of its own to ask: every area of the display is
    /// drawn inside the one `panel`, and `model.visible` is the flag the fade is played from.
    private struct Area {
        /// The cell, carrying the frame the arrangement gives it **now**: a cell is its index in the
        /// layout, and its frame follows the dividers when a window placed elsewhere moves them.
        var zone: Zone
        let model: SnapAssistAreaModel
        /// The reflow this area's cards are in the middle of, if any. Nil once they have arrived.
        var motion: CardMotion?
    }

    /// What an area's cards are **doing**, so that a click can be answered against what is on screen
    /// rather than against where the cards will be in `SnapAssistCardReflow.duration`.
    ///
    /// Assigning a shorter list into an area's model is instantaneous; the drawing is not. Without
    /// this, for the 0.22 s of every reflow the hit grid would be the settled arrangement while the
    /// cards are still on their way to it — measured on this app's own geometry, a click on the
    /// visible centre of a card picks its neighbour, and a few points to the left cancels the whole
    /// arrangement. Both of those are clicks on a card the user can plainly see.
    private struct CardMotion {
        /// Where each surviving card was **drawn** when the list changed, by window id. Drawn, not
        /// settled: a pick that interrupts another reflow has to start from where the cards actually
        /// are, which is what SwiftUI retargets its animation from.
        let from: [CGWindowID: CGRect]
        /// Everything that moves while the reflow runs — the two blocks *and* the frames above, which
        /// on an interrupting pick lie outside both. `SnapAssistCardReflow.movingRegion` says why.
        let region: CGRect
        /// Whether the **cell itself** is moving, and not only the cards within it. The cards of a cell
        /// that is resizing are carried by two animations at once — the area's and their own inside it
        /// — and the frame a card is drawn at is then no longer the one line this file can evaluate:
        /// the two differ by up to an eighth of the change in the cell's size, which for a cell that
        /// gives up 250 pt is wider than a card's pickable band. So for the length of that motion the
        /// whole region answers nothing, which is the rule everywhere else in this file: ignored,
        /// never a guess.
        let cellMoved: Bool
        /// When the cards started moving: the end of `pick`, which is also when `from` is read. Nothing
        /// can be drawn until this run-loop turn returns, so the turn's end is the better estimate of
        /// when the animation begins than the moment the lists changed — and taking both readings there
        /// means there is one instant on record for one event. See the note at the bottom of `pick`.
        let startedAt: CFTimeInterval
    }

    private let ax: AccessibilityWindows
    private let screens: any ScreensProviding
    private let eligible: EligibleWindows
    private let settingsStore: SettingsStore
    private let engines: EngineRouter
    /// Places the picked window and whatever the pick moves, and corrects from what lands.
    private let coordinator: ArrangementCoordinator
    private let parkedStore: ParkedWindowsStore
    /// The deck's writer, kept here as well as handed to the animator: the opportunistic probe posts
    /// through it directly, on the same per-pid queue, so a probe can never overlap a card's own
    /// writes.
    private let writer: WindowWriter
    /// The deck is the cheapest moment in the app to spend a probe's blink, so this class is the one
    /// that spends it.
    private let minimums: MinimumSizeStore

    /// Whether a choosing phase is running. Not derived from the areas: the phase outlives the last
    /// one by one snap, and the desktop it cleared has to be restored whatever is left on screen.
    private var inPhase = false
    /// The areas still offering cards, in layout order. A pick removes the one it filled.
    private var areas: [Area] = []
    /// The windows on offer, front to back, chosen once when the phase starts — after the desktop is
    /// cleared they are all sitting in the parking corner, so the rule could not be re-applied later.
    /// Every area shows this same list, so a pick removes the card from all of them at once.
    private var offered: [Candidate] = []
    private var display: DisplayInfo?
    /// **The phase's one arrangement**: the layout the drop chose, and every window placed in it so
    /// far with what is known of its limits. Every frame of the phase — where a pick goes, where the
    /// open areas are, whether a placed window has to give room — is this, solved. It holds no window
    /// that was on screen before: they are all in the deck.
    private var arrangement: LayoutArrangement?
    /// The windows placed so far, by cell, as the coordinator needs them to re-fit one: the handle,
    /// the cell, and where the window was last known to land.
    private var placed: [Int: Placed] = [:]

    /// Numbers the placements of a phase, so that only the newest may move the open areas.
    private var placement = 0
    /// How many placements have windows in the air. The phase is not ended, and not reconciled, until
    /// it is zero.
    private var placementsInFlight = 0
    /// A placement ended that was not the newest while it ran: see `place`.
    private var needsReconciling = false
    /// What a placement found the phase should end for while another still had a window in the air.
    /// Spent by whichever placement is the last to settle.
    private var pendingEnd: EndReason?

    private struct Placed {
        let windowID: CGWindowID
        let handle: WindowHandle
        let zone: Zone
        var current: CGRect
    }
    /// **One** panel for the whole display, kept for the life of the app: it covers the display's
    /// visible frame and hosts every area of a phase at its own place inside it. One panel because
    /// macOS renders true Liquid Glass only in the key window — see `SnapAssistPanel`. Kept rather
    /// than built per phase because a dismissed panel is still fading out for 150 ms after the phase
    /// that owned it has let go of it, and releasing an `NSPanel` mid-fade takes the fade off the
    /// screen with it.
    private let panel = SnapAssistPanel()
    /// What that panel draws: the panel's own origin, and the area models. The areas outlive `areas`
    /// by their fade — a filled area leaves `areas` at once and this list 150 ms later.
    private let surfaces = SnapAssistSurfacesModel()
    /// Windows this app dealt into the deck. Only these are ever put back, and a window it failed to
    /// move never makes it in — so nothing the app did not move is moved. A window leaves this list
    /// exactly when it is home again, never before, which is what makes the list a promise rather than
    /// a log: while an entry is in it, that window is somewhere it did not choose to be.
    private var parked: [Parked] = []
    /// Windows that refused to go home. They stay on disk for the next launch to retry, and they keep
    /// the frame recorded **before** the app first moved them — so if one of them is dealt again in a
    /// later phase, `park` records that frame and not the corner it is currently sitting in.
    private var stranded: [ParkedWindowsStore.Entry] = []
    /// The deck. The animation only; the record-before-move rule is this class's.
    private let deck: DeckAnimator
    /// The window picked last, raised again after the restore so it ends frontmost.
    private var lastPicked: WindowHandle?
    /// Voids the snap completion of a phase that a dismissal or a newer drop has superseded — the same
    /// discipline the panels apply to a fade they no longer own.
    private var session = 0
    /// Cards still waiting for the opportunistic minimum probe, in deck order. Emptied by the
    /// chain itself and by any end of the phase.
    private var probeQueue: [Parked] = []
    /// **The net.** A window whose size a probe has changed and has not yet put back, with the size it
    /// must go back to. `MinimumProbe.probeInBackground` posts its own restore, but a pick or a
    /// dismissal can `cancel` that window in the writer before the restore runs, and the one thing a
    /// probe may never do is leave a window at 1 × 1. While an id is in here, that window is a size
    /// nobody asked for — exactly the promise `parked` makes about position.
    private var probeRestores: [CGWindowID: (handle: WindowHandle, size: CGSize)] = [:]

    /// How many of a deck's windows one phase will probe. The blink is cheap here and it is not free:
    /// four windows is two or three seconds of chain in the worst case, which is about as long as a
    /// deck is reliably left standing, and the rest are caught by the next phase or by their first
    /// drag.
    private static let deckProbeBudget = 4

    /// `screens` is here because parking needs the union of *every* display's frame, not just the one
    /// the phase runs on. `writer` is the deck's only way to move a window.
    init(ax: AccessibilityWindows, screens: any ScreensProviding, settingsStore: SettingsStore,
         writer: WindowWriter, engines: EngineRouter, coordinator: ArrangementCoordinator,
         minimums: MinimumSizeStore, parkedStore: ParkedWindowsStore = ParkedWindowsStore()) {
        self.ax = ax
        self.screens = screens
        self.eligible = EligibleWindows(ax: ax)
        self.settingsStore = settingsStore
        self.engines = engines
        self.coordinator = coordinator
        self.parkedStore = parkedStore
        self.writer = writer
        self.minimums = minimums
        self.deck = DeckAnimator(writer: writer)
        deck.onCardLost = { [weak self] id in
            guard let self else { return }
            // A window the app fails to move is not recorded and is left alone. The record is written
            // before the first write, so a crash in the gap can only ever name a window that had not
            // moved — a no-op to restore. Here the write has come back refused, and the record goes
            // with it.
            self.parked.removeAll { $0.entry.windowID == id }
            self.persistParked()
            Logger.assist.debug("could not deal window \(id) at all; it stays where it is, unrecorded")
        }
    }

    /// True while a phase is running **or** while the deck still has windows away from home. The
    /// handle bar and the junction knob stand down for both: a pill over two windows that are on their
    /// way back across the screen is a handle between two windows nobody is looking at.
    var isActive: Bool { inPhase || deck.isRunning || !parked.isEmpty }

    /// Windows that refused to go home and sit in the deck corner until the next launch tries again. The
    /// Health page reports them.
    var strandedCount: Int { stranded.count }

    /// Whether the record an earlier run left could not be read at launch, so the windows it parked could
    /// not be named, let alone put back. The Health page reports it.
    var parkedRecordWasUnreadable: Bool { parkedStore.lastLoadWasUnreadable }

    /// `WindowWriter.onOutcome`'s share for this feature, routed here by `AppDelegate` because one
    /// property on a shared writer needs one fan-out and this is its first consumer. The deck reads
    /// its own deal's outcomes off it and nothing else does; no decision is taken here.
    func writeOutcome(_ outcome: WindowWriter.Outcome) {
        deck.record(outcome)
    }

    /// A kill or a crash mid-phase — or mid-*animation*, which the deck makes a longer
    /// window to be killed in — leaves windows in a corner with nothing to click. Their frames outlive
    /// the process, so this is the first thing the app does with Accessibility.
    ///
    /// Routed through the same bounded restore as every other way home, rather than its own loop: it
    /// runs after `mouse.start()`, so the tap is already live and a burst of writes against a
    /// still-launching application is the same stall here as anywhere else.
    func restoreParkedFromPreviousRun() {
        let entries = parkedStore.load()
        guard !entries.isEmpty else { return }
        var found = 0
        for entry in entries {
            guard let handle = ax.handle(forWindowID: entry.windowID, pid: entry.pid) else {
                Logger.assist.debug("window \(entry.windowID) dealt by an earlier run is gone")
                continue
            }
            // The recorded frame for want of a reading: taking one would be an Accessibility round
            // trip per window at launch for a value nothing reads. **What makes that safe** is not
            // this path — it is `begin`'s `guard parked.isEmpty`, which declines a phase while any
            // record is still outstanding, so a record seeded here can never reach `dealOut` or
            // `dealBack`, the only two readers of `observedOrigin`. `restorePass`, which is all this
            // path runs, writes straight home and never looks at it. If that guard ever goes, this
            // seed has to go with it, or a window would be dealt from a frame nobody observed.
            parked.append(Parked(entry: entry, handle: handle, observedOrigin: entry.frame.origin))
            found += 1
        }
        // A window that could not be found now will not be findable later, and a stale entry would move
        // some future window that happens to reuse the id — so what is written back is what was found.
        persistParked()
        Logger.assist.info("putting \(found) window(s) back from an earlier run")
        restorePass()
    }

    /// The parked list, on disk: what is still away from home **and** what refused to go back. Both
    /// have to survive the process, and both have to survive the next phase writing the file — which
    /// is why every save in this class goes through here and none of them writes `parked` alone.
    private func persistParked() {
        parkedStore.save(parked.map(\.entry) + stranded)
    }

    /// Puts parked windows home, unanimated, **bounded**, and carries on next turn if it runs out.
    ///
    /// This is the promise's last mile, so it is written to the same rule as every other write pass in
    /// this app rather than to a convenience. One window is one `setPosition`, the deadline is checked
    /// before each remaining one, so a callback is bounded by `restoreDeadline + messagingTimeout` =
    /// 0.40 s — under the measured 1.00–1.05 s single stall that disables the event tap and destroys
    /// mouse events. A straight-home burst is the most dangerous moment in this feature (N × 0.25 s
    /// against hung applications, past the threshold at four windows), so it is capped here.
    ///
    /// **A window leaves `parked` only when it is actually home**, and the file is rewritten each pass,
    /// so a kill part way through leaves every window that is still away named on disk and the next
    /// launch finishes the job. That is also what makes the deadline safe on the quit path, where there
    /// is no next turn of the run loop to carry on into: what this does not manage, the next launch
    /// does, and the alternative — an unbounded burst inside `applicationWillTerminate` — risks the
    /// watchdog killing us before the file is written at all.
    private func restorePass() {
        guard !parked.isEmpty else { return }
        let started = CACurrentMediaTime()
        var attempted = 0
        while let window = parked.first {
            if attempted > 0, CACurrentMediaTime() - started >= Self.restoreDeadline { break }
            attempted += 1
            parked.removeFirst()
            if !ax.setPosition(window.entry.frame.origin, of: window.handle) {
                Logger.assist.error("could not put window \(window.entry.windowID) back; it stays where it is")
                stranded.append(window.entry)
            }
        }
        persistParked()
        guard !parked.isEmpty else { return }
        // One window per turn of the run loop, read out of `self` so anything that clears `parked`
        // revokes what is left. Never a block: three windows in one callback is 0.75 s against hung
        // applications, and four is the measured stall that disables the tap.
        Logger.assist.debug("restore ran out of deadline; \(self.parked.count) window(s) left, one a turn")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.restorePass() }
        }
    }

    /// Starts a choosing phase for every cell of `zone`'s layout but `zone`'s own, presented at once.
    /// `origin` is the trigger: only a drop made from the snap bar starts a phase. `placedWindowID`
    /// is the window that was just snapped — the one window left in place while the others are parked,
    /// and the one window not offered as a card.
    ///
    /// The placed window is never offered: the drop's own cell is not among the areas, so a window
    /// that leaves it cannot be put back. Picking it elsewhere would end the arrangement with a hole
    /// the user cannot fill without starting the whole thing over — and dropping it there was their
    /// choice for that cell in the first place.
    func begin(after zone: Zone, placed handle: WindowHandle, display: DisplayInfo, origin: ZoneOrigin,
               limits: SizeLimits) {
        let placedWindowID = handle.windowID
        // Any new snap supersedes a live phase, whatever it came from, and this runs before the origin
        // guard for a reason: `begin` is called from the engine's completion, so a drag started in the
        // gap between the drop and that completion opens its phase underneath itself, and an edge drop
        // that returned at the guard would leave those surfaces up and those windows parked until
        // something else happened to click. On the common path — no phase running — `dismiss` is a
        // `guard inPhase` and nothing more, so an edge snap still costs no Accessibility call.
        dismiss(.superseded)
        // `dismiss` above has already cancelled any deck and started the windows home, whether or not
        // there was a phase behind it. What is left is the guard: nothing may be in the air when the
        // snapshot below is taken, because a window in flight would be read at its deck position and
        // recorded as if that were its home — the one way this feature can *create* the loss it exists
        // to prevent. An arrangement over windows in the air is worth less than a window that ends up
        // where it started, so the phase is declined rather than opened on a bad reading.
        guard parked.isEmpty else {
            Logger.assist.error("\(self.parked.count) window(s) from the last phase are not home yet; no choosing phase")
            return
        }
        // The trigger: the snap bar and nothing else. An edge, corner or top snap places the window
        // and stops here, before the window snapshot and before the Accessibility sweep.
        //
        // `.pairCell` stops here too: a pair drop has already filled both
        // halves, so the only cell a phase could offer is the one the partner has just landed in — and
        // clearing the desktop for it would park the very window this gesture placed.
        guard origin == .snapBar else { return }
        guard settingsStore.settings.snapAssist, zone.layout.cells.count > 1 else { return }
        // A window the window list could not be matched to cannot be told from the windows on offer:
        // it would be offered as a card and dealt into the deck with them. It keeps its snap and
        // starts no phase.
        guard let placedWindowID else {
            Logger.assist.info("the dropped window has no window id; no choosing phase")
            return
        }
        // The phase's arrangement: the chosen layout with the dropped window in its cell, and with
        // what that window's own landing revealed of its limits. Nothing else is in it — every other
        // window of this display is about to be in the deck — so the cells offered are the layout's
        // own, moved only by what the dropped window would not give or could not take.
        let gap = settingsStore.settings.gap
        var arrangement = LayoutArrangement(layout: zone.layout, area: display.visibleFrame, gap: gap)
        arrangement.members[zone.cellIndex] = LayoutArrangement.Member(windowID: placedWindowID, limits: limits)
        let solved = arrangement.solve()
        for index in solved.withdrawn {
            Logger.assist.info("cell \(index) of \(zone.layout.id, privacy: .public) no longer fits on the display; not offered")
        }
        let cells = SnapAssist.otherZones(besides: zone, display: display, gap: gap).compactMap { cell -> Zone? in
            guard let frame = solved.open[cell.cellIndex] else { return nil }
            var offered = cell
            offered.frame = frame
            return offered
        }
        // A dropped window that needs nearly the whole display leaves no cell to offer. A phase with no
        // surface on screen is one the user has nothing to click, and only a click ends a phase.
        guard !cells.isEmpty else {
            Logger.assist.info("no cell of \(zone.layout.id, privacy: .public) is left on the display; no choosing phase")
            return
        }
        let windows = WindowList.snapshot().filter { display.frame.contains($0.frame.center) }
        let handles = eligible.handles(for: windows)
        let offered = eligible.candidates(from: windows, handles: handles,
                                          excluding: [placedWindowID])
        // On a display where the dropped window was the only eligible one there is nothing to
        // arrange. Nothing has been touched at this point — no parking, no surfaces, `inPhase` still
        // false — so returning here leaves the snap and nothing else, which is exactly what an empty
        // offer should do.
        guard !offered.isEmpty else {
            Logger.assist.debug("no eligible window to offer; no choosing phase")
            return
        }
        inPhase = true
        self.offered = offered
        self.display = display
        self.arrangement = arrangement
        placed = [zone.cellIndex: Placed(windowID: placedWindowID, handle: handle, zone: zone, current: zone.frame)]
        let cellCount = cells.count
        let windowCount = offered.count
        Logger.assist.debug("choosing phase: \(cellCount) area(s) of \(zone.layout.id, privacy: .public), \(windowCount) window(s) offered")
        park(windows, handles: handles, except: placedWindowID)
        // The surfaces go up first and the cards slide out behind them: `present` touches no
        // Accessibility at all, and putting it ahead of the deal means the first thing the user sees
        // after the drop is the arrangement they are being asked about.
        present(cells)
        dealOut(on: display)
    }

    /// **The one place that decides what a click means while a phase is running.** The
    /// answers, in this order:
    ///
    /// - **On a card of an area still offering** — that window is placed in that area's cell. "On a
    ///   card" means on the card *as drawn at that instant*, which for the 0.22 s after a pick is not
    ///   where that card will come to rest: see `hit(_:in:)`.
    /// - **Anywhere else on such an area** — the phase is cancelled, with one exception below.
    /// - **Among the cards of an area whose cards are still moving, but on none of them** — nothing
    ///   happens, and the phase carries on. This is the exception, and it is deliberate. Three things
    ///   land there: the gaps, which are moving too, so a click into one is not the confident "I meant
    ///   the backdrop" a cancel has to be; the card the user has just picked, fading out on its way to
    ///   its cell, where a second click is the likeliest click of all and cancelling on it would tear
    ///   down the arrangement they are half way through building; and the band near a moving card's
    ///   edge where the display's latency leaves it genuinely unclear which card was under the cursor,
    ///   which is worth nothing rather than a guess at someone else's window. Everything outside the
    ///   block of cards still cancels throughout, and the exception expires with the reflow.
    /// - **On a surface on its way out** — a filled area, fading or waiting for the phase to end —
    ///   nothing at all happens, and the phase carries on.
    /// - **Anywhere else** — the click outside that ends the phase, which also covers "a new window
    ///   drag", since that starts with a mouse-down somewhere else.
    ///
    /// It returns `true` for all of them, and `false` only when no phase is running: while one is, every
    /// mouse-down belongs to it and none is passed on. That matters. Ending a phase puts every parked
    /// window back, so by the time this returns there may be a window sitting under the cursor that
    /// was nowhere near it when the button went down; handing the click to the drag session would arm
    /// a drag on whichever window the restore had just moved there, and a few pixels of drift would
    /// move it. The same goes for a pick and for a click on a retiring surface: what is under either
    /// is a window this arrangement has just placed.
    ///
    /// It also means the Accessibility that a pick needs — the raise, and the frame read for the
    /// animation — runs inside the tap's callback, like `dismiss`'s `restorePass` already does. That is
    /// allowed for the same reason: it is a one-off at the end of a gesture, not something on the
    /// path that serves a drag, and every call carries the 0.25 s messaging timeout.
    ///
    /// A SwiftUI tap gesture on a surface's backdrop cannot stand in for this: the app is an accessory
    /// that never activates, and in a non-activating panel of an inactive app AppKit gives the click
    /// only to views that take first mouse. Buttons do; a gesture does not. Measured — see
    /// `SnapAssistView`.
    @discardableResult
    func handleGlobalMouseDown(at point: CGPoint) -> Bool {
        guard inPhase else { return false }
        // The zone, not the panel's frame: the zone is the geometry the cards were measured against,
        // and it does not move while a surface is still animating in.
        if let area = areas.first(where: { $0.model.visible && self.covers($0, point) }) {
            switch hit(point, in: area) {
            case .card(let candidate):
                pick(candidate, for: area.zone)
            case .movingCards:
                Logger.assist.debug("click among cards that are still moving; ignored")
            case .backdrop:
                Logger.assist.debug("click on an area but not on a card")
                dismiss(.cancelled)
            }
            return true
        }
        // A surface still on screen but no longer offering: a filled area fades for 150 ms after it
        // leaves `areas`, and the last one stays up until the phase ends. Clicking something the user
        // can still plainly see must not tear the arrangement down.
        //
        // The *areas* still being drawn, never the panel's frame: the panel covers the whole visible
        // frame now, so testing it would swallow every click outside every area and the phase could
        // never be ended by clicking outside.
        if surfaces.areas.contains(where: { $0.visible && $0.zoneFrame.contains(point) }) {
            Logger.assist.debug("click on a surface that is on its way out; ignored")
            return true
        }
        Logger.assist.debug("click at \(Int(point.x)),\(Int(point.y)) outside every surface")
        dismiss(.clickOutside)
        return true
    }

    /// Whether `point` is `area`'s to answer: inside its cell, or — while the area is still travelling
    /// to a new frame — anywhere it has been since it set off. A click aimed at an area that is moving
    /// away must find that area, which ignores it, and not fall through to "outside every surface",
    /// which ends the phase.
    private func covers(_ area: Area, _ point: CGPoint) -> Bool {
        if area.zone.frame.contains(point) { return true }
        guard let motion = area.motion, CACurrentMediaTime() - motion.startedAt < Self.reflowWindow else { return false }
        return motion.region.contains(point)
    }

    func handleGlobalMouseMoved(at point: CGPoint) {
        guard inPhase else { return }
        for area in areas {
            var hovered: CGWindowID?
            if area.model.visible, area.zone.frame.contains(point),
               case .card(let candidate) = hit(point, in: area) {
                hovered = candidate.id
            }
            if area.model.hovered != hovered { area.model.hovered = hovered }
        }
    }

    /// What is under `point` on an area that is still offering cards.
    private enum SurfaceHit {
        /// A card the user can see there. Picks it.
        case card(Candidate)
        /// Inside the block while it is still reflowing, but on no card the user can be shown to have
        /// been pointing at: a moving gap, the card just picked fading out, the band near a moving
        /// card's edge that the display's latency leaves ambiguous, or — where the arrangement wraps —
        /// the path of a card flying to another line, which could be covering any of the cards it
        /// crosses. Ignored, never a guess.
        case movingCards
        /// The surface behind the cards, at rest. Cancels the phase.
        case backdrop
    }

    /// What `point` is pointing at, **as drawn at this instant**.
    ///
    /// Each card is hit-tested against `SnapAssistCardLayout.cardFrame`, which is the same function
    /// `SnapAssistCardGrid` places the cards with, and — while a reflow is running — carried along
    /// that reflow by `SnapAssistCardReflow`, which is the same curve `SnapAssistView` plays it with.
    /// So the frame this tests is the frame on screen at both ends: at rest trivially, and in flight
    /// because the drawing and the reading evaluate one curve rather than two that resemble each
    /// other, narrowed by `SnapAssistCardReflow.card(at:among:)` to close the one gap no shared curve
    /// can — the display's own latency, since what the user aimed at is the last frame it presented
    /// and not the value the animation has reached. A point that latency leaves ambiguous, because two
    /// cards could both be drawn there, is `movingCards`: ignored, never a guess.
    ///
    /// The choice is `SnapCore`'s, not this file's, so it can be unit-tested against every arrangement
    /// including the wrapped ones, where a card changes line and crosses the whole of the line above.
    /// Taking the topmost card where two overlap is the right answer to "which card is on top *now*"
    /// and the wrong answer to the question a click actually asks: which card was on top at an instant
    /// the app cannot observe. Where two of them could be, neither answers.
    private func hit(_ point: CGPoint, in area: Area) -> SurfaceHit {
        let now = CACurrentMediaTime()
        if let motion = area.motion, motion.cellMoved, now - motion.startedAt < Self.reflowWindow,
           motion.region.contains(point) {
            return .movingCards
        }
        let cards = cards(of: area, at: now)
        if let index = SnapAssistCardReflow.card(at: point, among: cards.map(\.target)) {
            return .card(cards[index].candidate)
        }
        if let motion = area.motion, now - motion.startedAt < Self.reflowWindow,
           motion.region.contains(point) {
            return .movingCards
        }
        return .backdrop
    }

    /// How long after a pick the cards count as still moving: the reflow itself, plus the display
    /// latency `lookBack` allows for, because for that much longer what the user is looking at is
    /// still a frame from inside the reflow.
    private static let reflowWindow = SnapAssistCardReflow.duration + SnapAssistCardReflow.lookBack

    /// Every card of `area` in list order, with where it is and what a click on it means. The two are
    /// the same thing once the cards have arrived and differ only while they are moving.
    ///
    /// - `drawn` — where the card is on screen, by the reflow's own curve. This is what the *next*
    ///   reflow has to start from, so it must be the frame itself and not the target's regions.
    /// - `target` — the pair `SnapAssistCardReflow.card(at:among:)` decides from: where a click counts
    ///   as this card, and everywhere it might be drawn so that no other card claims those points.
    private func cards(of area: Area, at now: CFTimeInterval)
        -> [(candidate: Candidate, drawn: CGRect, target: SnapAssistCardTarget)] {
        let cards = area.model.candidates
        let layout = SnapAssistCardLayout(count: cards.count, cell: area.zone.frame.size)
        let elapsed = area.motion.map { now - $0.startedAt }
        return cards.enumerated().map { index, candidate in
            let settled = layout.cardFrame(index, in: area.zone.frame)
            guard let elapsed, elapsed < Self.reflowWindow, let from = area.motion?.from[candidate.id] else {
                return (candidate, settled, SnapAssistCardTarget(settled: settled))
            }
            return (candidate,
                    SnapAssistCardReflow.frame(from: from, to: settled, elapsed: elapsed),
                    SnapAssistCardTarget(from: from, to: settled, elapsed: elapsed))
        }
    }

    /// The block `count` cards occupy in `cell`, centred — one of the two ends of a reflow, which
    /// `SnapAssistCardReflow.movingRegion` takes together with where the cards actually are.
    private func block(of count: Int, in cell: CGRect) -> CGRect {
        let layout = SnapAssistCardLayout(count: count, cell: cell.size)
        return CGRect(origin: layout.blockOrigin(in: cell), size: layout.contentSize)
    }

    /// Ends the phase by any route and puts the desktop back. Safe to call when
    /// no phase is running, and it never depends on the happy path: leaving a user's windows parked
    /// is the worst thing this feature can do.
    func dismiss(_ reason: EndReason) {
        // Three conditions, not one. A deal back outlives the phase that started it, so for the length
        // of one it is true that `inPhase` is false and that windows are still away from home — and an
        // interruption has to reach *that* as much as it has to reach a live phase. On a display
        // change it is worse than a missed animation: the `CADisplayLink` was taken from the screen
        // the phase ran on, so it may simply stop, and `finish()` is only reachable from a tick —
        // nothing would ever clear `parked` and the windows would sit in the corner until the next
        // drop or quit.
        //
        // The cheap path is untouched: an edge snap calls `dismiss(.superseded)` with no phase, no
        // deck and nothing parked, and pays three boolean reads.
        guard inPhase || deck.isRunning || !parked.isEmpty else { return }
        // Before either branch and before the deck is told anything: a window left at 1 × 1 by a probe
        // this dismissal interrupts is the one failure the probe is not allowed to have, and it has to
        // be fixed while this class still knows which window it is.
        restoreProbedSizes()
        guard inPhase else {
            Logger.assist.debug("\(reason.rawValue, privacy: .public) with no phase running; sending the deck straight home")
            deck.cancel()
            restorePass()
            return
        }
        inPhase = false
        session &+= 1
        areas = []
        offered = []
        arrangement = nil
        placed = [:]
        placementsInFlight = 0
        needsReconciling = false
        pendingEnd = nil
        // Read before it is cleared: the deal back runs on the display the phase ran on, and by the
        // time it is started this is nil.
        let phaseDisplay = display
        display = nil
        // The one panel, which every area of the phase was drawn in: it fades out as a whole and the
        // areas go with it. `dismiss` is a no-op on a panel that is already down.
        //
        // On the two interruptions the surfaces leave through the shared 120 ms fade instead of this
        // feature's own 150 ms, because they are leaving beside the pill, the dim and every preview in
        // one event rather than at the end of a phase the user finished. The state half below is
        // untouched by that — `dealsBack` is already false for both (see `EndReason`), so the parked
        // windows go straight home on this turn while the cards fade.
        let interrupted = reason == .spaceChange || reason == .missionControl
        interrupted ? panel.fadeOutForInterruption() : panel.dismiss()
        // The area models are cleared only once that fade has landed. Clearing them now would take
        // every area out of the hosting view on this turn and the surfaces would vanish instead of
        // fading. Guarded by the session, so a phase that started inside the fade keeps its own areas.
        let fadeSession = session
        let fade = interrupted ? OverlayPanel.interruptionFadeDuration : SnapAssistPanel.dismissDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == fadeSession else { return }
                self.surfaces.areas = []
            }
        }
        let chosen = lastPicked
        lastPicked = nil
        Logger.assist.debug("choosing phase ended: \(reason.rawValue, privacy: .public)")
        guard reason.dealsBack else {
            // An interruption cancels the animation and sends every card straight home.
            deck.cancel()
            restorePass()
            raise(chosen)
            return
        }
        dealBack(on: phaseDisplay, raising: chosen)
    }

    /// The chosen window ends up frontmost, raised once the others are back and asserted rather than
    /// assumed. Dealing leaves the stack alone, but the chosen window was behind the one the
    /// user snapped first to begin with.
    private func raise(_ chosen: WindowHandle?) {
        guard let chosen else { return }
        if !ax.raise(chosen) {
            Logger.assist.error("could not raise the chosen window after putting the others back")
        }
    }

    /// Puts a surface on every offered cell, all at once. Each gets its own model; the models start
    /// out holding the same card list and stay in step from then on.
    ///
    /// **One panel** holds all of them, covering the display's visible frame — the cells tile it, so
    /// every area is inside it, and the menu bar stays clickable. One panel because macOS renders
    /// true Liquid Glass only in the key window, and there can only be one of those: with a panel per
    /// cell, every area but the last presented fell back to a flat material. See `SnapAssistPanel`.
    private func present(_ cells: [Zone]) {
        guard let display else { return }
        let visible = display.visibleFrame
        areas = cells.map { zone in
            let model = SnapAssistAreaModel(cellSize: zone.frame.size, zoneFrame: zone.frame,
                                            candidates: offered)
            // The view takes no *mouse* callbacks: picking and cancelling are decided in
            // `handleGlobalMouseDown`, from the click itself. This one is the Accessibility press,
            // which is not a click and cannot be produced by one.
            let cellIndex = zone.cellIndex
            model.onAccessibilityPress = { [weak self] id in self?.pickFromAccessibility(id, inCell: cellIndex) }
            return Area(zone: zone, model: model)
        }
        // Given in CG, and placed in CG: `SnapAssist.areaFrame` translates each zone into the panel's
        // own space, whose y increases downward as CG's does. The one conversion to Cocoa is the
        // panel's own frame, below — the panel boundary and nowhere else.
        surfaces.panelFrame = visible
        surfaces.areas = areas.map(\.model)
        panel.onEscape = { [weak self] in self?.dismiss(.escape) }
        panel.present(frame: CoordinateSpace.cocoaRect(fromCG: visible),
                      content: SnapAssistSurfacesView(model: surfaces))
        // Next run-loop turn, so that SwiftUI draws the areas small and clear first and has a chance
        // to animate. Set here and the flag would already be true on the first frame.
        let session = self.session
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.inPhase, self.session == session else { return }
                for model in self.surfaces.areas { model.visible = true }
            }
        }
    }

    /// A card pressed through Accessibility — VoiceOver, Switch Control, or anything else driving the
    /// app's own `AXPress`. It is the same placement a click makes, through the same
    /// `pick` and the same guards; what it is not is a second reader of a mouse event, because an
    /// `AXPress` never was one. `handleGlobalMouseDown` remains the only thing that reads a click.
    private func pickFromAccessibility(_ windowID: CGWindowID, inCell cellIndex: Int) {
        guard inPhase, let candidate = offered.first(where: { $0.id == windowID }),
              let area = areas.first(where: { $0.zone.cellIndex == cellIndex }) else { return }
        Logger.assist.debug("accessibility press on window \(windowID)")
        pick(candidate, for: area.zone)
    }

    /// Takes key for `panel`, twice: now, and once more after the activation `ax.raise` set off has
    /// had its turn. The raise activates the picked window's owning app, and that activation is not
    /// synchronous — a `makeKeyAndOrderFront` issued in the same run-loop turn can be undone a moment
    /// later, which would leave Escape dead for the rest of the phase. The second pass is guarded by
    /// the session and by `isShown`, so a phase that has since ended never steals key back from
    /// whatever the user moved on to.
    private func takeKeyBack(_ panel: SnapAssistPanel) {
        panel.takeKey()
        let session = self.session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyReassertDelay) { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.inPhase, self.session == session else { return }
                panel?.takeKey()
            }
        }
    }

    /// Raises the chosen window, snaps it into `zone` and takes that area off the screen — landed or
    /// not, since a window that refuses the frame must not hold the phase open. The card leaves every
    /// other area as it goes.
    private func pick(_ candidate: Candidate, for zone: Zone) {
        guard inPhase, let display, var arrangement,
              let index = areas.firstIndex(where: { $0.zone.cellIndex == zone.cellIndex }) else { return }
        // A window is placed once. The cards of two areas are the same windows, so this is the guard
        // against a second press landing on a card that is already on its way somewhere else.
        // Unreachable from a click today, kept as a cheap regression catch — `hit(_:in:)` only ever
        // offers a card that is still in the area's list, and a picked window leaves every list in
        // this same run-loop turn — but the Accessibility press has its own timing, and logging beats
        // returning in silence.
        guard offered.contains(where: { $0.id == candidate.id }) else {
            Logger.assist.debug("window \(candidate.id) has already been placed; ignoring the press")
            return
        }
        let area = areas.remove(at: index)
        offered.removeAll { $0.id == candidate.id }

        // The arrangement takes the picked window, with what is known of its limits, and is solved
        // once for everything this pick decides: where the window goes, what a window placed earlier
        // has to give for it to fit, and where the areas still open are afterwards.
        arrangement.members[zone.cellIndex] = LayoutArrangement.Member(
            windowID: candidate.id,
            limits: SizeLimits(minimum: MinimumSizePolicy.presumed(minimums.minimum(for: candidate.handle))))
        self.arrangement = arrangement
        let solved = arrangement.solve()
        // An area the placed windows have pushed off the display is withdrawn: a cell hanging off the
        // screen is a cell no window should be sent to.
        let withdrawn = areas.filter { solved.open[$0.zone.cellIndex] == nil }
        for leaving in withdrawn {
            Logger.assist.info("cell \(leaving.zone.cellIndex) no longer fits on the display; withdrawn")
            areas.removeAll { $0.zone.cellIndex == leaving.zone.cellIndex }
            fadeOut(leaving)
        }

        if areas.isEmpty {
            // No area is left to click — the last one was just filled, or the rest were withdrawn — and
            // the filled one keeps its surface until the phase ends, because the phase is not over
            // until the window lands: something has to hold key for the length of that snap or Escape
            // would reach no window at all in the gap, and a preview over the cell the window is
            // flying into reads like the one that accompanies any other snap. It answers no click,
            // because a click is decided against `areas` and this area has just left it — so its
            // model stays in `surfaces.areas`, still `visible`, purely to keep being drawn, at the
            // frame the arrangement gives the window rather than at the cell it was offered as.
            //
            // Its cards go entirely: that area stops offering cards. Not the shortened list the other
            // areas get — there are usually more eligible windows than cells, so what is left over
            // are cards for windows nobody placed, and they would hang over the window landing in the
            // cell for the length of the snap and its fade. An emptied list has no grid, and
            // `SnapAssistCardGrid` places what is still fading out at the block's centre, so they
            // leave together from where they were.
            area.model.candidates = []
            if let frame = solved.members[zone.cellIndex] {
                area.model.zoneFrame = frame
                area.model.cellSize = frame.size
            }
        } else {
            // With areas left to click, the filled one goes: it has served its purpose, and the window
            // landing in it should be visible.
            fadeOut(area)
        }
        if !ax.raise(candidate.handle) {
            Logger.assist.error("could not raise window \(candidate.id); snapping it anyway")
        }
        // Raising the window activates its app and steals key from our non-activating panel, so the
        // surface takes it back — Escape has to keep working after a pick. It is the one panel of the
        // phase, still up, whether or not the area just filled was the last.
        takeKeyBack(panel)
        lastPicked = candidate.handle
        // The chosen window is never put back: the engine animates it into the cell, and it starts
        // that flight from **where the card is now** — mid-deal or at rest in the fan. It flies out of
        // the deck into its cell, and the flight is the point. The size is the pre-deal one, because
        // the deck never resizes anything.
        let from: CGRect
        let inTheDeck = deck.drop(candidate.id)
        if let parkedFrame = unpark(candidate.id) {
            from = CGRect(origin: inTheDeck ?? parkedFrame.origin, size: parkedFrame.size)
        } else if let read = ax.frame(of: candidate.handle) {
            from = read
        } else {
            Logger.assist.error("no frame for window \(candidate.id); animating it from the zone itself")
            from = zone.frame
        }
        Logger.assist.info("placing window \(candidate.id) into \(zone.layout.id, privacy: .public)[\(zone.cellIndex)]")
        // What, if anything, this pick ends the phase for: every area filled or withdrawn, or nothing
        // left to offer the ones that remain. Decided here, from the state the pick just left behind,
        // and spent in the completion so that the desktop refills once the window has landed rather
        // than on top of it.
        let endReason: EndReason? = areas.isEmpty ? (withdrawn.isEmpty ? .picked : .noRoom)
                                                  : (offered.isEmpty ? .noWindows : nil)
        let id = candidate.id

        // The picked window and every window placed before it go to the coordinator together: one that
        // has to give room is re-fitted in the same motion, and the correction pass sees every landing.
        // A window that needs no move is not written.
        var members = [ArrangementCoordinator.Member(id: .window(id), handle: candidate.handle, current: from, zone: zone)]
        members += placed.values.map {
            ArrangementCoordinator.Member(id: .window($0.windowID), handle: $0.handle, current: $0.current, zone: $0.zone)
        }
        placed[zone.cellIndex] = Placed(windowID: id, handle: candidate.handle, zone: zone,
                                        current: solved.members[zone.cellIndex] ?? zone.frame)
        place(arrangement.arrangement, members: members, display: display, followsFirstSolution: false) { [weak self] outcome in
            if outcome.landed[.window(id)] == nil { Logger.assist.debug("window \(id) did not land; the phase carries on") }
            return endReason ?? (self?.areas.isEmpty == true ? .noRoom : nil)
        }
        // **The reflow, last thing.** Assigning the shorter list into the models the areas are holding
        // — not rebuilding the views — is what lets SwiftUI fade and shrink the card that left and
        // slide the rest into their new places; the motion recorded beside it is how a click arriving
        // during those 0.22 s is answered against what is on screen rather than where the cards are
        // going. Both happen here, at the end, for one reason: the reflow cannot begin before this
        // run-loop turn ends, because SwiftUI cannot commit the change until the tap callback returns,
        // and everything above — the raise, the key, the unpark — runs first and costs Accessibility
        // round trips. So the turn's end is the best estimate the app has of when the cards start
        // moving, and it is also where the frames they start *from* have to be read. One clock reading
        // for one event: if these drifted apart, an interrupting pick would describe the previous
        // reflow as less advanced than the clock it is timed against, by however long the
        // Accessibility work took — 0.25 s in the worst case the messaging timeout allows.
        //
        // An area whose cell the pick has moved travels in the same motion, on the same curve.
        let started = CACurrentMediaTime()
        for slot in areas.indices {
            move(slot, to: solved.open[areas[slot].zone.cellIndex] ?? areas[slot].zone.frame,
                 candidates: offered, at: started)
        }
    }

    /// Hands a placement of the phase's arrangement to the coordinator, and keeps the phase true to it.
    ///
    /// **Picks can overlap in time**: a second card can be clicked while the first window is still
    /// flying. Each placement is a run with a number, and only the newest one may move the open areas
    /// (`follow`) — an older run's correction was solved without the newer pick in it. What any run
    /// learned is kept (`absorb`). When a run ends that was *not* the newest while it ran, the frames
    /// the newer one compared against may have been wrong, so once nothing is in flight the arrangement
    /// is placed once more, which writes whatever is still off and nothing otherwise.
    ///
    /// `reason` is asked, once the placement has settled, what it ends the phase for — nil for nothing.
    /// No run ends the phase while another is in flight: the newer one has a window in the air.
    private func place(_ arrangement: Arrangement, members: [ArrangementCoordinator.Member], display: DisplayInfo,
                       followsFirstSolution: Bool, reason: @escaping @MainActor (ArrangementCoordinator.Outcome) -> EndReason?) {
        let session = self.session
        placement &+= 1
        let placement = self.placement
        placementsInFlight += 1
        // The first solution of a pick is the one `pick` itself applies, with the reflow; the ones
        // after it are corrections, and the areas follow them as they come.
        var skipsNextSolution = !followsFirstSolution
        coordinator.run(arrangement, members: members, display: display,
                        isCurrent: { [weak self] in self?.inPhase == true && self?.session == session },
                        onSolved: { [weak self] solution in
                            if skipsNextSolution { skipsNextSolution = false; return }
                            guard let self, self.session == session, self.placement == placement else { return }
                            self.follow(solution)
                        }) { [weak self] outcome in
            guard let self, self.session == session else { return }
            self.placementsInFlight -= 1
            self.absorb(outcome)
            if self.placement != placement { self.needsReconciling = true }
            let ending = self.pendingEnd ?? reason(outcome)
            guard self.placementsInFlight == 0 else {
                self.pendingEnd = ending
                return
            }
            if let ending {
                self.dismiss(ending)
            } else if self.needsReconciling {
                self.reconcile()
            }
        }
    }

    /// Places the arrangement as it now stands: every placed window, against where each was last known
    /// to land. It writes what is off and nothing otherwise.
    private func reconcile() {
        guard inPhase, let display, let arrangement else { return }
        needsReconciling = false
        let members = placed.values.map {
            ArrangementCoordinator.Member(id: .window($0.windowID), handle: $0.handle, current: $0.current, zone: $0.zone)
        }
        place(arrangement.arrangement, members: members, display: display, followsFirstSolution: true) { [weak self] _ in
            self?.areas.isEmpty == true ? .noRoom : nil
        }
    }

    /// Gives the area in `slot` its new cell and its new list in one motion, and records that motion.
    ///
    /// Read before the assignment: `cards(of:at:)` gives the frames of the list still on screen, which
    /// on a change that interrupts a reflow are neither of the two settled arrangements — and that is
    /// exactly what SwiftUI retargets its animation from. The region a click is *ignored* in is
    /// everything that moves: the two blocks, the cards where they are, and — when the cell itself
    /// moves — the whole of the cell at both ends, because then everything in it is moving.
    private func move(_ slot: Int, to frame: CGRect, candidates: [Candidate], at started: CFTimeInterval) {
        let area = areas[slot]
        let shown = cards(of: area, at: started)
        let moves = !frame.isApproximatelyEqual(to: area.zone.frame, tolerance: 1)
        guard moves || candidates.map(\.id) != area.model.candidates.map(\.id) else { return }
        var blocks = [block(of: area.model.candidates.count, in: area.zone.frame), block(of: candidates.count, in: frame)]
        if moves { blocks += [area.zone.frame, frame] }
        let region = SnapAssistCardReflow.movingRegion(cards: shown.map(\.drawn), blocks: blocks)
        if moves {
            areas[slot].zone.frame = frame
            area.model.zoneFrame = frame
            area.model.cellSize = frame.size
        }
        area.model.candidates = candidates
        // A cell already on its way somewhere is still a moving cell, whatever this change is.
        let stillMoving = area.motion.map { $0.cellMoved && started - $0.startedAt < Self.reflowWindow } ?? false
        areas[slot].motion = CardMotion(
            from: Dictionary(uniqueKeysWithValues: shown.map { ($0.candidate.id, $0.drawn) }),
            region: region, cellMoved: moves || stillMoving, startedAt: started)
    }

    /// A correction has moved the dividers: the areas still open go where the new solution puts them,
    /// and one it has pushed off the display is withdrawn.
    private func follow(_ solution: ArrangementSolution) {
        guard inPhase, let arrangement else { return }
        let solved = arrangement.solved(from: solution)
        for leaving in areas.filter({ solved.open[$0.zone.cellIndex] == nil }) {
            Logger.assist.info("cell \(leaving.zone.cellIndex) no longer fits on the display; withdrawn")
            areas.removeAll { $0.zone.cellIndex == leaving.zone.cellIndex }
            fadeOut(leaving)
        }
        let now = CACurrentMediaTime()
        for slot in areas.indices {
            guard let frame = solved.open[areas[slot].zone.cellIndex] else { continue }
            move(slot, to: frame, candidates: areas[slot].model.candidates, at: now)
        }
    }

    /// What a finished placement taught: the limits its landings revealed, and where each placed window
    /// now stands. Merged by window, because a later pick may have added a member while this one was
    /// still landing.
    private func absorb(_ outcome: ArrangementCoordinator.Outcome) {
        for box in outcome.arrangement.boxes {
            // Only a window this placement landed: a limit is revealed by a landing and by nothing
            // else, so for any other window the limits in this outcome are the ones the placement
            // started with, and a newer placement may know better.
            guard case .window(let windowID) = box.id, let landed = outcome.landed[box.id],
                  let cell = arrangement?.members.first(where: { $0.value.windowID == windowID })?.key else { continue }
            arrangement?.members[cell]?.limits = box.limits
            placed[cell]?.current = landed
        }
    }

    /// Takes an area off the screen: filled, or withdrawn. This area alone fades, not the panel — the
    /// panel is drawing the areas that are still offering. `visible` plays the fade, and the model
    /// leaves the hosting view once it has landed; removing it now would make the area disappear
    /// rather than fade. Its list is the shortened one, so a card just picked leaves it the same way it
    /// leaves the others.
    private func fadeOut(_ area: Area) {
        area.model.candidates = offered
        area.model.visible = false
        let fadeSession = session
        let fadedID = area.model.id
        DispatchQueue.main.asyncAfter(deadline: .now() + SnapAssistPanel.dismissDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == fadeSession else { return }
                self.surfaces.areas.removeAll { $0.id == fadedID }
            }
        }
    }

    /// **Records every window the deck is about to move, and moves none of them.** The safety
    /// property lives in this method and in the order of these three lines.
    ///
    /// The frame recorded is the one from the snapshot, taken before anything moved, and it goes to
    /// disk **per window, before that window's first write** — the write itself is `DeckAnimator`'s
    /// first pass, a turn of the run loop later. Both halves of that ordering are load-bearing:
    /// saving once after the loop strands everything parked so far if the app is killed mid-loop, and
    /// saving after each *move* leaves the window whose `setPosition` has just returned off-screen
    /// with nothing on disk, which a kill landing in that gap strands for good.
    ///
    /// **The deck makes the journey longer, and that changes nothing here.** A card is in the air for
    /// up to `animationDuration + Deck.maxStagger` rather than for one write, so there is far more of
    /// it to be killed in — but the record still precedes the first write and is still on disk for
    /// every frame of the flight, and the frame it names is still the pre-move one. A kill at any
    /// instant of the deal therefore leaves a record naming a window that is somewhere between home and
    /// its slot, and the next launch puts it at home. The failure the ordering inverts is the only one
    /// that matters: a crash can leave a record for a window that never moved, which restores as a
    /// no-op; it can never leave a moved window with nothing naming it.
    ///
    /// A window whose handle Accessibility cannot reach is never recorded and never dealt. A window
    /// that *refuses* its first write is un-recorded by `deck.onCardLost`, which is the same rule
    /// applied at the only moment the app can tell.
    private func park(_ windows: [WindowInfo], handles: [CGWindowID: WindowHandle], except placed: CGWindowID?) {
        for info in windows where info.id != placed {
            guard let handle = handles[info.id] else {
                Logger.assist.debug("no Accessibility handle for window \(info.id); it stays where it is")
                continue
            }
            // A window an earlier phase could not bring home is still sitting where the deck left it,
            // so the snapshot's frame is a deck slot and not a home. The record it never managed to
            // discharge is, and it is the one carried forward.
            let home = stranded.first { $0.windowID == info.id }?.frame ?? info.frame
            stranded.removeAll { $0.windowID == info.id }
            parked.append(Parked(entry: .init(windowID: info.id, pid: info.pid, frame: home),
                                 handle: handle, observedOrigin: info.frame.origin))
            persistParked()
        }
    }

    /// The deal: every recorded window animates from its own frame to its place in the fan.
    ///
    /// Position only — a window is never resized to join the deck — and the deepest card is the
    /// frontmost window, so each card behind it peeks out a little further and the whole pile is
    /// visible at once. Beyond `Settings.deckCeiling` the overflow is placed without animation.
    ///
    /// The placement is the phase's own display, passed in rather than read back off `self`: every
    /// window this deals was parked from that display and every one of them is dealt back to it. The
    /// rest of the arrangement decides which of its corners the fan hangs from, because a card's bulk
    /// is hidden only where no display can draw it.
    ///
    /// A slot is asked for per card and not once for the deck, since two of the three anchors are
    /// measured back from the card's own size. That size is the recorded home's — the deck never
    /// resizes a window, so it is also the size the card has right now — and it costs no read: the
    /// snapshot `park` was given already carried it.
    private func dealOut(on display: DisplayInfo) {
        guard !parked.isEmpty else { return }
        let placement = Deck.Placement(display: display, among: screens.displays)
        Logger.assist.debug(
            "deck on display \(display.id): \(String(describing: placement.horizontal), privacy: .public) / \(String(describing: placement.vertical), privacy: .public)")
        let count = parked.count
        let cards = parked.enumerated().map { index, window in
            window.card(depth: index, observedAt: window.observedOrigin,
                        to: placement.slot(index, of: count, size: window.entry.frame.size))
        }
        let session = self.session
        deck.deal(cards, label: "dealing out", on: screen(for: display),
                  duration: settingsStore.settings.animationDuration,
                  smoothness: settingsStore.settings.smoothness,
                  ceiling: settingsStore.settings.deckCeiling) { [weak self] failed in
            guard let self, self.session == session else { return }
            // A card that never reached its slot stays recorded, which is the point: it moved, so it
            // has to come back, wherever the deal left it.
            for id in failed { Logger.assist.debug("card \(id) never reached its place in the deck") }
            // Started only from here: the deal is over, so nothing this starts can stutter a card
            // that is still moving.
            self.probeFromDeck(skipping: Set(failed))
        }
    }

    // MARK: - The opportunistic minimum probe

    /// Asks the applications standing in the deck what they will not shrink below, while they are
    /// standing in it.
    ///
    /// **Why here.** A minimum can only be learned by writing 1 × 1 and reading back, which costs the
    /// window a visible blink, and the deck is the one moment in this app when that blink is free: the
    /// windows are already off their user-visible positions because this class put them there, all
    /// that shows of each one is the corner sliver of the fan, and the user is looking at a pile of
    /// cards rather than at any window's content. Every probe paid here is a probe the user does not
    /// pay at the press of a handle later, and — the reason it matters more than it looks — a window
    /// whose application has a row is a window the drop preview can tell the truth about.
    ///
    /// **Every card may be probed**, whether or not its application has a row, at most once per window
    /// per session, within the budget: the cards of applications **with no row first**, in deck order,
    /// then the rest. A probe of a card whose application has a row can only lower that row or raise
    /// the card's own floor; it never raises the row (`MinimumSizeStore.recordProbe`).
    ///
    /// **Only the size is written, and only at the deck slot.** `Deck` *places* its cards rather than
    /// letting macOS clamp them (`Deck.clampMargin`), so the origin here is legal at any size and the
    /// system's own position clamp cannot move the window while it is small.
    ///
    /// Serial, one window at a time, and capped. Nothing is logged when there is nothing to do.
    private func probeFromDeck(skipping failed: Set<CGWindowID>) {
        guard inPhase else { return }
        // Every card is a free look at a window's size, whether or not the budget reaches it: a row
        // larger than the window standing in the deck is too high, and it comes down now.
        for window in parked {
            MinimumProbe.logLowering(minimums.observe(window.handle, size: window.entry.frame.size),
                                     window: window.entry.windowID, size: window.entry.frame.size,
                                     log: Logger.deck)
        }
        var rowless: [Parked] = []
        var listed: [Parked] = []
        for window in parked where !failed.contains(window.entry.windowID) && !minimums.wasProbed(window.handle) {
            if minimums.hasRow(for: window.entry.pid) { listed.append(window) } else { rowless.append(window) }
        }
        probeQueue = Array((rowless + listed).prefix(Self.deckProbeBudget))
        guard !probeQueue.isEmpty else { return }
        Logger.deck.info("""
            probing \(self.probeQueue.count) of \(self.parked.count) card(s) not yet probed this \
            session, the \(rowless.count) of applications with no row first
            """)
        probeNext(session: session)
    }

    /// One card, then the next. Re-checked against the phase every time round, because every step of
    /// this costs a round trip into another application and the user may have ended the phase in the
    /// middle of one.
    private func probeNext(session probeSession: Int) {
        guard probeSession == session, inPhase, !deck.isRunning else {
            probeQueue = []
            return
        }
        guard !probeQueue.isEmpty else { return }
        let window = probeQueue.removeFirst()
        let id = window.entry.windowID
        // Still parked, and the deck still knows where it is. Either answer being no means this card
        // has been picked or lost since the queue was built.
        guard parked.contains(where: { $0.entry.windowID == id }),
              let origin = deck.position(of: id) else {
            probeNext(session: probeSession)
            return
        }
        // The deck never resizes a card, so the recorded home frame's size is this window's size right
        // now — no Accessibility read is needed to know it, and none may be made anyway once the
        // writer has posts in flight for this window.
        let size = window.entry.frame.size
        probeRestores[id] = (window.handle, size)
        // The card's *home* display, not the deck corner it is parked at: the area the implausible-floor
        // test is against is the one the window will be given back, and a deck slot is off in a corner.
        let area = screens.display(containing: window.entry.frame.center)?.visibleFrame.size
        MinimumProbe.probeInBackground(window.handle, at: CGRect(origin: origin, size: size), area: area,
                                       writer: writer, store: minimums, log: Logger.deck) { [weak self] _ in
            guard let self else { return }
            self.probeRestores[id] = nil
            self.probeNext(session: probeSession)
        }
    }

    /// Puts back the size of any window a probe changed and did not finish putting back itself.
    ///
    /// The probe posts its own restore, but a pick calls `DeckAnimator.drop`, which `cancel`s that
    /// window in the writer, and a cancelled mailbox drops whatever was pending in it. This is the
    /// backstop that makes "a probe never leaves a window at the probed size" true rather than likely.
    ///
    /// It writes on the main thread, like `restorePass` and for the same reason: it runs on the way out
    /// of a phase — including the quit path, where a posted write has no turn of the run loop left to
    /// run in — and there being finished matters more than being smooth. **It is bounded at one
    /// window**: the chain probes serially and clears each id in its completion, so this map never
    /// holds more than one entry and the callback costs at most the 0.25 s messaging timeout, well
    /// under the 1.00–1.05 s stall that has the window server disable the tap.
    ///
    /// The `cancel` first is the same ordering `dismiss` already uses for the deck: drop what is
    /// pending in the mailbox, then write what is true. A write that was already inside Accessibility
    /// still finishes and can still race this one — that race is inherent to every main-thread write
    /// this class makes and is why `dealBack` and `restorePass` write absolute frames rather than
    /// deltas.
    private func restoreProbedSizes() {
        probeQueue = []
        guard !probeRestores.isEmpty else { return }
        let count = probeRestores.count
        for (id, entry) in probeRestores {
            writer.cancel(entry.handle)
            if !ax.setSize(entry.size, of: entry.handle) {
                Logger.deck.error("could not put window \(id) back to its size after a probe")
            }
        }
        probeRestores = [:]
        Logger.deck.info("put \(count) probed window(s) back to the size they came in at")
    }

    /// The deal back: the cards that were not picked animate to their original frames, and the
    /// windows already placed stay above them.
    ///
    /// Each card starts from **where it actually is**, not from its slot, so a deliberate end that
    /// lands in the middle of the deal simply turns the cards round instead of teleporting them.
    private func dealBack(on display: DisplayInfo?, raising chosen: WindowHandle?) {
        guard !parked.isEmpty else {
            deck.cancel()
            raise(chosen)
            return
        }
        // Where each card actually is, asked of the animator, which has either written it or still
        // holds the frame it started from. **No fallback**: "we do not know where this window is" must
        // never be answered with "at home", because that is the one answer that would let a refused
        // write throw its record away. Unreachable today, kept as a cheap regression catch —
        // `dealBack` is only entered from the `dealsBack` branch, which does not cancel the deck
        // first — so if it ever happens, the whole deal is abandoned for the unanimated restore,
        // which needs no such answer.
        let positions = parked.map { deck.position(of: $0.entry.windowID) }
        guard !positions.contains(where: { $0 == nil }) else {
            Logger.assist.error("the deck cannot say where \(positions.filter { $0 == nil }.count) card(s) are; sending every card straight home")
            deck.cancel()
            restorePass()
            raise(chosen)
            return
        }
        let cards = parked.enumerated().map { index, window in
            window.card(depth: index, observedAt: positions[index] ?? window.observedOrigin,
                        to: window.entry.frame.origin)
        }
        let session = self.session
        deck.deal(cards, label: "dealing back", on: screen(for: display),
                  duration: settingsStore.settings.animationDuration,
                  smoothness: settingsStore.settings.smoothness,
                  ceiling: settingsStore.settings.deckCeiling) { [weak self] failed in
            guard let self, self.session == session else { return }
            // A window leaves `parked` only when it is home. What the deal could not place stays
            // recorded — on disk, at its pre-move frame — for the next launch to retry.
            for window in self.parked where failed.contains(window.entry.windowID) {
                Logger.assist.error("could not put window \(window.entry.windowID) back; it stays where it is")
                self.stranded.append(window.entry)
            }
            self.parked = []
            self.persistParked()
            self.deck.cancel()
            self.raise(chosen)
        }
    }

    /// The `NSScreen` a display link should be taken from. `NSScreen.main` is the fallback, and nil is
    /// handled by the animator: a deck with no screen to pace against places its cards without one.
    private func screen(for display: DisplayInfo?) -> NSScreen? {
        guard let display else { return NSScreen.main }
        return NSScreen.screens.first { $0.displayID == display.id } ?? NSScreen.main
    }

    /// Drops one window from the dealt set *without moving it*, and hands back the frame it had before
    /// it was dealt. Nil when the app never dealt it — then the caller has to ask Accessibility.
    private func unpark(_ id: CGWindowID) -> CGRect? {
        guard let index = parked.firstIndex(where: { $0.entry.windowID == id }) else { return nil }
        let frame = parked[index].entry.frame
        parked.remove(at: index)
        persistParked()
        return frame
    }
}
