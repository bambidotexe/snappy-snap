import CoreGraphics
import Foundation
import Testing
@testable import SnapCore

/// The deck, in the part that can be decided without AppKit: where each card rests in the fan,
/// when each one moves, and when a card counts as home.
///
/// The assertions are written against the properties the deck must have and not against the numbers
/// that happen to be in the source today — a fan whose cards land on the same point is not a fan — so
/// the fan's separation is swept over every deck size. What survives here is what the deck still
/// decides.
@Suite struct DeckTests {
    /// Swift Testing boxes `CGFloat` against `Double`; compare with an epsilon, never with `==`.
    func near(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool { abs(a - b) <= epsilon }

    /// A display like the one everything was measured on.
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 925))

    /// A card in the sweeps below: a window that fits on every display used here, since a card
    /// longer than its display is the one case no placement can keep off a neighbour.
    let card = CGSize(width: 1268, height: 663)

    /// Nothing beside it, so the deck keeps the bottom-right corner it has always used.
    var lone: Deck.Placement { Deck.Placement(display: display, among: [display]) }
    var corner: CGPoint { lone.slot(0, of: 1, size: card) }

    // MARK: the fan

    @Test func theFrontmostCardRestsAtTheCornerAndNothingElseDoes() throws {
        #expect(near(Deck.slotOffset(0, of: 1).dx, 0))
        #expect(near(Deck.slotOffset(0, of: 1).dy, 0))
        for count in 2...40 {
            #expect(near(Deck.slotOffset(0, of: count).dx, 0))
            #expect(near(Deck.slotOffset(0, of: count).dy, 0))
            for index in 1..<count {
                let offset = Deck.slotOffset(index, of: count)
                #expect(hypot(offset.dx, offset.dy) > 0, "card \(index) of \(count) sits on the corner")
            }
        }
    }

    /// Every card's clamped sliver has to stay distinct: two cards
    /// resting on the same point are one card, and the deck reads as the corner artefact it was born as.
    /// Swept up to twice the deck ceiling, not only the size the constants were chosen for.
    @Test func everyCardsSliverStaysDistinctAtEveryDeckSize() throws {
        for count in 1...(2 * Settings.Fixed.deckCeiling) {
            let slots = lone.slots(count: count, size: card)
            try #require(slots.count == count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let separation = hypot(slots[i].x - slots[j].x, slots[i].y - slots[j].y)
                    #expect(separation >= Deck.minCardSeparation - 1e-9,
                            "cards \(i) and \(j) of \(count) are \(separation) pt apart")
                }
            }
        }
    }

    /// The property the one above rests on, stated on its own so a change to the arc cannot quietly
    /// take it away: the radius grows by a whole spacing per card, and the triangle inequality then
    /// makes any two cards at least `(j - i) × spacing` apart whatever the angles do.
    @Test func theRadiusGrowsByAWholeSpacingPerCard() {
        for count in 2...40 {
            let spacing = Deck.spacing(count: count)
            #expect(spacing >= Deck.spacingFloor - 1e-9)
            for index in 1..<count {
                let here = Deck.slotOffset(index, of: count)
                let before = Deck.slotOffset(index - 1, of: count)
                #expect(near(hypot(here.dx, here.dy) - hypot(before.dx, before.dy), spacing, 1e-9))
            }
        }
    }

    /// An arc, not a diagonal: the direction a card is offset in turns as the deck deepens, which is
    /// what makes the slivers read as a fan rather than as a staircase. Read edge-on — "there is
    /// no rotation in Accessibility" — so the turn is in the offsets and never in a card.
    @Test func theOffsetsSweepAnArc() throws {
        let count = 20
        let first = Deck.slotOffset(1, of: count)
        let last = Deck.slotOffset(count - 1, of: count)
        let firstAngle = atan2(first.dy, first.dx), lastAngle = atan2(last.dy, last.dx)
        #expect(lastAngle > firstAngle + 0.3, "the fan is a straight line, not an arc")
        // Monotone, so no card doubles back over the one before it.
        for index in 2..<count {
            let here = Deck.slotOffset(index, of: count)
            let before = Deck.slotOffset(index - 1, of: count)
            #expect(atan2(here.dy, here.dx) >= atan2(before.dy, before.dx) - 1e-9)
        }
    }

    /// The fan is placed, never clamped. The corner it is measured back from is inset far enough
    /// that every requested position is legal even against the most generous clamp measured,
    /// 111 pt — a clamped deck is a deck whose first cards land on one point, which is exactly
    /// what the sweep above forbids.
    @Test func theDeepestCardIsInsideEvenTheMostGenerousClampEverMeasured() {
        let widestSliverEverMeasured = CGSize(width: 40, height: 111)
        #expect(corner.x <= display.frame.maxX - widestSliverEverMeasured.width)
        #expect(corner.y <= display.frame.maxY - widestSliverEverMeasured.height)
    }

    @Test func theDeckStaysInTheBottomRightCornerOfALoneDisplay() throws {
        for count in 1...(2 * Settings.Fixed.deckCeiling) {
            for slot in lone.slots(count: count, size: card) {
                #expect(slot.x > display.frame.minX)
                #expect(slot.y > display.frame.minY)
                #expect(slot.x <= corner.x + 1e-9)
                #expect(slot.y <= corner.y + 1e-9)
                // Still recognisably a corner effect rather than a second arrangement of the desktop.
                #expect(slot.x >= display.frame.maxX - display.frame.width / 3)
                #expect(slot.y >= display.frame.maxY - display.frame.height * 0.6)
            }
        }
    }

    // MARK: which corner the fan hangs from

    func screen(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DisplayInfo {
        DisplayInfo(id: id, frame: CGRect(x: x, y: y, width: w, height: h),
                    visibleFrame: CGRect(x: x, y: y + 25, width: w, height: h - 25))
    }

    /// Two 2560 × 1440 displays side by side: the arrangement the defect was measured on.
    var pair: [DisplayInfo] { [screen(1, 0, 0, 2560, 1440), screen(2, 2560, 0, 2560, 1440)] }
    /// Three in a row, so one display is hemmed in on both sides.
    var row: [DisplayInfo] { [screen(1, 0, 0, 1512, 982), screen(2, 1512, 0, 1512, 982),
                              screen(3, 3024, 0, 1512, 982)] }
    /// One display above another, which blocks an axis the other arrangements leave free.
    var stack: [DisplayInfo] { [screen(1, 0, 0, 1512, 982), screen(2, 0, 982, 1512, 982)] }

    /// **The corner is a consequence of the arrangement, not a constant.** The bulk of a card has to
    /// leave the desktop to stay hidden, so it goes past whichever edge has no display beyond it.
    @Test func theFanHangsFromTheEdgeWhoseOverhangLeavesTheDesktop() {
        // A lone display keeps the bottom-right corner the deck was born with.
        #expect(lone.horizontal == .pastFar)
        #expect(lone.vertical == .pastFar)

        // Side by side: the left display hangs its cards off its own left edge, the right one keeps
        // the bottom-right. This is the defect, stated as the rule that replaces it.
        #expect(Deck.Placement(display: pair[0], among: pair).horizontal == .pastNear)
        #expect(Deck.Placement(display: pair[0], among: pair).vertical == .pastFar)
        #expect(Deck.Placement(display: pair[1], among: pair).horizontal == .pastFar)

        // Hemmed in on both sides, nothing may leave horizontally: the deck hangs straight down from
        // the bottom centre.
        #expect(Deck.Placement(display: row[1], among: row).horizontal == .none)
        #expect(Deck.Placement(display: row[1], among: row).vertical == .pastFar)

        // A display with another below it hangs its cards off its top edge instead.
        #expect(Deck.Placement(display: stack[0], among: stack).vertical == .pastNear)
        #expect(Deck.Placement(display: stack[0], among: stack).horizontal == .pastFar)
        #expect(Deck.Placement(display: stack[1], among: stack).vertical == .pastFar)
    }

    /// A neighbour blocks an axis only where it overlaps on the other one, and abutment is not
    /// required: a display set off to the right with a gap in front of it still draws whatever
    /// slides into that gap.
    @Test func aNeighbourBlocksOnlyWhereItCouldActuallyDrawTheCard() {
        let gapped = [display, screen(2, 2000, 0, 1512, 982)]
        #expect(Deck.Placement(display: display, among: gapped).horizontal == .pastNear)

        // Diagonally placed, sharing neither a row nor a column: it can catch nothing.
        let diagonal = [display, screen(2, 2000, 1500, 1512, 982)]
        #expect(Deck.Placement(display: display, among: diagonal).horizontal == .pastFar)
        #expect(Deck.Placement(display: display, among: diagonal).vertical == .pastFar)
    }

    /// **The property the whole placement exists for: no part of any card is ever drawn on a display
    /// the phase is not running on.** Swept over every arrangement, every display in it, several card
    /// sizes and every deck size — a card that crosses a seam is the defect whether it is the deepest
    /// one or the shallowest.
    @Test func noCardIsEverDrawnOnAnotherDisplay() throws {
        var trespassing: [String] = []
        var invisible: [String] = []
        for displays in [pair, row, stack, [display]] {
            for phase in displays {
                let placement = Deck.Placement(display: phase, among: displays)
                for size in [CGSize(width: 300, height: 200), card, CGSize(width: 900, height: 900)] {
                    for count in 1...Settings.Fixed.deckCeiling {
                        for slot in placement.slots(count: count, size: size) {
                            let rect = CGRect(origin: slot, size: size)
                            for other in displays where other.id != phase.id {
                                if rect.intersects(other.frame) {
                                    trespassing.append("\(size) card of \(count) at \(slot) reaches display \(other.id)")
                                }
                            }
                            // …and it is still on the phase's display, or the user has no card to see.
                            if !rect.intersects(phase.frame) {
                                invisible.append("\(size) card of \(count) at \(slot) shows nothing on display \(phase.id)")
                            }
                        }
                    }
                }
            }
        }
        #expect(trespassing.isEmpty, "\(trespassing.prefix(3))")
        #expect(invisible.isEmpty, "\(invisible.prefix(3))")
    }

    /// Where nothing may leave, the card is laid on the display whole and centred rather than pushed
    /// past an edge it cannot pass.
    @Test func aDisplayHemmedInOnBothSidesCentresItsCards() throws {
        let middle = row[1]
        let placement = Deck.Placement(display: middle, among: row)
        let deepest = try #require(placement.slots(count: 1, size: card).first)
        #expect(near(deepest.x, ((middle.frame.minX + middle.frame.maxX - card.width) / 2).rounded()))
        // Still hanging off the bottom, which is the one edge it is free to use.
        #expect(near(deepest.y, middle.frame.maxY - Deck.clampedSliver.height - Deck.clampMargin))
    }

    // MARK: when a record may be thrown away

    /// **The safety property, as arithmetic.** A refused write may un-record a window only while that
    /// window is still standing where its record says it belongs. Every other case keeps the record,
    /// because the record is the only thing that knows where the window came from.
    @Test func onlyAWindowStillAtItsRecordedHomeMayLoseItsRecord() {
        let home = CGPoint(x: 100, y: 200), slot = CGPoint(x: 1448, y: 867)
        // Dealing out, nothing written yet: the one case that may forget.
        #expect(Deck.mayForgetRecord(journeyStartsAt: home, recordedHome: home, hasBeenWritten: false))
        // Dealing out, already moved.
        #expect(!Deck.mayForgetRecord(journeyStartsAt: home, recordedHome: home, hasBeenWritten: true))
        // **Dealing back**, nothing written *this journey*: the window is
        // in the corner; forgetting it here strands it with nothing naming it.
        #expect(!Deck.mayForgetRecord(journeyStartsAt: slot, recordedHome: home, hasBeenWritten: false))
        #expect(!Deck.mayForgetRecord(journeyStartsAt: slot, recordedHome: home, hasBeenWritten: true))
        // A point away from home by a rounding error is still "away": the answer errs toward keeping
        // the record, and restoring a window to the frame it is already at is a no-op.
        #expect(!Deck.mayForgetRecord(journeyStartsAt: CGPoint(x: 100.4, y: 200),
                                      recordedHome: home, hasBeenWritten: false))
    }

    /// The other half of the same safety property: the driver does not know
    /// whether a write succeeded — it knows what the window's **flush** read back, and a window can be
    /// a point away from the position it was handed. Both axes, and the boundary is inclusive: at
    /// exactly the tolerance the window counts as standing there.
    @Test func aWindowIsStandingOnAPointWhenItIsWithinAPointOfIt() {
        let target = CGPoint(x: 1448, y: 867)
        #expect(Deck.arrived(at: target, target: target))
        #expect(Deck.arrived(at: CGPoint(x: 1447, y: 868), target: target))
        #expect(Deck.arrived(at: CGPoint(x: 1448.5, y: 866.5), target: target))
        // A point on one axis is fine; two points on either is not.
        #expect(!Deck.arrived(at: CGPoint(x: 1450, y: 867), target: target))
        #expect(!Deck.arrived(at: CGPoint(x: 1448, y: 865), target: target))
        // The deck's own sliver is nowhere near home, which is the comparison that decides whether a
        // window moved at all.
        #expect(!Deck.arrived(at: CGPoint(x: 100, y: 200), target: target))
        #expect(near(Deck.arrivalTolerance, 1))
    }

    // MARK: the overflow

    /// The cards past the deck's size are placed, not animated — and they are placed over the length
    /// of the deal rather than all on its first frame, so the corner is not already full before a
    /// single card that *does* animate has arrived in it.
    @Test func theOverflowIsSpreadAcrossTheDealRatherThanLandingAtOnce() {
        let span = Deck.totalDuration(count: 34, duration: 0.25)
        #expect(near(Deck.overflowDelay(0, of: 30, deckOf: 34, duration: 0.25), 0))
        #expect(near(Deck.overflowDelay(29, of: 30, deckOf: 34, duration: 0.25), span))
        // Monotone and strictly spread: no two land at the same instant.
        var last = -1.0
        for index in 0..<30 {
            let at = Deck.overflowDelay(index, of: 30, deckOf: 34, duration: 0.25)
            #expect(at > last)
            last = at
        }
        // One overflow card has nothing to be spread against and lands immediately.
        #expect(near(Deck.overflowDelay(0, of: 1, deckOf: 5, duration: 0.25), 0))
    }
    // MARK: the ceiling

    @Test func theCeilingDecidesHowManyCardsAreAnimated() {
        #expect(Deck.animatedCount(12, ceiling: 20) == 12)
        #expect(Deck.animatedCount(34, ceiling: 20) == 20)
        #expect(Deck.animatedCount(0, ceiling: 20) == 0)
        // A ceiling of nothing still deals nothing rather than crashing on a negative count.
        #expect(Deck.animatedCount(34, ceiling: 0) == 0)
    }

    // MARK: timing

    @Test func everyCardReachesItsSlotExactlyAtTheEnd() throws {
        for count in 1...20 {
            let total = Deck.totalDuration(count: count, duration: 0.25)
            for index in 0..<count {
                #expect(near(Deck.progress(card: index, of: count, elapsed: total, duration: 0.25), 1))
                #expect(near(Deck.progress(card: index, of: count, elapsed: total + 1, duration: 0.25), 1))
            }
        }
    }

    @Test func aCardHasNotMovedBeforeItsTurnToBeDealt() {
        let count = 8
        for index in 1..<count {
            let delay = Deck.delay(index, of: count)
            #expect(delay > 0)
            #expect(near(Deck.progress(card: index, of: count, elapsed: delay, duration: 0.25), 0))
            #expect(near(Deck.progress(card: index, of: count, elapsed: delay / 2, duration: 0.25), 0))
        }
        // The first card is dealt immediately; nothing waits on nothing.
        #expect(near(Deck.delay(0, of: count), 0))
    }

    @Test func theDealNeverStaggersLongerThanItsCap() {
        for count in 1...40 {
            #expect(Deck.delay(count - 1, of: count) <= Deck.maxStagger + 1e-9)
            #expect(Deck.totalDuration(count: count, duration: 0.4) <= 0.4 + Deck.maxStagger + 1e-9)
        }
    }

    /// The rounding is load-bearing: the deck skips a write whose target equals the position it last
    /// wrote, and sub-point arithmetic would make that comparison never fire, so every settled card
    /// would pay a full Accessibility round trip on every pass.
    ///
    /// **Odd deltas on purpose.** Whole-number deltas would give a midpoint that is already a
    /// whole number with or without rounding, so the test would assert nothing about rounding.
    /// These deltas are 1301 and 661, so the unrounded midpoint is (750.5, 530.5) and the
    /// assertion can only hold if `position` rounds.
    @Test func aPositionInterpolatesAndRoundsToWholePoints() {
        let from = CGPoint(x: 100, y: 200), to = CGPoint(x: 1401, y: 861)
        #expect(near(Deck.position(from: from, to: to, progress: 0).x, 100))
        #expect(near(Deck.position(from: from, to: to, progress: 1).x, 1401))
        #expect(near(Deck.position(from: from, to: to, progress: 1).y, 861))
        let mid = Deck.position(from: from, to: to, progress: 0.5)
        #expect(near(mid.x, 751), "the unrounded midpoint is 750.5")
        #expect(near(mid.y, 531), "the unrounded midpoint is 530.5")
    }

    @Test func progressIsEasedRatherThanLinear() {
        // The same curve the stepping engine uses, so a card and a snap look like one system.
        let eased = Deck.progress(card: 0, of: 1, elapsed: 0.0625, duration: 0.25)
        #expect(eased < 0.25, "an ease-in curve starts slower than linear")
    }
}
