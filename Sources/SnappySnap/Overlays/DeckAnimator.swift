import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// The Snap Assist deck, driven: N windows animated into the corner and back, every card posted on
/// every frame it moves on.
///
/// A class of its own rather than more of `SnapAssistController`: an animation loop with its own clock
/// is the piece that separates cleanly. What stays in the controller is the thing that must not move —
/// the record-before-move rule and the persisted list of parked windows. This class never touches
/// either; it is handed cards and it moves windows.
///
/// **Nothing it writes touches the main thread.** A tick only *posts* each card's interpolated
/// position to `WindowWriter` — 0.01 ms whatever the target application is doing, one serial queue per
/// pid, and a post to a window whose previous frame has not landed **replaces** it rather than
/// queueing behind it. A browser drops its own stale frames and slows neither the deck nor the tap.
///
/// **Position only.** Every request carries `writeSize: false`, so no application's minimum size can
/// distort a card and the deck never pays for the expensive call.
///
/// **What the flush is for.** A card's journey ends in one `flush` per card, whose `landedFrame` is
/// read on the worker and delivered on the main actor. That read is the *only* evidence this class
/// has about where a window ended up — a post is fire-and-forget and a dropped intermediate post is
/// not a failure — and it is what decides both halves of parking safety: whether a card arrived
/// (`completion`) and, in the one case where the application would not move the window at all,
/// whether its record may be thrown away (`onCardLost`, via `Deck.mayForgetRecord`).
@MainActor
final class DeckAnimator {
    /// One window on its way into or out of the deck.
    struct Card {
        let id: CGWindowID
        let handle: WindowHandle
        /// Where this card sits in the deck: 0 = the top, which is the card dealt deepest into the
        /// corner and the first one dealt.
        ///
        /// Fixed for the whole of **one journey**, so the fan cannot re-shuffle under a window already
        /// in flight. It is *not* fixed across journeys: the deal back re-indexes what is left of the
        /// deck, so a card picked out of the middle does move every deeper card one place up. That is
        /// right — the remaining pile has a new top — and it is only safe because a deal back's targets
        /// are home frames rather than slots, so nothing about the fan depends on it. A future re-fan
        /// would have to think about this again.
        let depth: Int
        let from: CGPoint
        let to: CGPoint
        /// **Where the record says this window belongs**, which is the only thing that decides whether
        /// its record may be thrown away. See `landed(_:_:)`.
        let home: CGPoint
    }

    /// An animation in progress. The cards themselves outlive it, so a settled deck can still say
    /// where each of its cards is.
    private struct Flight {
        let link: CADisplayLink?
        let label: String
        let deckCount: Int
        let duration: Double
        let startedAt: CFTimeInterval
        let completion: (Set<CGWindowID>) -> Void
        /// How many cards this flight animates; the rest are placed without animation, at the deck's
        /// ceiling. Fixed for the flight — re-deciding it mid-journey would have a card stop being
        /// animated half way there, which is a jump, not a degradation.
        let animated: Int
        /// How often a frame may post, from the display's refresh rate and the Smoothness preset.
        let rate: PostRate
        /// When the last pass posted, which is what `rate` gates the next one against.
        var lastPost: CFTimeInterval?
        /// The final positions have gone out and every card is waiting on its flush.
        var landing = false
        /// Cards whose final flush has not answered yet. `isRunning` is true while this is non-empty.
        var waiting: Set<CGWindowID> = []
        /// Cards whose final flush did not confirm them standing at their target.
        var failed: Set<CGWindowID> = []
        /// Cards the application would not move at all — reported through `onCardLost`, never through
        /// `completion`. The two channels are disjoint by construction.
        var lost: [CGWindowID] = []
        /// Frames that posted. Not display-link callbacks: `rate` throttles below the link on the
        /// Balanced and Battery presets, and what this counts is the passes that happened.
        var frames = 0
        var posts = 0
        /// Posts the mailboxes replaced before they were written — the writer's own count, summed off
        /// the outcomes this flight owns.
        var superseded = 0
        /// What each application's writes cost, by pid, for the one line at the end.
        var costs: [pid_t: [Double]] = [:]
    }

    private let writer: WindowWriter

    /// The deck. Outlives a flight so `position(of:)` answers at rest too, and is emptied only by
    /// `cancel()` or by the next `deal`.
    private var cards: [Card] = []
    /// The last position each card was **posted** to — the deck's own belief about where its cards
    /// are, replaced by what a flush reads back when one answers. Two jobs: it is what `position(of:)`
    /// hands a deal back, and it is what makes a post that cannot move a window free (see
    /// `Deck.position`).
    private var lastPosted: [CGWindowID: CGPoint] = [:]
    /// The writer generation each card's journey was begun under. An outcome carrying any other
    /// generation belongs to a gesture this flight does not own — a write still inside Accessibility
    /// when the last deal ended, or another subsystem's — and must teach this one nothing.
    private var generations: [CGWindowID: Int] = [:]
    private var flight: Flight?

    /// A card the application would not move at all. Such a window is not recorded and is left alone,
    /// so the controller drops it from the parked list. A card that moved and then stopped
    /// short is a different animal: it is reported through `completion` instead, it keeps its record,
    /// and it will be put back.
    var onCardLost: ((CGWindowID) -> Void)?

    init(writer: WindowWriter) {
        self.writer = writer
    }

    /// True from `deal` until the last card's flush has answered.
    var isRunning: Bool { flight != nil }

    /// Where a card is now: the last position posted to it — or read back for it — or where it started
    /// if it has not moved. Answers at rest as well as in flight, which is what a pick needs: the
    /// flight out of the deck starts wherever the card actually is.
    func position(of id: CGWindowID) -> CGPoint? {
        if let posted = lastPosted[id] { return posted }
        return cards.first { $0.id == id }?.from
    }

    /// Takes a card out of the deck without moving it, and says where it was. The remaining cards keep
    /// their slots: re-fanning them would buy a tidier gap at the price of a whole second animation
    /// over every window, and the gap a picked card leaves is a gap in a pile of windows.
    ///
    /// The writer is told, because "without moving it" has to include the frame still sitting in this
    /// window's mailbox. Whatever picks the card up next — the snap engine, on the way to a cell —
    /// opens its own gesture with a `begin`, and this makes sure nothing of the deck's is left in
    /// front of it.
    @discardableResult
    func drop(_ id: CGWindowID) -> CGPoint? {
        let where_ = position(of: id)
        if let card = cards.first(where: { $0.id == id }) { writer.cancel(card.handle) }
        cards.removeAll { $0.id == id }
        lastPosted[id] = nil
        generations[id] = nil
        if var run = flight {
            run.waiting.remove(id)
            run.failed.remove(id)
            run.lost.removeAll { $0 == id }
            flight = run
            finishIfLanded()
        }
        return where_
    }

    /// Starts an animation over `cards`. `completion` is called once every card's flush has answered,
    /// with the ids that were not confirmed standing at their target.
    func deal(_ cards: [Card], label: String, on screen: NSScreen?, duration: TimeInterval,
              smoothness: Smoothness, ceiling: Int,
              completion: @escaping (Set<CGWindowID>) -> Void) {
        cancel()
        guard !cards.isEmpty else { completion([]); return }
        self.cards = cards
        let animated = Deck.animatedCount(cards.count, ceiling: ceiling)
        let rate = PostRate(refreshRate: Self.refreshRate(of: screen), smoothness: smoothness)
        // One `begin` per card, before its first post: it seeds the writer with where the window is
        // and claims the element for its pid's queue, and it hands back the generation every outcome
        // of this journey will carry.
        for card in cards { generations[card.id] = writer.begin(card.handle, current: Self.frame(at: card.from)) }
        let link = screen?.displayLink(target: self, selector: #selector(tick(_:)))
        flight = Flight(link: link, label: label, deckCount: cards.count, duration: duration,
                        startedAt: CACurrentMediaTime(), completion: completion,
                        animated: animated, rate: rate)
        Logger.deck.debug("""
            \(label, privacy: .public): \(cards.count) card(s), \
            \(cards.count - animated) placed rather than animated, posting at \(Int(rate.rate)) Hz
            """)
        if let link {
            link.add(to: .main, forMode: .common)
        } else {
            // No screen to pace against — a display that went away between the drop and here. There is
            // nothing to animate *on*, so every card goes straight to its place and the flushes follow.
            Logger.deck.error("no screen for the deck; placing \(cards.count) card(s) without animation")
            land()
        }
    }

    /// Drops the animation on the spot, with no writes of any kind. Every card's pending post is
    /// cancelled and every flush still waiting is answered nil. The caller owns
    /// what happens to the windows next; nothing here knows where home is, and no `completion` is
    /// called.
    ///
    /// `flight` is cleared **before** the writer is told, so the nil flushes that come back find no
    /// flight and say nothing.
    func cancel() {
        guard flight != nil || !cards.isEmpty else { return }
        flight?.link?.invalidate()
        flight = nil
        for card in cards { writer.cancel(card.handle) }
        cards = []
        lastPosted = [:]
        generations = [:]
    }

    /// Every applied write the writer reports, offered to the deck by `AppDelegate`'s fan-out. Nothing
    /// here changes what the deck does; it is the material for the one line at the end of a deal, and
    /// it is the only place the mailboxes' `superseded` counts can be seen at all.
    func record(_ outcome: WindowWriter.Outcome) {
        guard var run = flight else { return }
        guard let id = outcome.handle.windowID, generations[id] == outcome.generation else { return }
        run.superseded += outcome.superseded
        run.costs[outcome.handle.pid, default: []].append(outcome.cost)
        flight = run
    }

    // MARK: - The pass

    @objc private func tick(_ link: CADisplayLink) {
        guard var run = flight, !run.landing else { link.invalidate(); return }
        let now = CACurrentMediaTime()
        let elapsed = now - run.startedAt
        if elapsed >= Deck.totalDuration(count: run.deckCount, duration: run.duration) {
            flight = run
            land()
            return
        }
        guard run.rate.shouldPost(now: now, lastPost: run.lastPost) else { flight = run; return }
        run.lastPost = now
        run.frames += 1
        for card in cards {
            if card.depth >= run.animated {
                // Past the deck's ceiling: placed rather than animated, once, on its own turn rather
                // than all of them on the first frame — see `Deck.overflowDelay`. The skip in
                // `post` is what makes sure it is placed exactly once.
                guard elapsed >= Deck.overflowDelay(card.depth - run.animated,
                                                    of: run.deckCount - run.animated,
                                                    deckOf: run.deckCount, duration: run.duration)
                else { continue }
                post(card.to, to: card, in: &run)
            } else {
                post(Deck.position(from: card.from, to: card.to,
                                   progress: Deck.progress(card: card.depth, of: run.deckCount,
                                                           elapsed: elapsed, duration: run.duration)),
                     to: card, in: &run)
            }
        }
        flight = run
    }

    /// One card, one frame. **Every card is posted on every frame**, with the single exception of a
    /// card whose rounded position has not changed since the last post, which is a card that has not
    /// moved. That is not a rationing: it cannot delay a card
    /// by so much as a frame, and what it saves is a full Accessibility round trip **into the
    /// target application** for a write that could not change anything on screen. It is what keeps a
    /// card free before its turn to be dealt and after it has arrived, and `Deck.position` rounds to
    /// whole points precisely so that the comparison can fire.
    private func post(_ point: CGPoint, to card: Card, in run: inout Flight) {
        guard lastPosted[card.id] != point else { return }
        lastPosted[card.id] = point
        run.posts += 1
        writer.post(WindowWriter.Request(frame: Self.frame(at: point), writeSize: false),
                    to: card.handle)
    }

    /// The end of the deal: every card's exact target, then one `flush` each.
    ///
    /// The posts go out first and the flushes afterwards, all of them, so the reads queue behind the
    /// last frame of their own window and none of them behind another window's. A flush answers on the
    /// main actor with the frame the application reports, and an application that never answers costs
    /// its deadline and reports a failure rather than holding anything up.
    private func land() {
        guard var run = flight, !run.landing else { return }
        run.landing = true
        run.link?.invalidate()
        var flushes: [(card: Card, generation: Int)] = []
        for card in cards {
            guard let generation = generations[card.id] else { continue }
            post(card.to, to: card, in: &run)
            run.waiting.insert(card.id)
            flushes.append((card, generation))
        }
        flight = run
        for (card, generation) in flushes {
            writer.flush(card.handle) { [weak self] outcome in
                self?.landed(card, generation: generation, outcome)
            }
        }
        finishIfLanded()
    }

    /// One card's flush, home. Three answers, and parking safety turns on telling them apart.
    ///
    /// - **A frame was read.** Standing at its target to within `Deck.arrivalTolerance`: arrived. Not
    ///   at its target but somewhere other than its recorded home: it moved and stopped short, so it
    ///   keeps its record and is reported through `completion`. Standing exactly where the record says
    ///   it belongs, on a journey that started there: the application would not move it at all, which
    ///   is the one case that lets a record be discarded — `Deck.mayForgetRecord` is the rule and this
    ///   is its only caller.
    /// - **An `Outcome` with no frame.** The flush reached its deadline, or the read was refused. The
    ///   window may have moved or may not, so the record stays: `mayForgetRecord`'s error direction is
    ///   deliberate, and keeping a record that was not needed restores a window to where it already is
    ///   while losing one loses a window.
    /// - **nil: cancelled.** Only reachable through `drop`, or through another subsystem opening its
    ///   own gesture on this window; `cancel()` clears the flight first, so its nils arrive to nothing.
    ///   Not confirmed home, so — like a deadline — the record stays.
    ///
    /// **Matched on the generation, never on the card alone.** `WindowHandle` compares by its
    /// Accessibility element, so the same window looked up again in a later deal compares equal to
    /// this one — and a flush whose read had already started when the last deal was cancelled still
    /// answers, on the next turn of the main queue, by which time this deal may already be waiting on
    /// the very same card. The generation `begin` handed back is what tells them apart.
    private func landed(_ card: Card, generation: Int, _ outcome: WindowWriter.Outcome?) {
        guard var run = flight, generations[card.id] == generation,
              run.waiting.contains(card.id) else { return }
        run.waiting.remove(card.id)
        if let outcome, outcome.generation == generation {
            // This window's last mailbox count. It reaches the tally nowhere else: a flush's outcome
            // is delivered to its own completion and never to `onOutcome`.
            run.superseded += outcome.superseded
            if let landed = outcome.landedFrame {
                lastPosted[card.id] = landed.origin
                if Deck.arrived(at: landed.origin, target: card.to) {
                    flight = run
                    finishIfLanded()
                    return
                }
                // "Has it moved at all" is the only sense of `hasBeenWritten` the writer can answer:
                // posts are fire-and-forget and a dropped one is not a failure, so the evidence is
                // where the window actually is rather than how many writes were applied.
                let moved = !Deck.arrived(at: landed.origin, target: card.home)
                if Deck.mayForgetRecord(journeyStartsAt: card.from, recordedHome: card.home,
                                        hasBeenWritten: moved) {
                    run.lost.append(card.id)
                    cards.removeAll { $0.id == card.id }
                    flight = run
                    finishIfLanded()
                    return
                }
            }
        }
        run.failed.insert(card.id)
        flight = run
        finishIfLanded()
    }

    /// Ends the deal once every card's flush has answered.
    private func finishIfLanded() {
        guard let run = flight, run.landing, run.waiting.isEmpty else { return }
        flight = nil
        let wall = max(CACurrentMediaTime() - run.startedAt, 0.001)
        let slowest = run.costs
            .map { (pid: $0.key, p95: Self.percentile95($0.value)) }
            .max { $0.p95 < $1.p95 }
        Logger.deck.info("""
            deck \(run.label, privacy: .public): \(self.cards.count) cards, \(run.frames) frames, \
            \(run.posts) posts, \(run.superseded) superseded, \
            slowest \(Int(slowest?.pid ?? 0)) \
            \(String(format: "%.2f", (slowest?.p95 ?? 0) * 1000), privacy: .public) ms \
            (\(Int(wall * 1000)) ms wall, \(run.failed.count) card(s) never arrived, \
            \(run.lost.count) never moved)
            """)
        // Un-recording comes first: a lost card has left `cards` and is not in `failed`, so the two
        // channels never name the same window and the controller sees the record go before it is told
        // what did not arrive.
        for id in run.lost { onCardLost?(id) }
        run.completion(run.failed)
    }

    // MARK: - Small rules

    /// A position-only request's rectangle. Every post carries `writeSize: false`, so the size in here
    /// is never written — and never read either, because the writer's ordering rule only chooses which
    /// of two writes goes first and there is only ever one. `.zero` says that, rather than carrying a
    /// size the deck has no use for and would then have to keep true.
    private static func frame(at point: CGPoint) -> CGRect { CGRect(origin: point, size: .zero) }

    /// The 95th percentile of an application's write costs — the figure this app's write measurements
    /// are quoted in, and the one that says whether a deck was smooth for a given application rather
    /// than on average. Computed once, at the end of a deal.
    private static func percentile95(_ costs: [Double]) -> Double {
        guard !costs.isEmpty else { return 0 }
        let sorted = costs.sorted()
        let rank = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Aim at the display's refresh rate, never at a number in the source.
    private static func refreshRate(of screen: NSScreen?) -> Double {
        let rate = Double((screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0)
        return rate > 0 ? rate : PostRate.fallbackRefreshRate
    }
}
