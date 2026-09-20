import Testing
import CoreGraphics
@testable import SnapCore

/// A snap-bar drop opens every other cell of its layout at
/// once, unfiltered and in no particular order.
@Suite struct SnapAssistAreaTests {
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 625),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 600))

    private func zone(_ layout: Layout, _ index: Int, gap: Double = 8) -> Zone {
        Geometry.zone(display: display, layout: layout, cellIndex: index, gap: gap)
    }

    /// A 2×2 whose cells are *stored* bottom-right, top-left, top-right, bottom-left. The areas
    /// come back in the order the layout stores them, because with every area on screen at once
    /// there is no order to read them in.
    let scrambled = Layout(id: "scrambled", cells: [
        UnitRect(0.5, 0.5, 0.5, 0.5),
        UnitRect(0, 0, 0.5, 0.5),
        UnitRect(0.5, 0, 0.5, 0.5),
        UnitRect(0, 0.5, 0.5, 0.5),
    ])

    @Test func everyCellButTheDropsIsOffered() {
        let areas = SnapAssist.otherZones(besides: zone(LayoutCatalog.grid2x2, 2), display: display, gap: 8)
        #expect(areas.map(\.cellIndex) == [0, 1, 3])
        // The frames are the ones the resolver would produce for those cells, gap included.
        #expect(areas.map(\.frame) == [0, 1, 3].map { zone(LayoutCatalog.grid2x2, $0).frame })
    }

    @Test func theAreasComeBackInTheLayoutsOwnOrder() {
        let areas = SnapAssist.otherZones(besides: zone(scrambled, 1), display: display, gap: 8)
        #expect(areas.map(\.cellIndex) == [0, 2, 3])
    }

    @Test func aSingleCellLayoutHasNothingToArrange() {
        #expect(SnapAssist.otherZones(besides: zone(LayoutCatalog.fill, 0), display: display, gap: 8).isEmpty)
    }

    @Test(arguments: [0.0, 8.0, 24.0])
    func theGapIsApplied(gap: Double) throws {
        let areas = SnapAssist.otherZones(besides: zone(LayoutCatalog.halves, 0, gap: gap), display: display, gap: gap)
        // `try #require`, not `#expect`: `#expect` does not abort, so a wrong count here would reach
        // the subscript below and trap — and a crashed test target prints no summary line at all.
        let only = try #require(areas.count == 1 ? areas.first : nil)
        #expect(only.frame == Geometry.frame(for: LayoutCatalog.halves.cells[1], in: display.visibleFrame, gap: gap))
    }

    @Test func everyLayoutOffersOneAreaPerCellItDidNotFill() {
        for layout in LayoutCatalog.snapBar {
            for filled in layout.cells.indices {
                let areas = SnapAssist.otherZones(besides: zone(layout, filled), display: display, gap: 8)
                #expect(areas.count == layout.cells.count - 1, "\(layout.id)[\(filled)]")
                #expect(!areas.contains { $0.cellIndex == filled }, "\(layout.id)[\(filled)]")
            }
        }
    }
}

/// Every area of a phase is drawn in one surface covering the display's visible frame, so where an
/// area goes inside it is a translation of its zone and nothing else.
@Suite struct SnapAssistAreaFrameTests {
    let panel = CGRect(x: 0, y: 25, width: 1000, height: 600)

    @Test func anAreaIsItsZoneTranslatedByTheSurfacesOrigin() {
        let zone = CGRect(x: 8, y: 33, width: 484, height: 584)
        #expect(SnapAssist.areaFrame(of: zone, inPanelCovering: panel)
                == CGRect(x: 8, y: 8, width: 484, height: 584))
    }

    @Test func anAreaAtTheSurfacesOwnCornerLandsAtItsOrigin() {
        #expect(SnapAssist.areaFrame(of: panel, inPanelCovering: panel)
                == CGRect(x: 0, y: 0, width: panel.width, height: panel.height))
    }

    /// A display away from the origin is the case a translation exists for: the second display's
    /// zones carry its own offset, and the surface planted on it cancels exactly that much.
    @Test func aSecondDisplaysAreasAreMeasuredFromItsOwnSurface() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let zone = CGRect(x: 1520, y: 8, width: 952, height: 1039)
        #expect(SnapAssist.areaFrame(of: zone, inPanelCovering: second)
                == CGRect(x: 8, y: 8, width: 952, height: 1039))
    }

    /// Never a scale: an area is drawn at the size the cards were measured against and a click is
    /// hit-tested against, so a surface of any size leaves it alone.
    @Test(arguments: [CGRect(x: 0, y: 0, width: 400, height: 300),
                      CGRect(x: -800, y: -200, width: 3000, height: 2000)])
    func theSizeIsTheZonesWhateverTheSurface(surface: CGRect) {
        let zone = CGRect(x: 10, y: 20, width: 123.5, height: 456.25)
        let frame = SnapAssist.areaFrame(of: zone, inPanelCovering: surface)
        #expect(frame.size == zone.size)
    }
}

@Suite struct SnapAssistCardLayoutTests {
    let landscape = CGSize(width: 800, height: 500)
    let portrait = CGSize(width: 400, height: 900)

    /// Along the long axis, not across it. Both directions are
    /// asserted, so the rule cannot pass by halves.
    @Test func theListRunsAlongTheCellsLongAxis() {
        #expect(SnapAssistCardLayout(count: 3, cell: landscape).isHorizontal)
        #expect(!SnapAssistCardLayout(count: 3, cell: portrait).isHorizontal)
    }

    /// The block the view centres follows the same flip, which is the half of the rule the eye
    /// actually sees: a wide cell gets a wide block, and it still fits the room it is centred in.
    @Test func theBlockRunsTheSameWayAsTheList() {
        let wide = SnapAssistCardLayout(count: 4, cell: landscape)
        #expect(wide.perLine == 4 && wide.lines == 1)
        #expect(wide.contentSize.width > wide.contentSize.height)
        #expect(wide.contentSize.width <= landscape.width - 2 * SnapAssistCardLayout.padding)
        #expect(wide.contentSize.height <= landscape.height - 2 * SnapAssistCardLayout.padding)

        let tall = SnapAssistCardLayout(count: 4, cell: portrait)
        #expect(tall.perLine == 4 && tall.lines == 1)
        #expect(tall.contentSize.height > tall.contentSize.width)
        #expect(tall.contentSize.width <= portrait.width - 2 * SnapAssistCardLayout.padding)
        #expect(tall.contentSize.height <= portrait.height - 2 * SnapAssistCardLayout.padding)
    }

    @Test func oneCardIsOneLine() {
        let layout = SnapAssistCardLayout(count: 1, cell: landscape)
        #expect(layout.perLine == 1)
        #expect(layout.lines == 1)
        #expect(layout.side == SnapAssistCardLayout.maxSide)
    }

    @Test func noCardsIsAnEmptyBlock() {
        let layout = SnapAssistCardLayout(count: 0, cell: landscape)
        #expect(layout.perLine == 0)
        #expect(layout.lines == 0)
        #expect(layout.contentSize == .zero)
    }

    @Test func moreOptionsNeverMeansBiggerCards() {
        var previous = Double.infinity
        for count in 1...12 {
            let side = SnapAssistCardLayout(count: count, cell: landscape).side
            #expect(side <= previous, "count \(count)")
            previous = side
        }
        #expect(SnapAssistCardLayout(count: 12, cell: landscape).side < SnapAssistCardLayout(count: 2, cell: landscape).side)
    }

    @Test func cardsNeverShrinkBelowTheReadableMinimum() {
        // A cell far too small for the block: the cards stop at `minSide` rather than vanishing.
        let layout = SnapAssistCardLayout(count: 20, cell: CGSize(width: 200, height: 160))
        #expect(layout.side == SnapAssistCardLayout.minSide)
        #expect(layout.perLine >= 1)
        #expect(layout.lines * layout.perLine >= 20)
    }

    @Test(arguments: [1, 2, 3, 4, 6, 8, 10])
    func theBlockFitsInsideTheCell(count: Int) {
        for cell in [landscape, portrait] {
            let layout = SnapAssistCardLayout(count: count, cell: cell)
            let room = CGSize(width: cell.width - 2 * SnapAssistCardLayout.padding,
                              height: cell.height - 2 * SnapAssistCardLayout.padding)
            #expect(layout.contentSize.width <= room.width + 1e-9, "\(count) in \(cell)")
            #expect(layout.contentSize.height <= room.height + 1e-9, "\(count) in \(cell)")
        }
    }

    @Test(arguments: [1, 2, 3, 5, 7, 11, 16])
    func everyCardHasAPlaceInTheGrid(count: Int) {
        for cell in [landscape, portrait, CGSize(width: 300, height: 300)] {
            let layout = SnapAssistCardLayout(count: count, cell: cell)
            #expect(layout.perLine * layout.lines >= count, "\(count) in \(cell)")
            // …and no line is left empty: dropping one line would no longer hold them.
            #expect(layout.perLine * (layout.lines - 1) < count, "\(count) in \(cell)")
        }
    }

    @Test func aLineThatCannotHoldThemWrapsIntoAGrid() {
        // Eight cards along a 500 pt long axis cannot sit on one line at a readable size: 8 × 80 pt
        // plus seven 12 pt gaps is 724, against 452 pt of room.
        let layout = SnapAssistCardLayout(count: 8, cell: CGSize(width: 500, height: 400))
        #expect(layout.lines > 1)
        #expect(layout.perLine < 8)
    }

    /// `cardFrame` is what the app hit-tests a click with and what the view places the cards at, so
    /// these are not decoration: a card drawn anywhere other than where a click on it is expected to
    /// land is a click that picks the wrong window, or none.
    let cell = CGRect(x: 100, y: 200, width: 800, height: 500)

    @Test func theBlockIsCentredInTheCell() {
        let layout = SnapAssistCardLayout(count: 5, cell: cell.size)
        let origin = layout.blockOrigin(in: cell)
        let block = CGRect(origin: origin, size: layout.contentSize)
        #expect(abs(block.midX - cell.midX) < 1e-9)
        #expect(abs(block.midY - cell.midY) < 1e-9)
        #expect(cell.contains(block))
    }

    /// A second cell, small enough that the same counts wrap onto several lines: in `cell` every one
    /// of these arguments fits on one line, so the properties below — containment, non-overlap, one
    /// card per point — were never being asserted across a wrap, a partly-filled last line, or a count
    /// that exactly fills a line. They decide which window a click picks, so they are asserted in both.
    let wrapping = CGRect(x: -40, y: 60, width: 500, height: 400)

    @Test(arguments: [1, 2, 3, 5, 8])
    func everyCardSitsInTheBlockAndNowhereNearAnother(count: Int) {
        for cell in [cell, wrapping] {
            let layout = SnapAssistCardLayout(count: count, cell: cell.size)
            let block = CGRect(origin: layout.blockOrigin(in: cell), size: layout.contentSize)
            let frames = (0..<count).map { layout.cardFrame($0, in: cell) }
            for (index, frame) in frames.enumerated() {
                #expect(Double(frame.width) == layout.side && Double(frame.height) == layout.side)
                // A tolerance on containment only, for the halving in `blockOrigin`.
                #expect(block.insetBy(dx: -1e-9, dy: -1e-9).contains(frame), "card \(index) of \(count) in \(cell)")
                for (other, otherFrame) in frames.enumerated() where other != index {
                    #expect(!frame.intersects(otherFrame), "cards \(index) and \(other) of \(count) in \(cell)")
                }
            }
        }
    }

    /// **The property the view rests on, and the only one that can put a click somewhere the card is
    /// not.** `cardFrame` reads nothing from the rect it is handed but its centre, so every rect with
    /// the same centre produces the same cards: the panel scaling in from a 4 % inset, a padding
    /// someone adds around the grid, a shadow inset. `SnapAssistCardGrid` calls this with the panel's
    /// own bounds while `SnapAssistController` calls it with the zone — if the block's origin ever
    /// stopped being derived from the centre, the drawing and the hit test would part company with
    /// nothing on screen to show it. This is the test that fails first.
    @Test(arguments: [1, 3, 6, 9])
    func aConcentricRectPlacesEveryCardIdentically(count: Int) {
        for cell in [cell, wrapping] {
            let layout = SnapAssistCardLayout(count: count, cell: cell.size)
            // The scale-in's own inset, an asymmetric one with the same centre, and one that grows.
            for inset in [CGSize(width: cell.width * 0.04, height: cell.height * 0.04),
                          CGSize(width: 37, height: 11), CGSize(width: -24, height: -24)] {
                let other = cell.insetBy(dx: inset.width, dy: inset.height)
                #expect(abs(other.midX - cell.midX) < 1e-9 && abs(other.midY - cell.midY) < 1e-9)
                for index in 0..<count {
                    #expect(layout.cardFrame(index, in: other) == layout.cardFrame(index, in: cell),
                            "card \(index) of \(count) in \(cell) inset by \(inset)")
                }
            }
        }
    }

    /// The other half of the same coupling: the view measures in the panel's local space, where the
    /// cell starts at the origin, and the controller measures in global CG space, where it starts at
    /// the zone. They can only be the same function if moving the cell moves every card with it.
    @Test(arguments: [1, 4, 7]) func cardsTranslateWithTheCellTheyAreMeasuredIn(count: Int) {
        for cell in [cell, wrapping] {
            let layout = SnapAssistCardLayout(count: count, cell: cell.size)
            let local = CGRect(origin: .zero, size: cell.size)
            for index in 0..<count {
                let moved = layout.cardFrame(index, in: local)
                    .offsetBy(dx: cell.minX, dy: cell.minY)
                #expect(moved == layout.cardFrame(index, in: cell), "card \(index) of \(count) in \(cell)")
            }
        }
    }

    @Test func consecutiveCardsAreExactlyOneSpacingApartAlongTheList() {
        let wide = SnapAssistCardLayout(count: 3, cell: landscape)
        let first = wide.cardFrame(0, in: CGRect(origin: .zero, size: landscape))
        let second = wide.cardFrame(1, in: CGRect(origin: .zero, size: landscape))
        // `Double(...)` on both sides throughout: `#expect` boxes a CGFloat and a Double
        // separately and reports 12.0 == 12.0 as false (the same trap as in the parking suite).
        #expect(Double(second.minX - first.maxX) == wide.spacing)
        #expect(second.minY == first.minY)

        let tall = SnapAssistCardLayout(count: 3, cell: portrait)
        let top = tall.cardFrame(0, in: CGRect(origin: .zero, size: portrait))
        let below = tall.cardFrame(1, in: CGRect(origin: .zero, size: portrait))
        #expect(Double(below.minY - top.maxY) == tall.spacing)
        #expect(below.minX == top.minX)
    }

    @Test func awrappedCardStartsTheNextLine() {
        // A cell that forces two lines (the wrap test's cell), so the card at `perLine` is the one
        // that has to move across the block rather than continue along it.
        let small = CGSize(width: 500, height: 400)
        let layout = SnapAssistCardLayout(count: 8, cell: small)
        let area = CGRect(origin: .zero, size: small)
        #expect(layout.lines > 1)
        let first = layout.cardFrame(0, in: area)
        let wrapped = layout.cardFrame(layout.perLine, in: area)
        // Landscape cell ⇒ the list runs left to right and wraps downward.
        #expect(wrapped.minX == first.minX)
        #expect(Double(wrapped.minY - first.maxY) == layout.spacing)
    }

    @Test func theCentreOfACardIsInThatCardAndNoOther() {
        // Both cells: six cards fit on one line in `cell` and wrap onto two in `wrapping`, and a
        // click has to be unambiguous in either.
        for cell in [cell, wrapping] {
            let layout = SnapAssistCardLayout(count: 6, cell: cell.size)
            let frames = (0..<6).map { layout.cardFrame($0, in: cell) }
            for (index, frame) in frames.enumerated() {
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                #expect(frame.contains(centre))
                #expect(frames.filter { $0.contains(centre) }.count == 1, "card \(index) in \(cell)")
            }
            // …and the gap between two cards belongs to no card at all, which is what makes it a
            // cancel. Taken along the list, so it is a gap on both arrangements.
            let between = CGPoint(x: (frames[0].midX + frames[1].midX) / 2,
                                  y: (frames[0].midY + frames[1].midY) / 2)
            #expect(!frames.contains { $0.contains(between) }, "\(cell)")
        }
    }

    @Test func theBlockIsSquareEnoughToCentre() {
        // `contentSize` is exactly the cards plus the spacings between them — the view centres that.
        let layout = SnapAssistCardLayout(count: 6, cell: landscape)
        let main = Double(layout.perLine) * layout.side + Double(layout.perLine - 1) * layout.spacing
        let cross = Double(layout.lines) * layout.side + Double(layout.lines - 1) * layout.spacing
        #expect(layout.contentSize == CGSize(width: main, height: cross))  // landscape ⇒ horizontal list
    }
}

/// The reflow is read rather than played. A click that arrives while the cards are moving is
/// answered against these frames, so "where is card 2 right now" is a question with one answer and the
/// view and the controller both have to get it.
@Suite struct SnapAssistCardReflowTests {
    let cell = CGRect(x: 760, y: 41, width: 744, height: 433)

    @Test func nothingHasMovedAtTheStartAndEverythingHasArrivedAtTheEnd() {
        let from = SnapAssistCardLayout(count: 3, cell: cell.size).cardFrame(1, in: cell)
        let to = SnapAssistCardLayout(count: 2, cell: cell.size).cardFrame(0, in: cell)
        #expect(SnapAssistCardReflow.frame(from: from, to: to, elapsed: 0) == from)
        #expect(SnapAssistCardReflow.frame(from: from, to: to, elapsed: SnapAssistCardReflow.duration) == to)
        // Past the end, and before the beginning: the settled answer, never an extrapolated one.
        #expect(SnapAssistCardReflow.frame(from: from, to: to, elapsed: 10) == to)
        #expect(SnapAssistCardReflow.frame(from: from, to: to, elapsed: -1) == from)
    }

    /// A card that stays both moves and grows — a shorter list means bigger cards — so the size has to
    /// travel with the position. Hit-testing a moving card at its final size would be a click that
    /// lands on nothing near the edges for the whole animation.
    @Test func aCardTravelsAtItsOwnSizeAndInOneDirection() {
        let from = SnapAssistCardLayout(count: 3, cell: cell.size).cardFrame(1, in: cell)
        let to = SnapAssistCardLayout(count: 2, cell: cell.size).cardFrame(0, in: cell)
        #expect(to.width > from.width)   // fewer cards, bigger cards: the case worth pinning
        #expect(to.minX < from.minX)
        var last = from
        for step in 1...22 {
            let now = SnapAssistCardReflow.frame(from: from, to: to, elapsed: Double(step) / 100)
            #expect(now.minX <= last.minX + 1e-9, "step \(step)")
            #expect(now.width >= last.width - 1e-9, "step \(step)")
            #expect(now.minX >= to.minX - 1e-9 && now.minX <= from.minX + 1e-9, "step \(step)")
            last = now
        }
        #expect(last == to)
    }

    /// The app cannot see
    /// its own pixels: it knows where a card is *computed* to be, and the click it is answering was
    /// aimed at where the card was *drawn*, one unknown latency ago. So a click that resolves to a card
    /// has to be a click on **that** card as drawn, for every latency in the range allowed for — or on
    /// nothing at all. Never on a different card.
    ///
    /// Sampled over the block on a grid, at every stage of the reflow, at latencies across the
    /// whole window — and over **wrapped** arrangements as well as single-line ones: eight
    /// windows in the built-in 2×2 cell send one card 554 pt in 0.22 s, which is 192 pt inside
    /// the latency window against a card 80 pt wide.
    @Test(arguments: [3, 4, 6, 8, 9, 11])
    func aClickNeverResolvesToACardThatIsNotUnderIt(count: Int) {
        let travels = reflow(of: count)
        let block = travels.reduce(CGRect.null) { $0.union($1.0).union($1.1) }
        let lags = stride(from: 0.0, through: SnapAssistCardReflow.lookBack, by: 0.0125).map { $0 }
        var wrong = 0
        var worst = ""
        for step in 0...11 {
            let elapsed = Double(step) * 0.025
            let targets = travels.map { SnapAssistCardTarget(from: $0.0, to: $0.1, elapsed: elapsed) }
            // The arrangement as the screen may be showing it, once per latency, computed outside the
            // point loop: this test is a sweep, not a spot check.
            let drawnPerLag = lags.map { lag in
                travels.map { SnapAssistCardReflow.frame(from: $0.0, to: $0.1, elapsed: elapsed - lag) }
            }
            for x in stride(from: block.minX, through: block.maxX, by: 6) {
                for y in stride(from: block.minY, through: block.maxY, by: 6) {
                    let point = CGPoint(x: x, y: y)
                    guard let picked = SnapAssistCardReflow.card(at: point, among: targets) else { continue }
                    for drawn in drawnPerLag {
                        for (index, frame) in drawn.enumerated()
                        where index != picked && frame.contains(point) {
                            wrong += 1
                            if worst.isEmpty {
                                worst = "count \(count), elapsed \(elapsed), \(point): resolved to card "
                                    + "\(picked) while card \(index) is drawn there"
                            }
                        }
                    }
                }
            }
        }
        #expect(wrong == 0, "\(wrong) points resolve to the wrong card — first: \(worst)")
    }

    /// And once the cards have arrived there is no allowance left, so the rules at rest — a card
    /// picks, the gap between two cards cancels — come back exactly as they were.
    @Test func afterTheReflowThePickableRegionIsTheCard() {
        let (from, to) = reflow(of: 4)[0]
        let over = SnapAssistCardReflow.duration + SnapAssistCardReflow.lookBack
        #expect(SnapAssistCardReflow.pickFrame(from: from, to: to, elapsed: over) == to)
        #expect(SnapAssistCardReflow.pickFrame(from: from, to: to, elapsed: over + 1) == to)
        // …and a card at rest is pickable exactly where it is drawn — the ordinary rule,
        // unaffected by the reflow machinery.
        let settled = SnapAssistCardTarget(settled: to)
        #expect(settled.pickable == to && settled.swept == to)
    }

    /// The travels of a pick that takes the first card: survivor j had index j + 1 and is going to j.
    private func reflow(of count: Int) -> [(CGRect, CGRect)] {
        let before = SnapAssistCardLayout(count: count, cell: cell.size)
        let after = SnapAssistCardLayout(count: count - 1, cell: cell.size)
        return (0..<(count - 1)).map { (before.cardFrame($0 + 1, in: cell), after.cardFrame($0, in: cell)) }
    }

    /// A single-line pick keeps every card placeable throughout — the safety above must not have been
    /// bought by making the ordinary case unclickable. The pickable strip is a real share of the card
    /// at every stage, and no two of them ever share a point.
    @Test(arguments: [2, 3, 4, 6]) func aSingleLinePickLeavesEveryCardPickable(count: Int) {
        // These counts keep their arrangement on one line across the pick; the wrapped case is below.
        #expect(SnapAssistCardLayout(count: count, cell: cell.size).lines
                == SnapAssistCardLayout(count: count - 1, cell: cell.size).lines)
        let travels = reflow(of: count)
        for step in 0...30 {
            let elapsed = Double(step) / 100
            let targets = travels.map { SnapAssistCardTarget(from: $0.0, to: $0.1, elapsed: elapsed) }
            for (index, target) in targets.enumerated() {
                guard let pickable = target.pickable else {
                    #expect(Bool(false), "card \(index) of \(count) is unplaceable at \(elapsed)")
                    continue
                }
                let drawn = SnapAssistCardReflow.frame(from: travels[index].0, to: travels[index].1, elapsed: elapsed)
                // Two thirds of the card, at worst, and the centre is always in it: a click aimed at a
                // card rather than at its edge always lands.
                #expect(pickable.width >= drawn.width * 0.6 && pickable.height >= drawn.height * 0.6,
                        "card \(index) of \(count) at \(elapsed): \(pickable) of \(drawn)")
                #expect(pickable.contains(CGPoint(x: drawn.midX, y: drawn.midY)))
                for (other, otherTarget) in targets.enumerated() where other != index {
                    #expect(!pickable.intersects(otherTarget.pickable ?? .null),
                            "cards \(index) and \(other) of \(count) at \(elapsed)")
                }
            }
        }
    }

    /// **The residual, pinned so nobody mistakes it for fixed.** A list that loses a line sends the
    /// card that was alone on the second line all the way across the first. It moves several times its
    /// own width inside the latency window, so there is no point that was under it throughout and it is
    /// not placeable at all for most of the reflow: during those milliseconds that card cannot be
    /// picked, and neither can the cards it is flying over. Ignored, never mis-attributed — which is
    /// what the sweep above asserts and what this one measures the cost of.
    @Test func aCardCrossingToAnotherLineIsNotPlaceableAndBlocksTheCardsItCrosses() {
        #expect(SnapAssistCardLayout(count: 8, cell: cell.size).lines == 2)
        #expect(SnapAssistCardLayout(count: 7, cell: cell.size).lines == 1)
        let travels = reflow(of: 8)
        // The crossing card is the last of the new list: old index 7 was alone on line 2.
        let crossing = travels.count - 1
        #expect(travels[crossing].0.minY > travels[crossing].1.minY)   // it really does come up a line
        var unplaceable = 0
        var blocked = 0
        for step in 0...22 {
            let elapsed = Double(step) / 100
            let targets = travels.map { SnapAssistCardTarget(from: $0.0, to: $0.1, elapsed: elapsed) }
            if targets[crossing].pickable == nil { unplaceable += 1 }
            // Its path covers cards that would otherwise be perfectly placeable, and those points
            // resolve to nothing rather than to whatever is underneath.
            for (index, target) in targets.enumerated() where index != crossing {
                let drawn = SnapAssistCardReflow.frame(from: travels[index].0, to: travels[index].1, elapsed: elapsed)
                let centre = CGPoint(x: drawn.midX, y: drawn.midY)
                if targets[crossing].swept.contains(centre) {
                    blocked += 1
                    #expect(SnapAssistCardReflow.card(at: centre, among: targets) == nil,
                            "card \(index) at \(elapsed) is under the crossing card and still answered")
                    _ = target
                }
            }
        }
        // Both numbers are the shape of the residual, not a target: most of the reflow for the card
        // itself, and a handful of card-instants for the ones it passes over.
        #expect(unplaceable > 10, "\(unplaceable) of 23 samples unplaceable")
        #expect(blocked > 0, "the crossing card covered no other card's centre at any sample")
    }

    /// **The region a click may not read as the backdrop follows the cards, not the counts.** On a
    /// pick that interrupts a reflow the cards are part way between two blocks that are concentric but
    /// of different aspect, and a card halfway between them sticks out of both. A region derived
    /// from the two counts alone would miss exactly that strip, so a click on a card the user
    /// could plainly see would fall through and cancel the whole arrangement.
    @Test func theMovingRegionIsTakenFromTheCardsAndNotFromTheCounts() {
        // A second pick landing 40 ms into the first reflow: the cards are between the 4-card and the
        // 3-card arrangements, and the counts it sees are 3 and 2.
        let midFlight = reflow(of: 4).map { SnapAssistCardReflow.frame(from: $0.0, to: $0.1, elapsed: 0.04) }
        let blocks = [3, 2].map { count -> CGRect in
            let layout = SnapAssistCardLayout(count: count, cell: cell.size)
            return CGRect(origin: layout.blockOrigin(in: cell), size: layout.contentSize)
        }
        let fromCounts = blocks[0].union(blocks[1])
        #expect(midFlight.contains { !fromCounts.contains($0) },
                "the counts happen to cover the cards here, so this test proves nothing")
        let region = SnapAssistCardReflow.movingRegion(cards: midFlight, blocks: blocks)
        for (index, frame) in midFlight.enumerated() {
            #expect(region.contains(frame), "card \(index) at \(frame) is outside \(region)")
        }
        // A *first* pick is unchanged by any of this: its cards are the settled old arrangement, which
        // is inside its own block, so taking the frames into account adds nothing at all.
        let old = SnapAssistCardLayout(count: 4, cell: cell.size)
        let oldBlock = CGRect(origin: old.blockOrigin(in: cell), size: old.contentSize)
        let settled = (0..<4).map { old.cardFrame($0, in: cell) }
        #expect(SnapAssistCardReflow.movingRegion(cards: settled, blocks: [oldBlock, blocks[0]])
                == oldBlock.union(blocks[0]))
    }

    /// Ease-out, so most of the travel is over early: half way through the 0.22 s the card is already
    /// most of the way there. This is the assertion that would fail if the curve were swapped for a
    /// linear one — which is what a hit test that "interpolates" without the curve would be doing.
    @Test func mostOfTheTravelHappensEarly() {
        #expect(SnapAssistCardReflow.progress(elapsed: 0) == 0)
        #expect(SnapAssistCardReflow.progress(elapsed: SnapAssistCardReflow.duration) == 1)
        let half = SnapAssistCardReflow.progress(elapsed: SnapAssistCardReflow.duration / 2)
        #expect(half > 0.65 && half < 0.72)
    }
}
