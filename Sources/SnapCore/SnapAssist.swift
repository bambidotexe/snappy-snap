import CoreGraphics
import Foundation

/// Snap Assist's pure parts: which of a layout's cells a drop opens for arranging, and how the cards
/// are arranged inside one. Everything that needs Accessibility — which windows are eligible, their
/// titles and icons — stays in the app layer; this is the part that can be reasoned about and tested.
public enum SnapAssist {
    /// Every cell of `zone`'s layout except the one the drop filled: the areas a snap-bar drop opens
    /// for arranging, all presented at once. An empty result — a one-cell layout — means there is
    /// nothing to arrange and no phase.
    ///
    /// In the layout's own order, and nothing is filtered: a cell a window already sits in is offered
    /// like any other. There is no queue, so there is no order to read them in, and from the snap bar
    /// the user is redoing the whole arrangement, so nothing is pre-judged as settled.
    public static func otherZones(besides zone: Zone, display: DisplayInfo, gap: Double) -> [Zone] {
        zone.layout.cells.indices
            .filter { $0 != zone.cellIndex }
            .map { Geometry.zone(display: display, layout: zone.layout, cellIndex: $0, gap: gap) }
    }

    /// Where one area is drawn inside the surface that hosts every area of a display.
    ///
    /// Every area of a phase is drawn in **one** panel covering the display's visible frame, so an
    /// area's place in it is its own zone frame translated by that frame's origin. A translation and
    /// never a scale or a second measurement: the cards inside an area are measured against the zone
    /// and a click is hit-tested against the zone, and those two agree only while the area is drawn at
    /// exactly it.
    ///
    /// The result is in the panel's own space, whose y increases downward as CG's does — which is why
    /// the translation is the whole of it.
    public static func areaFrame(of zone: CGRect, inPanelCovering panel: CGRect) -> CGRect {
        CGRect(x: zone.minX - panel.minX, y: zone.minY - panel.minY,
               width: zone.width, height: zone.height)
    }
}

/// How the cards of one Snap Assist cell are arranged: the list runs along the cell's long axis, cards
/// shrink as more windows are offered, and a line that cannot hold them wraps into a grid. The block is
/// centred in the cell: the view fills the cell and places its cards from `blockOrigin`.
public struct SnapAssistCardLayout: Hashable, Sendable {
    /// A card at its most generous, and the size below which a card stops being readable.
    public static let maxSide: Double = 180
    public static let minSide: Double = 80
    public static let spacing: Double = 12
    /// Clearance between the block of cards and the cell's stroke.
    public static let padding: Double = 24

    /// True when the cards run left to right, which is what a *landscape* cell gets: the list runs
    /// along the cell's long axis. Everything else here is written in main/cross terms, so this one
    /// assignment is the rule. A square cell is not landscape and gets a column, which is as good an
    /// answer as the other.
    public var isHorizontal: Bool
    /// Cards on one line, and how many lines it takes — `perLine * lines >= count`.
    public var perLine: Int
    public var lines: Int
    /// Cards are square.
    public var side: Double
    public var spacing: Double
    /// The block of cards, to be centred in the cell.
    public var contentSize: CGSize

    public init(count: Int, cell: CGSize) {
        isHorizontal = cell.width > cell.height
        spacing = Self.spacing
        let mainRoom = (isHorizontal ? cell.width : cell.height) - 2 * Self.padding
        let crossRoom = (isHorizontal ? cell.height : cell.width) - 2 * Self.padding
        guard count > 0 else {
            perLine = 0
            lines = 0
            side = 0
            contentSize = .zero
            return
        }

        // The more options, the smaller the card — before the cell is even measured, so that a handful
        // of windows in a large cell still reads as a short list rather than as billboards.
        let cap = max(Self.minSide, min(Self.maxSide, Self.maxSide / Double(count).squareRoot()))
        var fit = Self.arrangement(count: count, side: cap, spacing: spacing, mainRoom: mainRoom)
        var chosen = cap
        // Then shrink, a point at a time, until the block fits the cell both ways. A cell too small
        // even for `minSide` cards keeps them at `minSide`: unreadable cards would help no one.
        while chosen > Self.minSide, !Self.fits(fit, side: chosen, spacing: spacing, mainRoom: mainRoom, crossRoom: crossRoom) {
            chosen -= 1
            fit = Self.arrangement(count: count, side: chosen, spacing: spacing, mainRoom: mainRoom)
        }
        side = chosen
        perLine = fit.perLine
        lines = fit.lines
        let main = Double(perLine) * side + Double(perLine - 1) * spacing
        let cross = Double(lines) * side + Double(lines - 1) * spacing
        contentSize = isHorizontal ? CGSize(width: main, height: cross) : CGSize(width: cross, height: main)
    }

    /// The top-left corner of the block of cards when it is centred in `cell`, horizontally and
    /// vertically.
    public func blockOrigin(in cell: CGRect) -> CGPoint {
        CGPoint(x: cell.midX - contentSize.width / 2, y: cell.midY - contentSize.height / 2)
    }

    /// Where card `index` sits inside the block, from the block's own top-left corner. `line` is a row
    /// when the list runs left to right and a column when it runs top to bottom; the place along that
    /// line is the other axis. The two swap with `isHorizontal`, the same flip `contentSize` makes.
    public func cardOffset(_ index: Int) -> CGPoint {
        guard perLine > 0 else { return .zero }
        let step = side + spacing
        let line = Double(index / perLine)
        let slot = Double(index % perLine)
        return CGPoint(x: (isHorizontal ? slot : line) * step, y: (isHorizontal ? line : slot) * step)
    }

    /// The frame of card `index` with the block centred in `cell`, in `cell`'s own space.
    ///
    /// This is the one piece of arithmetic that says where a card is: the view places its cards with
    /// it, and the app hit-tests clicks against it. They must not be two calculations that agree —
    /// a click that picks the wrong window, or none, is what a second copy of this would buy.
    ///
    /// Two properties of it are load-bearing for that, and both are unit-tested rather than assumed:
    ///
    /// - It reads nothing from `cell` but its **centre** (through `blockOrigin`), because the block's
    ///   size comes from the cell the layout was *measured* against. So the view may hand it the
    ///   panel's own bounds — which shrink by 4 % during the scale-in and would shrink again if
    ///   anything ever padded the grid — and still get the frame the controller computes from the
    ///   zone. Only a rect that is not concentric with the cell can move a card, and an off-centre
    ///   panel would draw its whole preview off-centre where anyone can see it.
    /// - It is **translation-equivariant**, which is what lets the view call it in the panel's local
    ///   space and the controller call it in global CG space and get the same card under the cursor.
    public func cardFrame(_ index: Int, in cell: CGRect) -> CGRect {
        let origin = blockOrigin(in: cell)
        let offset = cardOffset(index)
        return CGRect(x: origin.x + offset.x, y: origin.y + offset.y, width: side, height: side)
    }

    private static func arrangement(count: Int, side: Double, spacing: Double, mainRoom: Double) -> (perLine: Int, lines: Int) {
        let capacity = Int((mainRoom + spacing) / (side + spacing))
        let perLine = min(count, max(1, capacity))
        return (perLine, Int((Double(count) / Double(perLine)).rounded(.up)))
    }

    private static func fits(_ fit: (perLine: Int, lines: Int), side: Double, spacing: Double,
                             mainRoom: Double, crossRoom: Double) -> Bool {
        let main = Double(fit.perLine) * side + Double(fit.perLine - 1) * spacing
        let cross = Double(fit.lines) * side + Double(fit.lines - 1) * spacing
        return main <= mainRoom && cross <= crossRoom
    }
}

/// The card reflow, as something that can be read as well as played: when a pick takes a card out of
/// an area, the cards that stay **slide and grow into their new frames instead of jumping**.
/// For as long as that takes, a card is drawn at neither its old frame nor its new one — so a click
/// arriving in the middle of it can only be answered correctly by evaluating the same curve the view
/// is playing. The view builds its `Animation` from `curve` and `duration`; the controller's hit test
/// evaluates them. One curve, two readers, no lookalike to drift apart from.
public enum SnapAssistCardReflow {
    /// How long a card takes to reach its new place.
    public static let duration: Double = 0.22

    /// SwiftUI's `.easeOut`, written out as the control points it is made of. Written out rather than
    /// named because `.easeOut` cannot be evaluated: naming it in the view and approximating it here
    /// would be precisely the second copy this type exists to avoid.
    public static let curve = UnitBezier(0, 0, 0.58, 1)

    /// Eased progress 0…1, `elapsed` seconds into a reflow. 1 once the reflow is over, so a caller
    /// that forgets to check gets the settled answer rather than a wrong one.
    public static func progress(elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        return curve.solve(elapsed / duration)
    }

    /// Where a card that is travelling from `from` to `to` is drawn, `elapsed` seconds in. Position
    /// and size together: a shorter list means bigger cards, so a card that stays both moves and grows.
    public static func frame(from: CGRect, to: CGRect, elapsed: Double) -> CGRect {
        AnimationCurve.interpolate(from, to, progress: progress(elapsed: elapsed))
    }

    /// How far behind the animation the screen may be. What the user aimed at is the last frame the
    /// display presented, which is never the value the animation has reached: there is the frame
    /// being composited, the display's own refresh — 8 ms to 42 ms on this machine's variable-rate
    /// panel — and, before either, however long the run-loop turn that committed the change took.
    /// Measured here at between 20 and 70 ms by comparing the app's own arithmetic against the card
    /// frames Accessibility reports, which are themselves a lower bound on how far the drawing has
    /// got. 50 ms is the working figure; everything below is written so that being wrong about it
    /// costs a larger ignored band and never a wrong window.
    public static let lookBack: Double = 0.05

    /// The region a moving card may be **picked** in: everywhere it has been for the *whole* of the
    /// last `lookBack` seconds — and `nil` when there is no such place.
    ///
    /// The point of the intersection rather than the card's current frame is that the app cannot see
    /// its own pixels. It knows where a card is *computed* to be; what the user clicked is where the
    /// card was drawn, one unknown latency ago. A point inside this region was under this card at
    /// every instant the display could still be showing, so picking it is right whatever that latency
    /// turns out to be. A point the card has merely passed through, or has yet to reach, is genuinely
    /// ambiguous — it may be on the neighbour the user can see — and `SnapAssistController` ignores it
    /// rather than guessing. Guessing is how a click picks a window nobody pointed at, which is the
    /// whole defect this exists to remove; a click that does nothing for a fraction of a second, in a
    /// band a few points wide at the edge of a card that is visibly in motion, is the cheaper wrong.
    ///
    /// **Nil is not a corner case.** A card whose line changes crosses the whole of the line above it
    /// in the same 0.22 s — 554 pt in the built-in 2×2 cell as soon as eight windows are offered, so
    /// 192 pt inside `lookBack`, against a card 80 pt wide. There is then no point that was under it
    /// for the whole window, and the honest answer is that the app does not know where it is. The raw
    /// current frame is not that answer: it assumes a card cannot travel its own width in `lookBack`,
    /// which is false for every wrapped arrangement, and it is exactly the unprotected frame this type
    /// exists to replace.
    public static func pickFrame(from: CGRect, to: CGRect, elapsed: Double) -> CGRect? {
        let common = frame(from: from, to: to, elapsed: elapsed)
            .intersection(frame(from: from, to: to, elapsed: elapsed - lookBack))
        return common.isNull || common.isEmpty ? nil : common
    }

    /// Everywhere a moving card may be drawn at this instant. Where this covers a point, that card
    /// *may* be the one the user is looking at there, so no other card may claim it either: a card
    /// flying to another line passes over the cards it crosses, and while it does, neither it nor they
    /// can answer for the points underneath.
    ///
    /// Its frames across the latency window — except for a card that `pickFrame` cannot place at all,
    /// where the window has stopped bounding anything and the answer becomes **everywhere it has been
    /// since the reflow began**. That much is unconditional rather than calibrated: the screen can lag
    /// the animation by any amount, but it cannot run ahead of it, so a card has never been drawn
    /// anywhere it has not yet reached.
    ///
    /// It does not make a wrapped arrangement safe at *any* latency — nothing here can, because past
    /// `lookBack` the ordinary cards are mis-placed too — but it cuts what gets through by three to
    /// five times, measured, and it costs nothing whatsoever on an arrangement that does not wrap,
    /// where no card is ever unplaceable.
    public static func sweptFrame(from: CGRect, to: CGRect, elapsed: Double) -> CGRect {
        let now = frame(from: from, to: to, elapsed: elapsed)
        guard pickFrame(from: from, to: to, elapsed: elapsed) != nil else { return from.union(now) }
        return now.union(frame(from: from, to: to, elapsed: elapsed - lookBack))
    }

    /// Everything that moves while an area's list changes, and therefore everything a click must not
    /// be allowed to read as the backdrop: the block the cards are leaving, the block they are going
    /// to, and **wherever the cards actually are**.
    ///
    /// The last of those is why this takes frames and not just the two blocks. On a pick that
    /// interrupts a reflow the cards are part way between the two, and the two are concentric but of
    /// different aspect — narrower along the list, taller across it — so a card halfway between them
    /// sticks out of both by up to about 30 pt in the built-in 2×2 cell. A region derived from the
    /// counts alone misses exactly that strip, and a click on a card the user can plainly see falls
    /// through to the backdrop and cancels the arrangement.
    public static func movingRegion(cards: [CGRect], blocks: [CGRect]) -> CGRect {
        (cards + blocks).reduce(CGRect.null) { $0.union($1) }
    }

    /// Which of `targets` a click at `point` belongs to, or nil for "no card the app can name".
    ///
    /// Two conditions, and the second is the one a wrapped arrangement needs: the point must be in a
    /// card's pickable region, **and** no other card may be able to be drawn over it. Where two cards
    /// could both be under the cursor the app cannot tell which the user is looking at, and neither
    /// answers — that is the whole of the protection, since a card crossing to another line sweeps
    /// over cards that are otherwise perfectly placeable and would otherwise answer in its place.
    ///
    /// At rest this is exactly "the card the point is inside": the frames are disjoint, so at most one
    /// can contain it and its swept region is itself.
    public static func card(at point: CGPoint, among targets: [SnapAssistCardTarget]) -> Int? {
        var only: Int?
        for (index, target) in targets.enumerated() where target.swept.contains(point) {
            if only != nil { return nil }
            only = index
        }
        guard let only, let pickable = targets[only].pickable, pickable.contains(point) else { return nil }
        return only
    }
}

/// What one card looks like to a hit test at one instant: where a click counts as it, and everywhere
/// it might be. The two differ only while it is moving, and the difference is the display's latency.
public struct SnapAssistCardTarget: Hashable, Sendable {
    /// Where a click counts as this card, or nil when it is moving too fast to be placed at all.
    public let pickable: CGRect?
    /// Everywhere it may be drawn right now — the region no *other* card may claim.
    public let swept: CGRect

    /// A card at rest. It is where it is, and there is nothing to allow for.
    public init(settled: CGRect) {
        pickable = settled
        swept = settled
    }

    /// A card `elapsed` seconds into a reflow from `from` to `to`.
    public init(from: CGRect, to: CGRect, elapsed: Double) {
        pickable = SnapAssistCardReflow.pickFrame(from: from, to: to, elapsed: elapsed)
        swept = SnapAssistCardReflow.sweptFrame(from: from, to: to, elapsed: elapsed)
    }
}
