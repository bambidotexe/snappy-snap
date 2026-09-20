import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct SnapBarGeometryTests {
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800))
    /// A second display to the right whose top edge is 200 pt *above* the primary's, so every
    /// display-relative term differs from its absolute-zero twin.
    let secondary = DisplayInfo(id: 2, frame: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 1440, y: -175, width: 1920, height: 1055))
    /// Defaults: the gap on (8, which the bar's top inset follows) and the fixed 24 pt edge band.
    var g: SnapBarGeometry { bar() }

    /// The same bar with the conditional pair cell in front of the four layouts.
    var paired: SnapBarGeometry { bar(pairing: true) }

    func bar(gapEnabled: Bool = true, on display: DisplayInfo? = nil, pairing: Bool = false) -> SnapBarGeometry {
        var s = Settings()
        s.snapBarAppearance = .bar
        s.gapEnabled = gapEnabled
        let display = display ?? self.display
        return SnapBarGeometry(layouts: LayoutCatalog.snapBar, display: display, settings: s,
                               pairCell: PairCell(hasPartner: pairing, display: display, gap: s.gap))
    }

    @Test func frameIsCenteredUnderTheMenuBar() {
        // 12 + 4×96 + 3×8 + 12 = 432 wide, 12 + 64 + 12 = 88 tall; centered on 1440 → minX 720 − 216 = 504;
        // top = visibleFrame.minY 25 + topInset(8 + 3 + 8) = 44.
        #expect(g.frame == CGRect(x: 504, y: 44, width: 432, height: 88))
    }

    @Test func cellsAreLaidOutLeftToRight() {
        // 44 + padding 12 = 56.
        #expect(g.cellRect(0) == CGRect(x: 516, y: 56, width: 96, height: 64))
        // 516 + cell 96 + spacing 8. One literal, not a sum: a compound integer expression defaults to
        // Int here and `CGFloat == Int` resolves through AnyHashable, which is false whatever the numbers.
        #expect(g.cellRect(1).minX == 620)
        #expect(g.localCellRect(0) == CGRect(x: 12, y: 12, width: 96, height: 64))
    }

    /// The two bands the eye reads at the top of the screen —
    /// menu bar to the preview's stroke, and that stroke to the bar — must be the same height, at any
    /// gap. The stroke is drawn inside the zone rect, so it starts where the zone starts.
    @Test(arguments: [true, false])
    func theBandsAboveAndBelowThePreviewStrokeAreEqual(gapEnabled: Bool) {
        let gap = gapEnabled ? Settings.Fixed.gap : 0
        let strokeTop = Geometry.frame(for: .full, in: display.visibleFrame, gap: gap).minY
        let above = strokeTop - display.visibleFrame.minY
        let below = bar(gapEnabled: gapEnabled).frame.minY - (strokeTop + ZonePreview.strokeWidth)
        #expect(abs(above - gap) < 1e-9)
        #expect(abs(below - gap) < 1e-9)
    }

    @Test func topInsetFollowsTheGap() {
        #expect(bar(gapEnabled: false).frame.minY == 28)   // 25 + (0 + 3 + 0)
        #expect(bar().frame.minY == 44)                    // 25 + (8 + 3 + 8)
    }

    @Test func zoneRectsSitInsideTheirCellWithInnerGap() {
        let z = g.zoneRect(layoutIndex: 0, cellIndex: 0)   // left half of the halves cell
        #expect(z == Geometry.frame(for: LayoutCatalog.halves.cells[0], in: g.cellRect(0), gap: SnapBarGeometry.innerGap))
        #expect(g.cellRect(0).contains(z))
    }

    @Test func hitTesting() {
        #expect(g.hit(g.zoneRect(layoutIndex: 0, cellIndex: 0).center) == .cell(layoutIndex: 0, cellIndex: 0))
        // Last cell of the last layout (grid-2x2) and the bottom-right quarter of left-half-right-quarters.
        #expect(g.hit(g.zoneRect(layoutIndex: 3, cellIndex: 3).center) == .cell(layoutIndex: 3, cellIndex: 3))
        #expect(g.hit(g.zoneRect(layoutIndex: 2, cellIndex: 2).center) == .cell(layoutIndex: 2, cellIndex: 2))
        #expect(g.hit(CGPoint(x: g.frame.minX + 4, y: g.frame.minY + 4)) == .background)
        #expect(g.hit(CGPoint(x: g.frame.midX, y: g.frame.maxY + 1)) == nil)
        #expect(g.hit(CGPoint(x: 10, y: 60)) == nil)
    }

    /// The bar's own empty space — the padding around the row of cells and the spacing between two of
    /// them. That is what Fill is aimed at, so it may never start resolving to a neighbouring zone.
    @Test func spacingBetweenCellsIsBackground() {
        let betweenCells = CGPoint(x: (g.cellRect(0).maxX + g.cellRect(1).minX) / 2, y: g.cellRect(0).midY)
        // The probe really is in the spacing, not in either cell. (Comparing the width against
        // `SnapBarGeometry.spacing` would be CGFloat vs Double, which `#expect` resolves through
        // AnyHashable and is false whatever the numbers; `cellsAreLaidOutLeftToRight` pins the 8 pt.)
        #expect(g.cellRect(0).maxX < betweenCells.x && betweenCells.x < g.cellRect(1).minX)
        #expect(g.hit(betweenCells) == .background)
        // The padding, on all four sides of the row.
        #expect(g.hit(CGPoint(x: g.frame.minX + 4, y: g.frame.midY)) == .background)
        #expect(g.hit(CGPoint(x: g.frame.maxX - 4, y: g.frame.midY)) == .background)
        #expect(g.hit(CGPoint(x: g.cellRect(0).midX, y: g.frame.minY + 4)) == .background)
        #expect(g.hit(CGPoint(x: g.cellRect(0).midX, y: g.frame.maxY - 4)) == .background)
    }

    /// Inside a cell there is no dead point: the drawn 3 pt seam splits between the two zones it
    /// separates and the drawn 3 pt rim belongs to the zone it borders. Sweeping across a cell hands
    /// one zone straight to the next, never through Fill.
    @Test func everyPointInsideACellBelongsToAZoneOfThatLayout() {
        for li in g.layouts.indices {
            let cell = g.cellRect(li)
            for x in stride(from: cell.minX, to: cell.maxX, by: 1) {
                for y in stride(from: cell.minY, to: cell.maxY, by: 1) {
                    guard case .cell(let hitLayout, _)? = g.hit(CGPoint(x: x, y: y)) else {
                        Issue.record("no zone at \(x),\(y) in cell \(li)")
                        continue
                    }
                    #expect(hitLayout == li)
                }
            }
        }
    }

    /// The halves cell splits at its own midX: the 3 pt drawn gap straddles that line, and the line
    /// itself opens the right zone.
    @Test func theSeamBetweenTwoZonesSplitsDownItsMiddle() {
        let cell = g.cellRect(0)
        #expect(g.hit(CGPoint(x: cell.midX, y: cell.midY)) == .cell(layoutIndex: 0, cellIndex: 1))
        #expect(g.hit(CGPoint(x: cell.midX - 0.5, y: cell.midY)) == .cell(layoutIndex: 0, cellIndex: 0))
        // Both probes sit in the drawn gap, which is the whole point: neither is over a drawn zone.
        #expect(!g.zoneRect(layoutIndex: 0, cellIndex: 0).contains(CGPoint(x: cell.midX - 0.5, y: cell.midY)))
        #expect(!g.zoneRect(layoutIndex: 0, cellIndex: 1).contains(CGPoint(x: cell.midX, y: cell.midY)))
    }

    /// The rim belongs to the zone it borders — including the corners, where the grid's four zones
    /// meet the cell's own.
    @Test func theRimOfACellBelongsToTheZoneBesideIt() {
        let halves = g.cellRect(0)
        #expect(g.hit(CGPoint(x: halves.minX, y: halves.midY)) == .cell(layoutIndex: 0, cellIndex: 0))
        #expect(g.hit(CGPoint(x: halves.maxX - 0.5, y: halves.midY)) == .cell(layoutIndex: 0, cellIndex: 1))
        let grid = g.cellRect(3)   // grid-2x2: cells run top-left, top-right, bottom-left, bottom-right
        #expect(g.hit(CGPoint(x: grid.minX, y: grid.minY)) == .cell(layoutIndex: 3, cellIndex: 0))
        #expect(g.hit(CGPoint(x: grid.maxX - 0.5, y: grid.minY)) == .cell(layoutIndex: 3, cellIndex: 1))
        #expect(g.hit(CGPoint(x: grid.minX, y: grid.maxY - 0.5)) == .cell(layoutIndex: 3, cellIndex: 2))
        #expect(g.hit(CGPoint(x: grid.maxX - 0.5, y: grid.maxY - 0.5)) == .cell(layoutIndex: 3, cellIndex: 3))
    }

    /// `Layouts.json` is validated for bounds but never for coverage, so a hand-edited layout may
    /// leave a hole. The rule holds anyway: the nearest zone claims it rather than the background.
    @Test func aLayoutThatDoesNotTileStillHasNoDeadPoint() {
        var s = Settings()
        s.snapBarAppearance = .bar
        s.gapEnabled = true
        let leftHalfOnly = Layout(id: "left-half-only", cells: [UnitRect(0, 0, 0.5, 1)])
        let sparse = SnapBarGeometry(layouts: [leftHalfOnly], display: display, settings: s)
        let cell = sparse.cellRect(0)
        // The right half of the cell is covered by no zone at all.
        #expect(sparse.hit(CGPoint(x: cell.maxX - 1, y: cell.midY)) == .cell(layoutIndex: 0, cellIndex: 0))
        #expect(sparse.hit(CGPoint(x: cell.midX + 1, y: cell.midY)) == .cell(layoutIndex: 0, cellIndex: 0))
        // Outside the cell it is still the bar's background.
        #expect(sparse.hit(CGPoint(x: cell.maxX + 4, y: cell.midY)) == .background)
    }

    /// A point equidistant from two zones' centres goes to the lower cell index. Arbitrary, but it has
    /// to be the same answer every time or the highlight would flicker where the two regions meet.
    @Test func anEquidistantPointGoesToTheLowerCellIndex() {
        var s = Settings()
        s.snapBarAppearance = .bar
        s.gapEnabled = true
        let quarters = Layout(id: "outer-quarters",
                              cells: [UnitRect(0, 0, 0.25, 1), UnitRect(0.75, 0, 0.25, 1)])
        let sparse = SnapBarGeometry(layouts: [quarters], display: display, settings: s)
        let cell = sparse.cellRect(0)
        #expect(sparse.hit(CGPoint(x: cell.midX, y: cell.midY)) == .cell(layoutIndex: 0, cellIndex: 0))
    }

    @Test func geometryAndArmingFollowADisplayAwayFromTheOrigin() {
        let g2 = bar(on: secondary)
        // Centered on midX 1440 + 960 = 2400 → 2400 − 216 = 2184; top = visibleFrame.minY −175 + 19 = −156.
        #expect(g2.frame == CGRect(x: 2184, y: -156, width: 432, height: 88))
        #expect(g2.cellRect(0) == CGRect(x: 2196, y: -144, width: 96, height: 64))
        // Arming is measured from this display's own top edge (−200), never from y = 0: −176 is the
        // last armed point, and 30 — which would be inside a 24 pt band measured from zero — is not.
        #expect(g2.shouldShow(cursor: CGPoint(x: 2400, y: -176), display: secondary, visible: false))
        #expect(!g2.shouldShow(cursor: CGPoint(x: 2400, y: -175), display: secondary, visible: false))
        #expect(!g2.shouldShow(cursor: CGPoint(x: 2400, y: 30), display: secondary, visible: false))
        #expect(g2.hit(g2.zoneRect(layoutIndex: 1, cellIndex: 1).center) == .cell(layoutIndex: 1, cellIndex: 1))
    }

    /// The bar arms on `edgeBand` — the same test that resolves the top zone — and releases
    /// on `edgeBand + releaseHysteresis`, the same release the top zone uses.
    @Test func armsAndReleasesOnTheEdgeBand() {
        // Arming, from cold: 24 is the last armed point, 25 is not armed.
        #expect(g.shouldShow(cursor: CGPoint(x: 700, y: 24), display: display, visible: false))
        #expect(!g.shouldShow(cursor: CGPoint(x: 700, y: 25), display: display, visible: false))
        // Release, beside the bar so only the first hide clause can answer: 24 + 12 = 36 is the last
        // point held, 37 is released.
        #expect(g.shouldShow(cursor: CGPoint(x: 100, y: 36), display: display, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 100, y: 37), display: display, visible: true))
    }

    /// The second hide clause, which is what lets the cursor travel down into the bar.
    @Test func theBarHoldsAroundItselfWithinTheHideMargin() {
        #expect(g.shouldShow(cursor: CGPoint(x: 700, y: 100), display: display, visible: true))       // inside the bar
        // Pins `hideMargin` at exactly 16 below and to either side.
        #expect(g.shouldShow(cursor: CGPoint(x: 700, y: g.frame.maxY + 16), display: display, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 700, y: g.frame.maxY + 17), display: display, visible: true))
        #expect(g.shouldShow(cursor: CGPoint(x: g.frame.minX - 16, y: 100), display: display, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: g.frame.minX - 17, y: 100), display: display, visible: true))
        #expect(g.shouldShow(cursor: CGPoint(x: g.frame.maxX + 16, y: 100), display: display, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: g.frame.maxX + 17, y: 100), display: display, visible: true))
        // Beside the bar and past the release band: nothing holds it.
        #expect(!g.shouldShow(cursor: CGPoint(x: 100, y: 100), display: display, visible: true))
    }

    /// A non-nil pair cell prepends one cell and the bar's width follows the cell count —
    /// it is not padded to keep a constant width.
    @Test func thePairCellWidensTheBarByExactlyOneCell() {
        // 12 + 5×96 + 4×8 + 12 = 536 wide; centered on 1440 → minX 720 − 268 = 452. Height unchanged.
        #expect(paired.frame == CGRect(x: 452, y: 44, width: 536, height: 88))
        // The difference derived from the constants rather than from the two literals above.
        let step = SnapBarGeometry.cellSize.width + SnapBarGeometry.spacing
        #expect(abs(paired.frame.width - g.frame.width - step) < 1e-9)
        #expect(paired.frame.minY == g.frame.minY)
        #expect(paired.frame.height == g.frame.height)
        #expect(paired.frame.midX == g.frame.midX)
    }

    /// The pair cell is the bar's *first* cell and every layout cell shifts one slot right — but the
    /// public indices still count layouts, so `cellRect(0)` is the halves layout's cell either way.
    @Test func thePairCellIsFirstAndTheLayoutCellsKeepTheirIndices() {
        #expect(paired.pairCellRect == CGRect(x: 464, y: 56, width: 96, height: 64))   // 452 + padding 12
        #expect(paired.cellRect(0) == CGRect(x: 568, y: 56, width: 96, height: 64))    // 464 + 96 + 8
        #expect(paired.cellRect(3).minX == 880)                                        // 464 + 4 × 104
        // The last layout cell still ends one padding short of the bar's right edge, at either width.
        #expect(abs(paired.frame.maxX - paired.cellRect(3).maxX - SnapBarGeometry.padding) < 1e-9)
        #expect(abs(g.frame.maxX - g.cellRect(3).maxX - SnapBarGeometry.padding) < 1e-9)
        // Index stability: the same layout answers to the same index, and a hit reports the same layout
        // index. Only the x moves — the zones are the same size in the same cell.
        #expect(paired.hit(paired.zoneRect(layoutIndex: 0, cellIndex: 0).center) == .cell(layoutIndex: 0, cellIndex: 0))
        #expect(paired.hit(paired.zoneRect(layoutIndex: 3, cellIndex: 3).center) == .cell(layoutIndex: 3, cellIndex: 3))
        #expect(paired.hit(paired.zoneRect(layoutIndex: 2, cellIndex: 2).center) == .cell(layoutIndex: 2, cellIndex: 2))
        #expect(paired.zoneRect(layoutIndex: 2, cellIndex: 2).size == g.zoneRect(layoutIndex: 2, cellIndex: 2).size)
        #expect(abs(paired.cellRect(0).minX - g.cellRect(0).minX - step48) < 1e-9)
    }

    /// 452 → 568 against 504 → 516: the bar moved left by half a slot and the cell moved right by half.
    private var step48: Double { (SnapBarGeometry.cellSize.width + SnapBarGeometry.spacing) / 2 }

    @Test func withoutAPartnerThereIsNoPairCellAtAll() {
        #expect(g.pairCell == nil)
        #expect(g.pairCellRect == nil)
        #expect(g.pairZoneRect(cellIndex: 0) == nil)
        #expect(g.localPairCellRect == nil)
        #expect(g.localPairZoneRects.isEmpty)
        #expect(g.localPairIconRect(cellIndex: PairCell.draggedCellIndex) == nil)
        #expect(g.localPairIconRect(cellIndex: PairCell.partnerCellIndex) == nil)
        // And no point of the bar reports a pair hit, swept across the whole panel rather than sampled
        // where the cell would have been: this is the assertion that the absent cell is absent from the
        // hit test too, not merely from the drawing.
        for x in stride(from: g.frame.minX, through: g.frame.maxX, by: 3) {
            for y in stride(from: g.frame.minY, through: g.frame.maxY, by: 3) {
                if case .pair = g.hit(CGPoint(x: x, y: y)) { Issue.record("pair hit at \(x),\(y)") }
            }
        }
    }

    /// The halves are drawn with the same `innerGap` arithmetic as any other cell's zones…
    @Test func thePairCellsHalvesAreTheHalvesLayoutsZonesInsideIt() {
        // Cell (464, 56, 96, 64) with innerGap 3: inner (465.5, 57.5, 93, 61), each half 46.5 wide
        // before its own 1.5 inset → 43.5 wide at x 467 and 513.5, y 59, 58 tall.
        #expect(paired.pairZoneRect(cellIndex: 0) == CGRect(x: 467, y: 59, width: 43.5, height: 58))
        #expect(paired.pairZoneRect(cellIndex: 1) == CGRect(x: 513.5, y: 59, width: 43.5, height: 58))
        #expect(paired.pairZoneRect(cellIndex: 2) == nil)
        #expect(paired.pairZoneRect(cellIndex: -1) == nil)
        for ci in PairCell.layout.cells.indices {
            let zone = paired.pairZoneRect(cellIndex: ci) ?? .null
            #expect(zone == Geometry.frame(for: PairCell.layout.cells[ci],
                                           in: paired.pairCellRect ?? .null, gap: SnapBarGeometry.innerGap))
            #expect(paired.pairCellRect?.contains(zone) == true)
        }
    }

    /// …but the cell is **one drop region**: every point of it answers `.pair`,
    /// the gap between the halves included, and nothing in the answer says which half the cursor is on.
    /// Swept point by point, because the whole defect this prevents is a point inside the cell that
    /// answers differently from its neighbour — a gap that fell through to `.background`, which
    /// resolves to Fill, so crossing the middle of the cell would have flipped the drop to full screen.
    @Test func theWholePairCellIsOneDropRegion() {
        let cell = paired.pairCellRect ?? .null
        var hits = Set<SnapBarHit>()
        for x in stride(from: cell.minX, through: cell.maxX - 0.01, by: 0.5) {
            for y in stride(from: cell.minY, through: cell.maxY - 0.01, by: 0.5) {
                hits.insert(paired.hit(CGPoint(x: x, y: y)) ?? .background)
            }
        }
        #expect(hits == [.pair])
        // Including the exact centre line, where the 3 pt inner gap straddles the cell's midX.
        #expect(paired.hit(CGPoint(x: cell.midX, y: cell.midY)) == .pair)
        // Its edges bound it: the spacing between the pair cell and the halves cell behind it is still
        // the bar's background, so the region is the cell and not "everything up to the next cell".
        let between = (cell.maxX + paired.cellRect(0).minX) / 2
        #expect(cell.maxX < between && between < paired.cellRect(0).minX)
        #expect(paired.hit(CGPoint(x: between, y: cell.midY)) == .background)
        #expect(paired.hit(CGPoint(x: cell.minX - 1, y: cell.midY)) == .background)
        #expect(paired.hit(CGPoint(x: cell.midX, y: cell.minY - 1)) == .background)
    }

    /// Both applications' icons, each centred in the half its window lands in, so the user reads the
    /// whole outcome off the cell: dragged left, partner right. Panel-relative, because that is the
    /// space they are drawn in.
    @Test func eachHalfsIconIsCentredInThatHalf() throws {
        #expect(paired.localPairCellRect == CGRect(x: 12, y: 12, width: 96, height: 64))
        // `try #require`, not `#expect`: `#expect` does not abort, so an empty `localPairZoneRects`
        // would reach the subscripts below and trap — and a crashed target prints no summary line.
        let halves = try #require(paired.localPairZoneRects.count == 2 ? paired.localPairZoneRects : nil)
        for ci in [PairCell.draggedCellIndex, PairCell.partnerCellIndex] {
            let half = halves[ci]
            let icon = paired.localPairIconRect(cellIndex: ci) ?? .null
            #expect(abs(icon.width - SnapBarGeometry.pairIconSide) < 1e-9)
            #expect(abs(icon.height - SnapBarGeometry.pairIconSide) < 1e-9)
            #expect(icon.midX == half.midX)
            #expect(icon.midY == half.midY)
            #expect(half.contains(icon))
        }
        // 24 centred in each half: (15 + 43.5/2) − 12 = 24.75 and (61.5 + 43.5/2) − 12 = 71.25 across,
        // (15 + 29) − 12 = 32 down for both.
        #expect(paired.localPairIconRect(cellIndex: PairCell.draggedCellIndex)
                == CGRect(x: 24.75, y: 32, width: 24, height: 24))
        #expect(paired.localPairIconRect(cellIndex: PairCell.partnerCellIndex)
                == CGRect(x: 71.25, y: 32, width: 24, height: 24))
        // Two icons, two places: neither strays into the other's half, so the cell never reads as one
        // window taking both sides.
        #expect(!halves[PairCell.partnerCellIndex]
            .intersects(paired.localPairIconRect(cellIndex: PairCell.draggedCellIndex) ?? .null))
        #expect(!halves[PairCell.draggedCellIndex]
            .intersects(paired.localPairIconRect(cellIndex: PairCell.partnerCellIndex) ?? .null))
        // The cell has two halves and no third: an index the layout does not have draws nothing.
        #expect(paired.localPairIconRect(cellIndex: 2) == nil)
        #expect(paired.localPairIconRect(cellIndex: -1) == nil)
    }

    /// The pair cell widens the bar, so the second hide clause — within `hideMargin` of the bar — has
    /// to follow the new edges. 436 is held by the wider bar and released by the narrower one.
    @Test func theWiderBarHoldsAroundItsOwnEdges() {
        #expect(paired.shouldShow(cursor: CGPoint(x: paired.frame.minX - 16, y: 100), display: display, visible: true))
        #expect(!paired.shouldShow(cursor: CGPoint(x: paired.frame.minX - 17, y: 100), display: display, visible: true))
        #expect(paired.shouldShow(cursor: CGPoint(x: 436, y: 100), display: display, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 436, y: 100), display: display, visible: true))
    }

    /// The whole cell follows the display the bar is on, not the primary one.
    @Test func thePairCellFollowsADisplayAwayFromTheOrigin() {
        let g2 = bar(on: secondary, pairing: true)
        // Centered on midX 2400 → 2400 − 268 = 2132; top = visibleFrame.minY −175 + 19 = −156.
        #expect(g2.frame == CGRect(x: 2132, y: -156, width: 536, height: 88))
        #expect(g2.pairCellRect == CGRect(x: 2144, y: -144, width: 96, height: 64))
        #expect(g2.pairCell?.displayID == secondary.id)
        #expect(g2.hit(g2.pairCellRect?.center ?? .zero) == .pair)
    }

    /// Both regions start at the display's top edge, so their union is
    /// contiguous at any gap and contains the arming band. Swept point by point, because the bar's
    /// position moves with the gap.
    @Test(arguments: [true, false])
    func theArmedRegionIsContiguousFromTheTopEdgeIntoTheBar(gapEnabled: Bool) {
        let b = bar(gapEnabled: gapEnabled)
        let x = b.frame.midX
        let lastHeld = b.frame.maxY + SnapBarGeometry.hideMargin
        // Contiguous: held for every point from the display's top edge down to the bar's bottom plus
        // the margin, and released immediately after. No hole, so no reveal-then-hide strip.
        for y in stride(from: display.frame.minY, through: lastHeld, by: 1) {
            #expect(b.shouldShow(cursor: CGPoint(x: x, y: y), display: display, visible: true), "held at y=\(y)")
        }
        #expect(!b.shouldShow(cursor: CGPoint(x: x, y: lastHeld + 1), display: display, visible: true))
        // And the arming band lies inside that region, so travelling down from it never loses the bar.
        #expect(b.shouldShow(cursor: CGPoint(x: x, y: b.edgeBand), display: display, visible: false))
        #expect(b.edgeBand <= lastHeld)
        // The bar itself is reachable: its own top edge is held.
        #expect(b.shouldShow(cursor: CGPoint(x: x, y: b.frame.minY), display: display, visible: true))
    }
}
