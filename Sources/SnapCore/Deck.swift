import CoreGraphics
import Foundation

/// The deck: the windows a choosing phase clears out of the way are *dealt* into a bottom corner of
/// the phase's own display, their edges staggered like the edge of a deck of cards, and dealt back
/// when the phase ends. Which corner is `Placement`'s answer, not a constant.
///
/// This is the part of it that can be decided without AppKit — where each card rests and when each
/// one moves. Everything that needs Accessibility is in `DeckAnimator`. All of it is in CG space:
/// origin at the top-left of the primary display, y down.
///
/// Every card's position write goes through `WindowWriter`, off the run loop that serves the event
/// tap — one serial queue per pid, one single-slot mailbox per window — so a dear application drops
/// its own stale frames and slows nobody else, and the deck posts every card on every frame it moves
/// on.
///
/// One measured fact shapes this file: **cost is per Accessibility call and flat in distance**, 1 pt
/// costing what 600 pt costs. That is why `position` rounds to whole points — a card whose rounded
/// target has not changed has not moved, and the write that would say so is a full round trip into
/// the target application for nothing.
///
/// The deck is **position only**: a window is never resized to join it, so no application's
/// minimum size can distort a card and the deck never pays a size round trip — the expensive call,
/// at ~5.7 ms against 0.09–3.4 ms for a position write.
public enum Deck {
    // MARK: - The anchor

    /// What macOS leaves on screen of a window pushed past a corner of the desktop. Measured on a
    /// 1512 × 982 display: requesting (5000, 5000) for a 744 × 873 window lands it at (1472, 891);
    /// and on a 2560 × 1440 display, requesting (−5000, 1325) for a 1268 × 663 window lands it at
    /// (−1228, 1325), which is the same 40 pt seen from the other side. It is **independent of the
    /// window's size**, so the fan's shape needs no frame — only the anchor it hangs from does.
    public static let clampedSliver = CGSize(width: 40, height: 91)

    /// How much further onto the screen the deck's deepest card sits than the clamp would put it.
    ///
    /// **The deck is placed, never clamped, and that is deliberate.** The clamp is against the union
    /// of the displays, so leaning on it would put every deck in one corner of the desktop rather than
    /// on the phase's display. And if the fan were measured back
    /// from the clamp itself, a machine whose clamp is a little tighter than the one measured here —
    /// 20 pt tighter in y is enough — would clamp the first cards to one point, and cards resting on
    /// one point are not a fan. 24 pt clears the whole of that disagreement, so
    /// every position this type asks for is legal and is honoured exactly. It costs nothing but a
    /// slightly more generous sliver, which is more of the deck visible rather than less.
    public static let clampMargin: Double = 24

    /// Which way the bulk of a card leaves the phase's display on one axis.
    ///
    /// A card is never resized, so the only way to hide the body of a window is to put it where no
    /// display can draw it. `AXPosition` holds a window against the **union** of the displays and not
    /// against any one of them, so an overhang that reaches a neighbour is not clipped — it is simply
    /// visible over there. Measured on two 2560 × 1440 displays side by side: a card anchored at the
    /// left display's bottom-right corner shows a 1204 × 115 pt band of itself on the right one.
    public enum Spill: Sendable, Equatable, CaseIterable {
        /// Past the display's far edge — right, or bottom — because no display lies beyond it. The
        /// anchor is that edge, and the card's own size does not enter into it.
        case pastFar
        /// Past the near edge — left, or top. A window extends right and down from the origin
        /// Accessibility sets, so this anchor is measured back from the card's own size.
        case pastNear
        /// A display lies beyond both edges, so nothing may leave on this axis: the card is centred
        /// and kept whole on its display. A card longer than the display still reaches a neighbour,
        /// and only a resize could stop it — which the deck does not do.
        case none
    }

    /// Where a phase's cards rest: the display they were parked from, and the direction their bulk
    /// leaves it on each axis.
    ///
    /// **The deck belongs to the phase's display.** Only windows whose centre is on it are ever
    /// parked, so a card dealt anywhere else has been taken off a screen it never came from.
    ///
    /// Which corner the fan hangs from is not a preference but a consequence of the arrangement,
    /// because the bulk has to leave the desktop to stay hidden: past whichever edge has no display
    /// beyond it. On the left display of a pair the fan hangs from the bottom **left**; on the right
    /// display, from the bottom right; on a display hemmed in on both sides it hangs straight down
    /// from the bottom centre.
    public struct Placement: Sendable, Equatable {
        public let display: DisplayInfo
        public let horizontal: Spill
        public let vertical: Spill

        public init(display: DisplayInfo, horizontal: Spill, vertical: Spill) {
            self.display = display
            self.horizontal = horizontal
            self.vertical = vertical
        }

        /// The placement `display` gets in the arrangement it belongs to.
        ///
        /// A display blocks an axis only where it overlaps on the other one: two displays side by
        /// side block each other horizontally, one stacked above blocks vertically. Abutment is not
        /// required — a neighbour with a gap in front of it still draws whatever slides into it.
        public init(display: DisplayInfo, among displays: [DisplayInfo]) {
            let others = displays.filter { $0.id != display.id }
            let beside = others.filter {
                Swift.min(display.frame.maxY, $0.frame.maxY)
                    - Swift.max(display.frame.minY, $0.frame.minY) > 0
            }
            let stacked = others.filter {
                Swift.min(display.frame.maxX, $0.frame.maxX)
                    - Swift.max(display.frame.minX, $0.frame.minX) > 0
            }
            self.init(
                display: display,
                horizontal: Self.spill(far: beside.contains { $0.frame.maxX > display.frame.maxX },
                                       near: beside.contains { $0.frame.minX < display.frame.minX }),
                vertical: Self.spill(far: stacked.contains { $0.frame.maxY > display.frame.maxY },
                                     near: stacked.contains { $0.frame.minY < display.frame.minY }))
        }

        /// The far edge is preferred, so a lone display and the right-hand display of a pair both
        /// keep the bottom-right corner the deck has always used.
        private static func spill(far: Bool, near: Bool) -> Spill {
            if !far { return .pastFar }
            if !near { return .pastNear }
            return .none
        }

        /// Where card `index` of `count` rests, as a window **origin** in CG space.
        ///
        /// The card's size is what makes this per card: `slotOffset` is size-independent, but two of
        /// the three anchors it is measured from are not.
        public func slot(_ index: Int, of count: Int, size: CGSize) -> CGPoint {
            let offset = slotOffset(index, of: count)
            return CGPoint(
                x: place(horizontal, lo: display.frame.minX, hi: display.frame.maxX,
                         extent: size.width, sliver: clampedSliver.width, fan: offset.dx).rounded(),
                y: place(vertical, lo: display.frame.minY, hi: display.frame.maxY,
                         extent: size.height, sliver: clampedSliver.height, fan: offset.dy).rounded())
        }

        /// Every card's resting origin for a deck of identically sized cards, front of the deck first.
        public func slots(count: Int, size: CGSize) -> [CGPoint] {
            (0..<Swift.max(0, count)).map { slot($0, of: count, size: size) }
        }

        /// One axis of one card: the anchor its deepest card rests at, with the fan run back from it.
        private func place(_ spill: Spill, lo: Double, hi: Double,
                           extent: Double, sliver: Double, fan: Double) -> Double {
            switch spill {
            case .pastFar:
                return hi - sliver - clampMargin - fan
            case .pastNear:
                return lo + sliver + clampMargin - extent + fan
            case .none:
                // Nothing may leave, so the whole card stays on the display: centred, the fan still
                // running inward, and held inside what room is left over. A card longer than the
                // display has no room at all and is simply centred.
                let centred = (lo + hi - extent) / 2
                let deepest = hi - extent
                guard deepest > lo else { return centred }
                return Swift.min(Swift.max(lo, centred - fan), deepest)
            }
        }
    }

    // MARK: - The fan

    /// How far apart consecutive cards sit along the arc when the deck is small enough to afford it.
    public static let cardSpacing: Double = 14
    /// …and how close two cards may ever come to each other **on screen**. Below this the slivers stop
    /// being told apart; measured: about a dozen cards with ~10 pt of arc each before the corner is
    /// full.
    public static let minCardSeparation: Double = 8
    /// The floor the *spacing* is held at to deliver `minCardSeparation` after rounding. `slot` rounds
    /// both coordinates to whole points, which can move either of two cards by up to √2⁄2 pt, so two
    /// slots a bare `minCardSeparation` apart in the arithmetic can land 1.42 pt closer than that on
    /// screen. 2 pt of slack covers it with room to spare, and the alternative — asking for sub-point
    /// positions — would break the arrived-card skip that keeps a settled deck free.
    public static let spacingFloor: Double = minCardSeparation + 2
    /// How far the fan reaches before it stops spreading and starts compressing. A corner effect, not
    /// a second arrangement of the desktop.
    public static let fanRadius: Double = 200
    /// The arc, in degrees from "straight back along the screen's bottom edge" to "straight up its
    /// right edge". The cards near the top of the deck peek out sideways and the deep ones upwards,
    /// which is what makes the staggered edges read as a fan instead of a staircase.
    ///
    /// **There is no rotation in Accessibility.** Position and size are all it exposes, so the fan is
    /// an arc of offsets read edge-on and never a splayed hand. That is a platform limit.
    public static let fanStartAngle: Double = 10
    public static let fanEndAngle: Double = 72

    /// The gap between consecutive cards for a deck of this size: `cardSpacing` while the fan fits
    /// inside `fanRadius`, compressed to fit when it does not, and never below `spacingFloor` —
    /// a deck that would need to be tighter than that grows past `fanRadius` instead, because two
    /// cards nobody can tell apart are worse than a fan that reaches a little further.
    public static func spacing(count: Int) -> Double {
        guard count > 1 else { return cardSpacing }
        return max(spacingFloor, min(cardSpacing, fanRadius / Double(count - 1)))
    }

    /// How far card `index` is offset back from the corner, in points, both components ≥ 0.
    ///
    /// The radius grows by exactly one `spacing` per card and the angle is a function of that radius,
    /// which is what makes the fan's separation provable rather than plotted: by the triangle
    /// inequality any two cards are at least `|i − j| × spacing` apart, whatever the angles do.
    public static func slotOffset(_ index: Int, of count: Int) -> CGVector {
        guard index > 0 else { return .zero }
        let radius = Double(index) * spacing(count: count)
        let t = min(1, radius / fanRadius)
        let angle = (fanStartAngle + (fanEndAngle - fanStartAngle) * t) * .pi / 180
        return CGVector(dx: radius * cos(angle), dy: radius * sin(angle))
    }

    // MARK: - The ceiling

    /// How many of `count` cards `Settings.deckCeiling` allows to be animated. **Above the ceiling the
    /// deck is not attempted** — the overflow is moved straight to its place without animation, because
    /// a deck that stutters is worse than one that does not play. The ceiling is a measured default the
    /// user can move, not a constant.
    ///
    /// It is a ceiling by **count**, and it is the only one. `WindowWriter`'s mailboxes are what a deck
    /// too expensive to animate degrades through, one window at a time, rather than the whole deck
    /// shrinking because one window in it is a browser.
    public static func animatedCount(_ count: Int, ceiling: Int) -> Int {
        max(0, min(count, ceiling))
    }

    // MARK: - The record

    /// **Whether a refused write may throw this window's record away.** A window the app fails to move
    /// is not recorded and is left alone — and the converse, which is the whole of the safety property,
    /// is that a window that *has* moved must keep its record whatever happens to it afterwards,
    /// because that record is the only thing that knows where it belongs.
    ///
    /// Two conditions. `hasBeenWritten` is what the driver knows: whether it has moved this window
    /// during *this* journey. That is enough on the way out and worthless on the way back, where the
    /// driver starts a fresh journey and every card's first write looks like a first move — so a
    /// single refused write on the way home would delete the record of a window sitting in the corner,
    /// and nothing would be left that knew where it belonged. Comparing where the journey **starts**
    /// against where the record says the window **belongs** closes it without a flag anyone has to
    /// remember to set: on the way out they are the same point and this reduces to `!hasBeenWritten`;
    /// on the way back the journey starts at a deck slot and this is false however the driver's own
    /// bookkeeping was reset.
    ///
    /// The error direction is deliberate. Rounding, or a window that has drifted a point on its own,
    /// can only make this answer *false* — keeping a record that may not be needed, which restores a
    /// window to a frame it is already at. That is a no-op. The other direction loses a window.
    public static func mayForgetRecord(journeyStartsAt from: CGPoint, recordedHome home: CGPoint,
                                       hasBeenWritten: Bool) -> Bool {
        !hasBeenWritten && from == home
    }

    /// How far a window read back may be from a point and still count as standing on it.
    ///
    /// A card's journey ends in a `WindowWriter` flush, whose `landedFrame` is what the *application*
    /// says rather than what was asked for, and a window can be a point away from the position it was
    /// given — its own rounding, or the clamp that keeps it on the display. One point is below
    /// anything the eye reads as "not there" and above everything either of those can add.
    public static let arrivalTolerance: Double = 1

    /// Whether a window read back at `origin` counts as standing at `target`. Both axes, separately:
    /// a diagonal point of slack is still a point of slack on each axis.
    public static func arrived(at origin: CGPoint, target: CGPoint) -> Bool {
        abs(origin.x - target.x) <= arrivalTolerance && abs(origin.y - target.y) <= arrivalTolerance
    }

    /// When an overflow card — one past the deck's size, placed rather than animated — is written, in
    /// seconds after the deal begins.
    ///
    /// **They are placed over the length of the deal rather than all on the first frame.** An overflow
    /// card does not animate, so all of them landing on frame 0 means the corner is *full* before a
    /// single card that does animate has arrived in it, and the deal the user is watching plays into a
    /// pile that was already there. The first lands immediately, the last lands as the deal ends, and
    /// the corner fills up while the cards are still flying to it.
    ///
    /// Spread in **time** rather than over a fixed number of frames, so nothing here has to know the
    /// post rate.
    public static func overflowDelay(_ index: Int, of overflow: Int, deckOf count: Int,
                                     duration: Double) -> Double {
        guard overflow > 1 else { return 0 }
        let span = totalDuration(count: count, duration: duration)
        return span * Double(max(0, min(index, overflow - 1))) / Double(overflow - 1)
    }

    // MARK: - Timing

    /// How long apart two consecutive cards begin their journey, at most. A deck is *dealt*, one card
    /// after another, not slid across as a block — and a card that has not been dealt yet is a card
    /// this pass does not write, so the stagger spends nothing it does not earn.
    public static let dealStagger: Double = 0.03
    /// …and the whole deal never takes longer than this to get going, whatever the deck's size. It is
    /// added to the animation's own duration, so the longest a deck can take is
    /// `Settings.animationDuration` + this.
    public static let maxStagger: Double = 0.15

    /// When card `index` starts moving, in seconds after the deal begins.
    public static func delay(_ index: Int, of count: Int) -> Double {
        guard count > 1, index > 0 else { return 0 }
        let step = min(dealStagger, maxStagger / Double(count - 1))
        return Double(min(index, count - 1)) * step
    }

    /// How long the whole deal takes: the last card's turn plus its travel.
    public static func totalDuration(count: Int, duration: Double) -> Double {
        delay(max(0, count - 1), of: count) + max(0, duration)
    }

    /// Eased progress of card `index`, `elapsed` seconds into the deal. 0 before its turn, 1 once it
    /// has arrived — so a caller that keeps asking gets the settled answer rather than a wrong one.
    ///
    /// `AnimationCurve.easeInOut`, the same curve `SteppingSnapEngine` snaps a window with, so a card
    /// flying into the deck and a window flying into a cell look like one system.
    public static func progress(card index: Int, of count: Int, elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = (elapsed - delay(index, of: count)) / duration
        return AnimationCurve.easeInOut(t)
    }

    /// Where a card is at `progress`, rounded to whole points.
    ///
    /// Rounded because the deck compares a card's next position with the one it last **posted** and
    /// skips the post when they are equal: sub-point arithmetic would make that comparison never fire,
    /// and an Accessibility write that cannot move a window still costs a full round trip into the
    /// application (86 µs at best, 3.4 ms to a browser). `WindowWriter` keeps that round trip off this
    /// app's main thread; it does not make it free for the application paying it.
    public static func position(from: CGPoint, to: CGPoint, progress p: Double) -> CGPoint {
        CGPoint(x: (from.x + (to.x - from.x) * p).rounded(),
                y: (from.y + (to.y - from.y) * p).rounded())
    }
}
