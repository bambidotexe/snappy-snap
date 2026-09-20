import CoreGraphics
import Testing
@testable import SnapCore

/// One display for every arrangement test: 1500 × 900 with an 8 pt gap, so the left half is
/// (8, 8, 738, 884) and the right half (754, 8, 738, 884).
enum ArrangementFixture {
    static let area = CGRect(x: 0, y: 0, width: 1500, height: 900)
    static let gap = 8.0
    static let open = SizeLimits(minimum: CGSize(width: 200, height: 150))

    static func cell(_ layout: Layout, _ index: Int) -> CGRect {
        Geometry.frame(for: layout.cells[index], in: area, gap: gap)
    }

    static func box(_ id: UInt32, _ preferred: CGRect, min: (Double, Double) = (200, 150),
                    maxW: Double? = nil, maxH: Double? = nil) -> ArrangementBox {
        ArrangementBox(id: .window(id), preferred: preferred,
                       limits: SizeLimits(minimum: CGSize(width: min.0, height: min.1),
                                          maximumWidth: maxW, maximumHeight: maxH))
    }

    static func solve(_ boxes: [ArrangementBox], aligned: Bool = true) -> ArrangementSolution {
        Arrangement(area: area, gap: gap, aligned: aligned, boxes: boxes).solve()
    }

    /// Whole rectangles, never a `CGFloat` against a `Double`: `#expect` compares those by boxing.
    static func expect(_ solution: ArrangementSolution, _ id: UInt32, _ x: Double, _ y: Double,
                       _ width: Double, _ height: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = CGRect(x: x, y: y, width: width, height: height)
        let actual = solution.frames[.window(id)]
        #expect(actual?.isApproximatelyEqual(to: expected, tolerance: 0.01) == true,
                "window \(id): \(String(describing: actual)) is not \(expected)", sourceLocation: sourceLocation)
    }
}

@Suite struct ArrangementSolverScenarios {
    typealias F = ArrangementFixture
    let halves = LayoutCatalog.halves
    let threeCells = LayoutCatalog.leftHalfRightQuarters
    let grid = LayoutCatalog.grid2x2

    @Test func halvesThatFitKeepTheirCells() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (400, 300)), F.box(2, F.cell(halves, 1))])
        F.expect(solved, 1, 8, 8, 738, 884)
        F.expect(solved, 2, 754, 8, 738, 884)
    }

    @Test func aMinimumMovesTheDividerAndTheOpenCellTakesTheRest() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (900, 300)), F.box(2, F.cell(halves, 1))])
        F.expect(solved, 1, 8, 8, 900, 884)
        F.expect(solved, 2, 916, 8, 576, 884)
    }

    @Test func aMaximumOnTheLeftLetsTheRightFill() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (300, 300), maxW: 500), F.box(2, F.cell(halves, 1))])
        F.expect(solved, 1, 8, 8, 500, 884)
        F.expect(solved, 2, 516, 8, 976, 884)
    }

    @Test func aMaximumOnTheRightStaysAgainstTheEdge() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (300, 300)),
                              F.box(2, F.cell(halves, 1), min: (300, 300), maxW: 400)])
        F.expect(solved, 1, 8, 8, 1076, 884)
        F.expect(solved, 2, 1092, 8, 400, 884)
    }

    @Test func minimumsThatDoNotFitOverflowToTheRight() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (900, 300)), F.box(2, F.cell(halves, 1), min: (700, 300))])
        F.expect(solved, 1, 8, 8, 900, 884)
        F.expect(solved, 2, 916, 8, 700, 884)
        #expect(solved.overflow(of: .window(2), in: F.area, gap: F.gap) == CGSize(width: 124, height: 0))
        #expect(solved.overflow(of: .window(1), in: F.area, gap: F.gap) == .zero)
    }

    @Test func aPlacedMemberGivesRoomToALaterOne() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (500, 300)), F.box(2, F.cell(halves, 1), min: (900, 300))])
        F.expect(solved, 1, 8, 8, 576, 884)
        F.expect(solved, 2, 592, 8, 900, 884)
    }

    @Test func threeCellsFollowTheTopRightMinimum() {
        let solved = F.solve([F.box(1, F.cell(threeCells, 0), min: (400, 300)),
                              F.box(2, F.cell(threeCells, 1), min: (900, 600)),
                              F.box(3, F.cell(threeCells, 2))])
        F.expect(solved, 1, 8, 8, 576, 884)
        F.expect(solved, 2, 592, 8, 900, 600)
        F.expect(solved, 3, 592, 616, 900, 276)
    }

    @Test func aGridStaysAlignedWhenOneCellNeedsRoom() {
        let solved = F.solve([F.box(1, F.cell(grid, 0), min: (900, 500)), F.box(2, F.cell(grid, 1)),
                              F.box(3, F.cell(grid, 2)), F.box(4, F.cell(grid, 3))])
        F.expect(solved, 1, 8, 8, 900, 500)
        F.expect(solved, 2, 916, 8, 576, 500)
        F.expect(solved, 3, 8, 516, 900, 376)
        F.expect(solved, 4, 916, 516, 576, 376)
    }

    @Test func overflowIsPerBoxNotPerLine() {
        let solved = F.solve([F.box(1, F.cell(grid, 0), min: (900, 300)), F.box(2, F.cell(grid, 1), min: (800, 300)),
                              F.box(3, F.cell(grid, 2)), F.box(4, F.cell(grid, 3))])
        F.expect(solved, 2, 916, 8, 800, 438)
        F.expect(solved, 4, 916, 454, 576, 438)
        #expect(solved.overflow(of: .window(2), in: F.area, gap: F.gap) == CGSize(width: 224, height: 0))
        #expect(solved.overflow(of: .window(4), in: F.area, gap: F.gap) == .zero)
    }

    @Test func aBoxTooTallOverflowsTheBottom() {
        let solved = F.solve([F.box(1, F.cell(threeCells, 0), min: (400, 1000)),
                              F.box(2, F.cell(threeCells, 1)), F.box(3, F.cell(threeCells, 2))])
        F.expect(solved, 1, 8, 8, 738, 1000)
        F.expect(solved, 2, 754, 8, 738, 438)
        F.expect(solved, 3, 754, 454, 738, 438)
    }

    @Test func aMiddleColumnTakesRoomEvenlyFromBothSides() throws {
        let thirds = Layout(id: "thirds", cells: [UnitRect(0, 0, 1.0 / 3, 1), UnitRect(1.0 / 3, 0, 1.0 / 3, 1),
                                                  UnitRect(2.0 / 3, 0, 1.0 / 3, 1)])
        let solved = F.solve([F.box(1, F.cell(thirds, 0)), F.box(2, F.cell(thirds, 1), min: (700, 300)),
                              F.box(3, F.cell(thirds, 2))])
        let left = try #require(solved.frames[.window(1)])
        let middle = try #require(solved.frames[.window(2)])
        let right = try #require(solved.frames[.window(3)])
        #expect(abs(Double(middle.width) - 700) < 0.01)
        #expect(abs(Double(middle.midX) - Double(F.cell(thirds, 1).midX)) < 0.01)
        #expect(abs(Double(left.width) - Double(right.width)) < 0.01)
    }

    @Test func aMiddleColumnAsksTheOtherSideForWhatOneCannotGive() throws {
        let thirds = Layout(id: "thirds", cells: [UnitRect(0, 0, 1.0 / 3, 1), UnitRect(1.0 / 3, 0, 1.0 / 3, 1),
                                                  UnitRect(2.0 / 3, 0, 1.0 / 3, 1)])
        // The left column will not go below 480 of its 489: it can give 9, so the right gives the rest.
        let solved = F.solve([F.box(1, F.cell(thirds, 0), min: (480, 300)), F.box(2, F.cell(thirds, 1), min: (700, 300)),
                              F.box(3, F.cell(thirds, 2))])
        let left = try #require(solved.frames[.window(1)])
        let middle = try #require(solved.frames[.window(2)])
        let right = try #require(solved.frames[.window(3)])
        #expect(abs(Double(left.width) - 480) < 0.01)
        #expect(abs(Double(middle.width) - 700) < 0.01)
        #expect(abs(Double(right.maxX) - 1492) < 0.01)
        #expect(abs(Double(middle.maxX) + F.gap - Double(right.minX)) < 0.01)
    }

    // MARK: Edge drops: only facing edges are one divider

    @Test func anEdgeDropNeighbourGivesRoom() {
        let neighbour = CGRect(x: 8, y: 8, width: 1270, height: 884)
        let free = CGRect(x: 1286, y: 8, width: 206, height: 884)
        let solved = F.solve([F.box(1, neighbour, min: (600, 300)), F.box(2, free, min: (500, 300))], aligned: false)
        F.expect(solved, 1, 8, 8, 976, 884)
        F.expect(solved, 2, 992, 8, 500, 884)
    }

    @Test func aNeighbourThatCannotGivePushesTheDraggedWindowOff() {
        let neighbour = CGRect(x: 8, y: 8, width: 1270, height: 884)
        let free = CGRect(x: 1286, y: 8, width: 206, height: 884)
        let solved = F.solve([F.box(1, neighbour, min: (1200, 300)), F.box(2, free, min: (500, 300))], aligned: false)
        F.expect(solved, 1, 8, 8, 1200, 884)
        F.expect(solved, 2, 1216, 8, 500, 884)
    }

    @Test func aLeftDropPushesItsRightNeighbourOff() {
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (900, 300)), F.box(2, F.cell(halves, 1), min: (700, 300))],
                             aligned: false)
        F.expect(solved, 1, 8, 8, 900, 884)
        F.expect(solved, 2, 916, 8, 700, 884)
    }

    @Test func unalignedRowsAreIndependent() {
        let solved = F.solve([F.box(1, F.cell(grid, 0), min: (900, 300)), F.box(2, F.cell(grid, 1), min: (300, 300)),
                              F.box(3, F.cell(grid, 2), min: (300, 300)), F.box(4, F.cell(grid, 3), min: (300, 300))],
                             aligned: false)
        F.expect(solved, 1, 8, 8, 900, 438)
        F.expect(solved, 2, 916, 8, 576, 438)
        F.expect(solved, 3, 8, 454, 738, 438)
        F.expect(solved, 4, 754, 454, 738, 438)
    }

    @Test func aFlushNeighbourKeepsItsOuterEdge() {
        let flush = CGRect(x: 0, y: 0, width: 750, height: 900)
        let free = CGRect(x: 758, y: 8, width: 734, height: 884)
        let solved = F.solve([F.box(1, flush, min: (300, 300)), F.box(2, free, min: (900, 300))], aligned: false)
        F.expect(solved, 1, 0, 0, 584, 900)
        F.expect(solved, 2, 592, 8, 900, 884)
    }

    /// Windows tiled by something that leaves no gap touch each other. They are still two windows in
    /// an order, and one pushed along pushes the next: closer than a gap is not the same as overlapping.
    @Test func neighboursThatTouchAreStillPushedInOrder() {
        let middle = CGRect(x: 754, y: 8, width: 370, height: 884)
        let right = CGRect(x: 1124, y: 8, width: 368, height: 884)   // touching `middle`, no gap between them
        let solved = F.solve([F.box(1, F.cell(halves, 0), min: (1000, 300)), F.box(2, middle, min: (200, 150)),
                              F.box(3, right, min: (200, 150))], aligned: false)
        F.expect(solved, 1, 8, 8, 1000, 884)
        let pushed = solved.frames[.window(2)]!, last = solved.frames[.window(3)]!
        #expect(Double(pushed.minX) >= 1016 - 0.01)
        #expect(Double(last.minX) >= Double(pushed.maxX) - 0.01, "\(pushed) overlaps \(last)")
    }

    @Test func neighboursThatTouchAreNotPulledApartWhenNothingNeedsRoom() {
        let middle = CGRect(x: 754, y: 8, width: 370, height: 884)
        let right = CGRect(x: 1124, y: 8, width: 368, height: 884)
        let solved = F.solve([F.box(1, F.cell(halves, 0)), F.box(2, middle), F.box(3, right)], aligned: false)
        F.expect(solved, 2, 754, 8, 370, 884)
        F.expect(solved, 3, 1124, 8, 368, 884)
    }

    @Test func boxesThatOverlapInThePreferredGeometryDoNotConstrainEachOther() {
        let under = CGRect(x: 8, y: 8, width: 1484, height: 884)
        let solved = F.solve([F.box(1, under, min: (1400, 300)), F.box(2, F.cell(halves, 1), min: (300, 300))],
                             aligned: false)
        F.expect(solved, 1, 8, 8, 1484, 884)
        F.expect(solved, 2, 754, 8, 738, 884)
    }

    @Test func aBoxWithNoSizeTakesNoPart() {
        let solved = F.solve([F.box(1, .zero), F.box(2, F.cell(halves, 1))])
        #expect(solved.frames[.window(1)] == .zero)
        F.expect(solved, 2, 754, 8, 738, 884)
    }
}

/// What must hold for every arrangement, checked over seeded random ones. A failure prints the case.
@Suite struct ArrangementSolverProperties {
    typealias F = ArrangementFixture
    static let layouts = LayoutCatalog.snapBar + [
        Layout(id: "thirds", cells: [UnitRect(0, 0, 1.0 / 3, 1), UnitRect(1.0 / 3, 0, 1.0 / 3, 1), UnitRect(2.0 / 3, 0, 1.0 / 3, 1)]),
        Layout(id: "rows", cells: [UnitRect(0, 0, 1, 0.5), UnitRect(0, 0.5, 1, 0.5)]),
    ]

    /// A layout's cells with random limits. Unaligned cases also pull some inner edges back, which
    /// leaves holes and never an overlap — by 2 pt or more, because edges within the solver's 1 pt
    /// tolerance are one edge by definition and come back on it.
    static func randomBoxes(_ rng: inout SeededGenerator, aligned: Bool, tinyMinimums: Bool = false) -> [ArrangementBox] {
        let layout = layouts[Int.random(in: 0..<layouts.count, using: &rng)]
        return layout.cells.indices.map { index in
            var frame = F.cell(layout, index)
            if !aligned, Bool.random(using: &rng) {
                let pull = Double.random(in: 2...120, using: &rng)
                if frame.minX > 100 { frame.origin.x += pull; frame.size.width -= pull }
                else if frame.maxX < 1400 { frame.size.width -= pull }
            }
            var limits = SizeLimits(minimum: CGSize(width: 1, height: 1))
            if !tinyMinimums {
                limits.minimum = CGSize(width: Double.random(in: 150...1100, using: &rng).rounded(),
                                        height: Double.random(in: 150...700, using: &rng).rounded())
                if Int.random(in: 0..<6, using: &rng) == 0 {
                    limits.maximumWidth = Double.random(in: 300...900, using: &rng).rounded()
                }
            }
            return ArrangementBox(id: .window(UInt32(index + 1)), preferred: frame, limits: limits)
        }
    }

    static func disjoint(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return overlap.isNull || overlap.width <= 1 || overlap.height <= 1
    }

    @Test(arguments: [true, false])
    func boxesThatWereApartStayApart(aligned: Bool) {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<2000 {
            let boxes = Self.randomBoxes(&rng, aligned: aligned)
            let solved = F.solve(boxes, aligned: aligned)
            for i in boxes.indices { for j in boxes.indices where i < j {
                guard Self.disjoint(boxes[i].preferred, boxes[j].preferred) else { continue }
                let a = solved.frames[boxes[i].id]!, b = solved.frames[boxes[j].id]!
                #expect(Self.disjoint(a, b), "\(a) overlaps \(b) — boxes \(boxes)")
            } }
        }
    }

    /// Real windows are not always a gap apart: tiled by another tool, or by hand, they touch or stand
    /// a few points from each other. Columns cut at random places with random separations from 0 to
    /// 12 pt, some cut again into rows: whatever the minimums, what was apart stays apart.
    @Test func windowsAtAnySeparationStayApart() {
        var rng = SeededGenerator(seed: 31)
        for _ in 0..<3000 {
            var boxes: [ArrangementBox] = []
            var x = 8.0
            let columns = Int.random(in: 2...4, using: &rng)
            for column in 0..<columns {
                let width = Double.random(in: 150...500, using: &rng).rounded()
                var y = 8.0
                let rows = Int.random(in: 1...2, using: &rng)
                for row in 0..<rows {
                    let height = rows == 1 ? 884 : Double.random(in: 200...420, using: &rng).rounded()
                    let minimum = CGSize(width: Double.random(in: 100...900, using: &rng).rounded(),
                                         height: Double.random(in: 100...600, using: &rng).rounded())
                    boxes.append(ArrangementBox(id: .window(UInt32(column * 2 + row + 1)),
                                                preferred: CGRect(x: x, y: y, width: width, height: height),
                                                limits: SizeLimits(minimum: minimum)))
                    y += height + Double.random(in: 0...12, using: &rng).rounded()
                }
                x += width + Double.random(in: 0...12, using: &rng).rounded()
            }
            let solved = F.solve(boxes, aligned: false)
            for i in boxes.indices { for j in boxes.indices where i < j {
                let a = solved.frames[boxes[i].id]!, b = solved.frames[boxes[j].id]!
                #expect(Self.disjoint(a, b), "\(a) overlaps \(b) — boxes \(boxes)")
            } }
        }
    }

    @Test(arguments: [true, false])
    func nothingLeavesByTheTopOrTheLeftAndEveryMinimumIsMet(aligned: Bool) {
        var rng = SeededGenerator(seed: 11)
        for _ in 0..<2000 {
            let boxes = Self.randomBoxes(&rng, aligned: aligned)
            let solved = F.solve(boxes, aligned: aligned)
            for box in boxes {
                let frame = solved.frames[box.id]!
                #expect(Double(frame.minX) >= F.gap - 0.001 && Double(frame.minY) >= F.gap - 0.001, "\(frame) — \(boxes)")
                let wide = box.limits.maximumWidth.map { max($0, Double(box.limits.minimum.width)) }
                #expect(Double(frame.width) >= Double(box.limits.minimum.width) - 0.001
                            && Double(frame.height) >= Double(box.limits.minimum.height) - 0.001, "\(frame) — \(box)")
                if let wide { #expect(Double(frame.width) <= wide + 0.001, "\(frame) is over its maximum — \(box)") }
            }
        }
    }

    /// One row of columns: it fits exactly when the minimums and their gaps fit, and when it does not
    /// the last column runs past the edge by exactly what is missing — never more.
    @Test func aRowOverflowsByExactlyWhatIsMissing() {
        var rng = SeededGenerator(seed: 13)
        for _ in 0..<2000 {
            let count = Int.random(in: 2...4, using: &rng)
            let layout = Layout(id: "row", cells: (0..<count).map { UnitRect(Double($0) / Double(count), 0, 1 / Double(count), 1) })
            let minimums = (0..<count).map { _ in Double.random(in: 150...900, using: &rng).rounded() }
            let boxes = layout.cells.indices.map { F.box(UInt32($0 + 1), F.cell(layout, $0), min: (minimums[$0], 150)) }
            let solved = F.solve(boxes)
            let needed = minimums.reduce(0, +) + F.gap * Double(count + 1)
            let missing = max(0, needed - Double(F.area.width))
            let worst = boxes.map { Double(solved.overflow(of: $0.id, in: F.area, gap: F.gap).width) }.max()!
            #expect(abs(worst - missing) < 0.001, "overflow \(worst), missing \(missing) — minimums \(minimums)")
        }
    }

    @Test(arguments: [true, false])
    func withNothingBindingThePreferredGeometryComesBack(aligned: Bool) {
        var rng = SeededGenerator(seed: 17)
        for _ in 0..<500 {
            let boxes = Self.randomBoxes(&rng, aligned: aligned, tinyMinimums: true)
            let solved = F.solve(boxes, aligned: aligned)
            for box in boxes {
                #expect(solved.frames[box.id]!.isApproximatelyEqual(to: box.preferred, tolerance: 0.001), "\(box)")
            }
        }
    }

    /// Whatever it is handed — boxes anywhere, overlapping, outside the area, a maximum under a minimum,
    /// no gap at all — the solver answers, with finite frames, and every box that is not aligned with
    /// another gets its minimum. (Aligned, a box lying outside the area can share a divider with one
    /// standing on the area's edge, and that divider does not move for it.)
    @Test func anythingAtAllGetsAFiniteAnswer() {
        var rng = SeededGenerator(seed: 29)
        for _ in 0..<3000 {
            let gap = Bool.random(using: &rng) ? 0.0 : 8.0
            let boxes = (0..<Int.random(in: 1...6, using: &rng)).map { index -> ArrangementBox in
                let frame = CGRect(x: Double.random(in: -400...1600, using: &rng).rounded(),
                                   y: Double.random(in: -300...1000, using: &rng).rounded(),
                                   width: Double.random(in: 0...1600, using: &rng).rounded(),
                                   height: Double.random(in: 0...1000, using: &rng).rounded())
                let minimum = CGSize(width: Double.random(in: 0...3000, using: &rng).rounded(),
                                     height: Double.random(in: 0...2000, using: &rng).rounded())
                return ArrangementBox(id: .window(UInt32(index + 1)), preferred: frame,
                                      limits: SizeLimits(minimum: minimum,
                                                         maximumWidth: Bool.random(using: &rng) ? Double.random(in: 1...2000, using: &rng) : nil,
                                                         maximumHeight: Bool.random(using: &rng) ? Double.random(in: 1...2000, using: &rng) : nil))
            }
            let aligned = Bool.random(using: &rng)
            let solved = Arrangement(area: F.area, gap: gap, aligned: aligned, boxes: boxes).solve()
            for box in boxes {
                let frame = solved.frames[box.id]
                #expect(frame != nil, "no frame for \(box)")
                guard let frame, box.preferred.width > 1, box.preferred.height > 1 else { continue }
                #expect(frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite,
                        "\(frame) — \(boxes)")
                #expect(frame.width > 0 && frame.height > 0, "\(frame) — \(boxes)")
                if !aligned || F.area.contains(box.preferred) {
                    #expect(Double(frame.width) >= Double(box.limits.minimum.width) - 0.001
                                && Double(frame.height) >= Double(box.limits.minimum.height) - 0.001,
                            "\(frame) is under its minimum — \(box) among \(boxes)")
                }
            }
        }
    }

    /// To within the solver's own edge tolerance: two edges that land exactly that far apart are one
    /// divider the second time, which is the definition of the tolerance and moves a frame by no more.
    @Test(arguments: [true, false])
    func solvingTheSolutionChangesNothing(aligned: Bool) {
        var rng = SeededGenerator(seed: 19)
        for _ in 0..<1000 {
            let boxes = Self.randomBoxes(&rng, aligned: aligned)
            let first = F.solve(boxes, aligned: aligned)
            let again = F.solve(boxes.map { box in
                var settled = box
                settled.preferred = first.frames[box.id]!
                return settled
            }, aligned: aligned)
            for box in boxes {
                #expect(again.frames[box.id]!.isApproximatelyEqual(to: first.frames[box.id]!,
                                                                   tolerance: ArrangementSolver.tolerance + 0.001),
                        "\(first.frames[box.id]!) became \(again.frames[box.id]!) — \(boxes)")
            }
        }
    }
}
