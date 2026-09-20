import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct EdgeDropFreeFrameTests {
    typealias F = ArrangementFixture
    let rightHalf = CGRect(x: 754, y: 8, width: 738, height: 884)
    let leftHalf = CGRect(x: 8, y: 8, width: 738, height: 884)
    let topRight = CGRect(x: 754, y: 8, width: 738, height: 438)
    let bottomRight = CGRect(x: 754, y: 454, width: 738, height: 438)

    func window(_ id: UInt32, _ frame: CGRect, min: CGSize? = nil, z: Int = 0) -> SnapOccupant {
        SnapOccupant(windowID: id, pid: 1, frame: frame, minimum: min, zIndex: z)
    }

    func free(_ zone: CGRect, _ neighbours: [SnapOccupant], fills: Bool = true) -> CGRect {
        EdgeDrop.freeFrame(zone: zone, area: F.area, gap: F.gap, neighbours: neighbours, fills: fills)
    }

    func expect(_ actual: CGRect, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = CGRect(x: x, y: y, width: width, height: height)
        #expect(actual.isApproximatelyEqual(to: expected, tolerance: 0.01), "\(actual) is not \(expected)",
                sourceLocation: sourceLocation)
    }

    @Test func withNobodyBesideItTheZoneIsTheFreeFrame() {
        expect(free(rightHalf, []), 754, 8, 738, 884)
    }

    @Test func aLeftThirdLeavesTheRightTwoThirds() {
        let third = window(1, Geometry.frame(for: UnitRect(0, 0, 1.0 / 3, 1), in: F.area, gap: F.gap))
        expect(free(rightHalf, [third]), 505.33, 8, 986.67, 884)
    }

    @Test func aLeftTwoThirdsLeavesTheRightThird() {
        let twoThirds = window(1, Geometry.frame(for: UnitRect(0, 0, 2.0 / 3, 1), in: F.area, gap: F.gap))
        expect(free(rightHalf, [twoThirds]), 1002.67, 8, 489.33, 884)
    }

    @Test func aRightThirdLeavesTheLeftTwoThirds() {
        let third = window(1, Geometry.frame(for: UnitRect(2.0 / 3, 0, 1.0 / 3, 1), in: F.area, gap: F.gap))
        expect(free(leftHalf, [third]), 8, 8, 986.67, 884)
    }

    @Test func aTallWindowAboveLeavesTheRestOfTheColumn() {
        let tall = window(1, CGRect(x: 754, y: 8, width: 738, height: 600))
        expect(free(bottomRight, [tall]), 754, 616, 738, 276)
    }

    @Test func aQuarterHeightWindowSaysNothingAboutAHalf() {
        let quarter = window(1, CGRect(x: 8, y: 8, width: 400, height: 438))
        expect(free(rightHalf, [quarter]), 754, 8, 738, 884)
    }

    @Test func aWindowSpanningTheZoneSaysNothingAboutIt() {
        let maximized = window(1, CGRect(x: 8, y: 8, width: 1484, height: 884))
        expect(free(rightHalf, [maximized]), 754, 8, 738, 884)
    }

    @Test func theNearestFacingEdgeIsTheBoundary() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884))
        let column = window(2, CGRect(x: 505, y: 8, width: 200, height: 884))
        expect(free(rightHalf, [third, column]), 713, 8, 779, 884)
    }

    @Test func growthStopsAtAnotherNeighbour() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884), z: 1)
        let low = window(2, CGRect(x: 8, y: 600, width: 738, height: 292), z: 0)
        expect(free(rightHalf, [third, low]), 754, 8, 738, 884)
    }

    // MARK: Both axes at once

    let narrowTopLeft = CGRect(x: 8, y: 8, width: 492, height: 438)
    let bottomLeftQuarter = CGRect(x: 8, y: 454, width: 738, height: 438)

    @Test func aCornerDropDoesNotGrowIntoTheDiagonalWindow() {
        let neighbours = [window(1, narrowTopLeft), window(2, CGRect(x: 754, y: 620, width: 738, height: 272)),
                          window(3, bottomLeftQuarter)]
        let frame = free(topRight, neighbours)
        let overlap = frame.intersection(bottomLeftQuarter)
        #expect(overlap.isNull || overlap.width <= 1 || overlap.height <= 1, "\(frame) reaches the diagonal window")
    }

    @Test func theLargerOfTheTwoOrdersWins() {
        // Across first: 984 × 438. Down first: 738 × 604, which is larger.
        let neighbours = [window(1, narrowTopLeft), window(2, CGRect(x: 754, y: 620, width: 738, height: 272)),
                          window(3, bottomLeftQuarter)]
        expect(free(topRight, neighbours), 754, 8, 738, 604)
    }

    @Test func aTieKeepsAcrossFirst() {
        // 984 × 438 and 738 × 584 are the same area.
        let neighbours = [window(1, narrowTopLeft), window(2, CGRect(x: 754, y: 600, width: 738, height: 292)),
                          window(3, bottomLeftQuarter)]
        expect(free(topRight, neighbours), 508, 8, 984, 438)
    }

    @Test func withoutFillTheZoneIsTheFreeFrame() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884))
        expect(free(rightHalf, [third], fills: false), 754, 8, 738, 884)
    }
}

@Suite struct EdgeDropPlanTests {
    typealias F = ArrangementFixture
    let rightHalf = CGRect(x: 754, y: 8, width: 738, height: 884)
    let leftHalf = CGRect(x: 8, y: 8, width: 738, height: 884)

    func window(_ id: UInt32, _ frame: CGRect, min: CGSize? = nil) -> SnapOccupant {
        SnapOccupant(windowID: id, pid: 1, frame: frame, minimum: min)
    }

    func plan(_ zone: CGRect, _ neighbours: [SnapOccupant], dragged: CGSize? = nil, fills: Bool = true) -> EdgeDrop.Plan {
        EdgeDrop.plan(zone: zone, area: F.area, gap: F.gap, draggedID: 99,
                      draggedLimits: SizeLimits(minimum: MinimumSizePolicy.presumed(dragged)),
                      neighbours: neighbours, fills: fills)
    }

    @Test func theDraggedWindowIsABoxAtTheFreeFrame() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884))
        let planned = plan(rightHalf, [third])
        #expect(planned.dragged == .window(99))
        #expect(planned.arrangement.aligned == false)
        #expect(planned.freeFrame == CGRect(x: 505, y: 8, width: 987, height: 884))
        #expect(planned.arrangement.boxes.first { $0.id == .window(99) }?.preferred == planned.freeFrame)
    }

    @Test func aNeighbourComesWithItsKnownMinimumOrThePresumedOne() {
        let measured = window(1, CGRect(x: 8, y: 8, width: 489, height: 438), min: CGSize(width: 420, height: 0))
        let unmeasured = window(2, CGRect(x: 8, y: 454, width: 489, height: 438))
        let boxes = plan(rightHalf, [measured, unmeasured]).arrangement.boxes
        #expect(boxes.first { $0.id == .window(1) }?.limits == SizeLimits(minimum: CGSize(width: 420, height: 150)))
        #expect(boxes.first { $0.id == .window(2) }?.limits == SizeLimits(minimum: CGSize(width: 200, height: 150)))
    }

    @Test func aWindowUnderTheZoneIsNotABox() {
        let maximized = window(1, CGRect(x: 8, y: 8, width: 1484, height: 884))
        #expect(plan(rightHalf, [maximized]).arrangement.boxes.map(\.id) == [.window(99)])
    }

    @Test func aDropOnTheTopEdgeCoversEverythingAndMovesNothing() {
        let whole = CGRect(x: 8, y: 8, width: 1484, height: 884)
        let planned = plan(whole, [window(1, leftHalf), window(2, rightHalf)])
        #expect(planned.arrangement.boxes.map(\.id) == [.window(99)])
        #expect(planned.arrangement.solve().frames[.window(99)] == whole)
    }

    @Test func aKnownMinimumMakesTheNeighbourGive() {
        let wide = window(1, CGRect(x: 8, y: 8, width: 1270, height: 884), min: CGSize(width: 600, height: 300))
        let solved = plan(rightHalf, [wide], dragged: CGSize(width: 500, height: 300)).arrangement.solve()
        #expect(solved.frames[.window(1)] == CGRect(x: 8, y: 8, width: 976, height: 884))
        #expect(solved.frames[.window(99)] == CGRect(x: 992, y: 8, width: 500, height: 884))
    }

    @Test func aSliverNarrowerThanThePresumedFloorIsWidenedByItsNeighbour() {
        let wide = window(1, CGRect(x: 8, y: 8, width: 1342, height: 884))
        let solved = plan(rightHalf, [wide]).arrangement.solve()
        #expect(solved.frames[.window(1)] == CGRect(x: 8, y: 8, width: 1276, height: 884))
        #expect(solved.frames[.window(99)] == CGRect(x: 1292, y: 8, width: 200, height: 884))
    }

    @Test func aDropThatDoesNotFitPushesItsRightNeighbourOffTheDisplay() {
        let right = window(1, rightHalf, min: CGSize(width: 700, height: 300))
        let solved = plan(leftHalf, [right], dragged: CGSize(width: 900, height: 300)).arrangement.solve()
        #expect(solved.frames[.window(99)] == CGRect(x: 8, y: 8, width: 900, height: 884))
        #expect(solved.frames[.window(1)] == CGRect(x: 916, y: 8, width: 700, height: 884))
    }

    @Test func withoutFillAHoleIsUsedBeforeANeighbourIsAsked() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884), min: CGSize(width: 300, height: 300))
        let solved = plan(rightHalf, [third], dragged: CGSize(width: 900, height: 300), fills: false).arrangement.solve()
        #expect(solved.frames[.window(1)] == third.frame)
        #expect(solved.frames[.window(99)] == CGRect(x: 592, y: 8, width: 900, height: 884))
    }

    @Test func presumedFillsOnlyTheAxesNobodyMeasured() {
        #expect(MinimumSizePolicy.presumed(nil) == CGSize(width: 200, height: 150))
        #expect(MinimumSizePolicy.presumed(CGSize(width: 500, height: 0)) == CGSize(width: 500, height: 150))
        #expect(MinimumSizePolicy.presumed(CGSize(width: 0, height: 400)) == CGSize(width: 200, height: 400))
        #expect(MinimumSizePolicy.presumed(CGSize(width: 600, height: 500)) == CGSize(width: 600, height: 500))
    }

    /// Whatever stands on the desktop, a drop never makes the dragged window overlap a neighbour it
    /// took into account, and never reaches into one while taking what is free.
    @Test func noDropOverlapsANeighbour() {
        var rng = SeededGenerator(seed: 23)
        let zones = [UnitRect(0, 0, 0.5, 1), UnitRect(0.5, 0, 0.5, 1), UnitRect(0, 0, 0.5, 0.5), UnitRect(0.5, 0, 0.5, 0.5),
                     UnitRect(0, 0.5, 0.5, 0.5), UnitRect(0.5, 0.5, 0.5, 0.5)].map { Geometry.frame(for: $0, in: F.area, gap: F.gap) }
        let tiles = LayoutCatalog.snapBar.flatMap(\.cells) + [UnitRect(0, 0, 1.0 / 3, 1), UnitRect(2.0 / 3, 0, 1.0 / 3, 1)]
        for _ in 0..<3000 {
            var windows: [SnapOccupant] = []
            for index in 0..<Int.random(in: 1...4, using: &rng) {
                var frame = Geometry.frame(for: tiles[Int.random(in: 0..<tiles.count, using: &rng)], in: F.area, gap: F.gap)
                if Bool.random(using: &rng) { frame.size.width -= Double.random(in: 0...300, using: &rng).rounded() }
                if Bool.random(using: &rng) { frame.size.height -= Double.random(in: 0...200, using: &rng).rounded() }
                windows.append(SnapOccupant(windowID: UInt32(index + 1), pid: 1, frame: frame,
                                            minimum: Bool.random(using: &rng) ? CGSize(width: 300, height: 200) : nil, zIndex: index))
            }
            let neighbours = NeighbourEvidence.neighbours(among: windows, area: F.area, gap: F.gap).accepted
            let zone = zones[Int.random(in: 0..<zones.count, using: &rng)]
            let minimum = CGSize(width: Double.random(in: 200...1000, using: &rng).rounded(),
                                 height: Double.random(in: 150...700, using: &rng).rounded())
            let planned = plan(zone, neighbours, dragged: minimum)
            for neighbour in neighbours {
                let overlap = planned.freeFrame.intersection(neighbour.frame)
                let covered = !zone.intersection(neighbour.frame).isNull
                    && zone.intersection(neighbour.frame).width > 1 && zone.intersection(neighbour.frame).height > 1
                if !covered {
                    #expect(overlap.isNull || overlap.width <= 1 || overlap.height <= 1,
                            "free \(planned.freeFrame) reaches \(neighbour.frame) — zone \(zone), windows \(windows)")
                }
            }
            let solved = planned.arrangement.solve()
            let dragged = solved.frames[.window(99)]!
            for box in planned.arrangement.boxes where box.id != .window(99) {
                let overlap = dragged.intersection(solved.frames[box.id]!)
                #expect(overlap.isNull || overlap.width <= 1 || overlap.height <= 1,
                        "\(dragged) overlaps \(solved.frames[box.id]!) — zone \(zone), windows \(windows)")
            }
        }
    }
}

/// A drop on the top edge is a maximize, unconditionally: the whole working area, whatever stands on
/// the display, with nobody else in the arrangement.
@Suite struct EdgeDropMaximiseTests {
    typealias F = ArrangementFixture
    let fill = Geometry.frame(for: .full, in: ArrangementFixture.area, gap: ArrangementFixture.gap)

    func window(_ id: UInt32, _ frame: CGRect, min: CGSize? = nil) -> SnapOccupant {
        SnapOccupant(windowID: id, pid: 1, frame: frame, minimum: min)
    }

    func maximised(dragged: CGSize? = nil) -> EdgeDrop.Plan {
        EdgeDrop.maximised(zone: fill, area: F.area, gap: F.gap, draggedID: 99,
                           draggedLimits: SizeLimits(minimum: MinimumSizePolicy.presumed(dragged)))
    }

    @Test func theDraggedWindowIsTheWholeWorkingAreaAndTheOnlyBox() {
        let planned = maximised()
        #expect(planned.dragged == .window(99))
        #expect(planned.freeFrame == fill)
        #expect(planned.arrangement.boxes.count == 1)
        #expect(planned.arrangement.boxes.first?.preferred == fill)
        #expect(planned.arrangement.solve().frames[.window(99)] == fill)
    }

    /// The failure this rule replaces: a window on the right half standing **flush with the screen's
    /// edge** rather than one gap inside it used to move the zone's right edge in to meet it, so a drag
    /// to the top edge placed the window in the left half. No window can move this frame now.
    @Test func aRightHalfFlushWithTheScreenEdgeDoesNotShrinkIt() {
        let flush = window(1, CGRect(x: 754, y: 8, width: F.area.maxX - 754, height: 884))
        #expect(flush.frame.maxX > fill.maxX)
        let planned = maximised()
        #expect(planned.freeFrame == fill)
        #expect(planned.arrangement.boxes.map(\.id) == [.window(99)])
    }

    /// Only the dragged window's own minimum can take it off the zone, past the right or bottom edge as
    /// every arrangement overflows.
    @Test func aMinimumLargerThanTheWorkingAreaOverflows() {
        let solved = maximised(dragged: CGSize(width: 1600, height: 1000)).arrangement.solve()
        let frame = solved.frames[.window(99)]!
        #expect(frame.minX == fill.minX)
        #expect(frame.minY == fill.minY)
        #expect(frame.width == 1600)
        #expect(frame.height == 1000)
    }
}
