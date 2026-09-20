import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct GeometryTests {
    // Working area of a 1000×625 display with a 25 pt menu bar.
    let area = CGRect(x: 0, y: 25, width: 1000, height: 600)
    let display = DisplayInfo(id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 625),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 600))

    @Test func halvesWithGap8() {
        let left = Geometry.frame(for: LayoutCatalog.halves.cells[0], in: area, gap: 8)
        let right = Geometry.frame(for: LayoutCatalog.halves.cells[1], in: area, gap: 8)
        #expect(left == CGRect(x: 8, y: 33, width: 488, height: 584))
        #expect(right == CGRect(x: 504, y: 33, width: 488, height: 584))
        #expect(right.minX - left.maxX == 8)
        #expect(area.maxX - right.maxX == 8)
    }

    @Test func onlyTheFillLayoutsZoneIsAFill() {
        func zone(_ layout: Layout, _ index: Int) -> Zone {
            Zone(displayID: 7, layout: layout, cellIndex: index,
                 frame: Geometry.frame(for: layout.cells[index], in: area, gap: 8))
        }
        #expect(zone(LayoutCatalog.fill, 0).isFill)
        #expect(!zone(LayoutCatalog.halves, 0).isFill)
        #expect(!zone(LayoutCatalog.halves, 1).isFill)
        #expect(!zone(LayoutCatalog.grid2x2, 0).isFill)
    }

    @Test func gapZeroFillsTheAreaExactly() {
        #expect(Geometry.frame(for: .full, in: area, gap: 0) == area)
    }

    @Test(arguments: [0.0, 8.0, 24.0])
    func outerInsetEqualsGapForEveryLayout(gap: Double) {
        for layout in LayoutCatalog.snapBar {
            let frames = layout.cells.map { Geometry.frame(for: $0, in: area, gap: gap) }
            #expect(abs(frames.map(\.minX).min()! - (area.minX + gap)) < 1e-6, "\(layout.id)")
            #expect(abs(frames.map(\.maxX).max()! - (area.maxX - gap)) < 1e-6, "\(layout.id)")
            #expect(abs(frames.map(\.minY).min()! - (area.minY + gap)) < 1e-6, "\(layout.id)")
            #expect(abs(frames.map(\.maxY).max()! - (area.maxY - gap)) < 1e-6, "\(layout.id)")
        }
    }

    @Test(arguments: [0.0, 8.0, 24.0])
    func neighborsAreExactlyGapApart(gap: Double) {
        // Unequal columns: the gap must not depend on the cells having the same width.
        let cols = LayoutCatalog.twoThirdsOneThird.cells.map { Geometry.frame(for: $0, in: area, gap: gap) }
        #expect(abs((cols[1].minX - cols[0].maxX) - gap) < 1e-6)
        // An interior cell, bounded by a gap on both sides and by no outer edge — the case no shipped
        // layout has any more, since every grid-2x2 cell touches the outer boundary on two sides.
        let thirds = Layout(id: "thirds", cells: [UnitRect(0, 0, 1.0 / 3, 1), UnitRect(1.0 / 3, 0, 1.0 / 3, 1), UnitRect(2.0 / 3, 0, 1.0 / 3, 1)])
        let three = thirds.cells.map { Geometry.frame(for: $0, in: area, gap: gap) }
        #expect(abs((three[1].minX - three[0].maxX) - gap) < 1e-6)
        #expect(abs((three[2].minX - three[1].maxX) - gap) < 1e-6)
        // Three equal cells share four gaps across the width: two interior and the two outer insets.
        #expect(abs(three[1].width - (area.width - 4 * gap) / 3) < 1e-6)
        // All four adjacencies of the grid, so a cell with a neighbour on two sides is covered
        // now that no catalog layout has three cells in a row.
        let grid = LayoutCatalog.grid2x2.cells.map { Geometry.frame(for: $0, in: area, gap: gap) }
        #expect(abs((grid[1].minX - grid[0].maxX) - gap) < 1e-6)
        #expect(abs((grid[2].minY - grid[0].maxY) - gap) < 1e-6)
        #expect(abs((grid[3].minX - grid[2].maxX) - gap) < 1e-6)
        #expect(abs((grid[3].minY - grid[1].maxY) - gap) < 1e-6)
        let mixed = LayoutCatalog.leftHalfRightQuarters.cells.map { Geometry.frame(for: $0, in: area, gap: gap) }
        #expect(abs((mixed[1].minX - mixed[0].maxX) - gap) < 1e-6)
        #expect(abs((mixed[2].minY - mixed[1].maxY) - gap) < 1e-6)
    }

    // MARK: - Minimum-size anchoring

    /// The four halves and the four quarters of the suite's working area, at the default gap.
    func zone(_ layout: Layout, _ index: Int) -> CGRect { Geometry.frame(for: layout.cells[index], in: area, gap: 8) }
    var leftHalf: CGRect { zone(LayoutCatalog.halves, 0) }          // (8, 33, 488, 584)
    var rightHalf: CGRect { zone(LayoutCatalog.halves, 1) }         // (504, 33, 488, 584)
    // No shipped layout stacks two rows across the full width; the anchoring rule has to hold
    // for one all the same.
    var topHalf: CGRect { Geometry.frame(for: UnitRect(0, 0, 1, 0.5), in: area, gap: 8) }     // (8, 33, 984, 288)
    var bottomHalf: CGRect { Geometry.frame(for: UnitRect(0, 0.5, 1, 0.5), in: area, gap: 8) } // (8, 329, 984, 288)

    @Test func aWindowThatFitsItsZoneStaysAtTheZoneOrigin() {
        for zone in [leftHalf, rightHalf, topHalf, bottomHalf] {
            #expect(Geometry.anchoredOrigin(for: zone.size, in: zone, within: area) == zone.origin)
            #expect(Geometry.anchoredOrigin(for: CGSize(width: 300, height: 200), in: zone, within: area) == zone.origin)
        }
    }

    /// The defect this rule exists for: a 700 pt-wide window in the right half would be left at the
    /// zone's *inner* edge, so 204 pt of it hung off the display. Anchored, it hangs inward instead.
    @Test func aRightZoneAnchorsAnOversizedWindowToItsOuterEdge() {
        let size = CGSize(width: 700, height: 584)
        let origin = Geometry.anchoredOrigin(for: size, in: rightHalf, within: area)
        #expect(origin == CGPoint(x: 292, y: 33))
        #expect(origin.x + size.width == rightHalf.maxX)
        #expect(origin.x + size.width <= area.maxX)
    }

    @Test func aLeftZoneKeepsTheOriginItAlreadyHad() {
        let origin = Geometry.anchoredOrigin(for: CGSize(width: 700, height: 584), in: leftHalf, within: area)
        #expect(origin == leftHalf.origin)
    }

    @Test func aBottomZoneAnchorsUpwardAndATopZoneDoesNot() {
        let size = CGSize(width: 984, height: 400)
        #expect(Geometry.anchoredOrigin(for: size, in: bottomHalf, within: area) == CGPoint(x: 8, y: 217))
        #expect(Geometry.anchoredOrigin(for: size, in: bottomHalf, within: area).y + size.height == bottomHalf.maxY)
        #expect(Geometry.anchoredOrigin(for: size, in: topHalf, within: area) == topHalf.origin)
    }

    /// Both axes overhang at once, which is the corner case the four halves cannot reach.
    @Test func aCornerZoneAnchorsOnBothAxesIndependently() {
        let size = CGSize(width: 600, height: 400)
        let topLeft = zone(LayoutCatalog.grid2x2, 0)
        let topRight = zone(LayoutCatalog.grid2x2, 1)
        let bottomLeft = zone(LayoutCatalog.grid2x2, 2)
        let bottomRight = zone(LayoutCatalog.grid2x2, 3)
        #expect(Geometry.anchoredOrigin(for: size, in: topLeft, within: area) == CGPoint(x: 8, y: 33))
        #expect(Geometry.anchoredOrigin(for: size, in: topRight, within: area) == CGPoint(x: 392, y: 33))
        #expect(Geometry.anchoredOrigin(for: size, in: bottomLeft, within: area) == CGPoint(x: 8, y: 217))
        #expect(Geometry.anchoredOrigin(for: size, in: bottomRight, within: area) == CGPoint(x: 392, y: 217))
    }

    /// A zone that spans the whole axis has no outer edge on it. The tie-break is "left zone →
    /// left/top", and the clamp still keeps the far edge on screen while the window fits the area.
    @Test func aFullWidthZoneKeepsTheLowEdgeButNotAtTheCostOfTheScreen() {
        #expect(Geometry.anchoredOrigin(for: CGSize(width: 990, height: 288), in: topHalf, within: area).x == 8)
        // 996 wide from x = 8 would end at 1004, past the working area; it slides back to 4.
        #expect(Geometry.anchoredOrigin(for: CGSize(width: 996, height: 288), in: topHalf, within: area).x == 4)
    }

    @Test func aWindowLargerThanTheWorkingAreaKeepsItsLeadingEdgeOnScreen() {
        let origin = Geometry.anchoredOrigin(for: CGSize(width: 1200, height: 700), in: rightHalf, within: area)
        #expect(origin == area.origin)
    }

    /// The property the arithmetic exists for, swept over every shipped layout: an oversized window
    /// that still fits the working area never lands outside it.
    @Test(arguments: [520.0, 700.0, 1000.0])
    func noZoneSendsAnOversizedWindowOffTheWorkingArea(width: Double) {
        for layout in LayoutCatalog.snapBar {
            for (i, cell) in layout.cells.enumerated() {
                let zone = Geometry.frame(for: cell, in: area, gap: 8)
                let size = CGSize(width: width, height: zone.height)
                let origin = Geometry.anchoredOrigin(for: size, in: zone, within: area)
                #expect(origin.x >= area.minX - 1e-6, "\(layout.id)[\(i)]")
                #expect(origin.x + size.width <= area.maxX + 1e-6, "\(layout.id)[\(i)]")
            }
        }
    }

    @Test func zoneUsesTheDisplayWorkingArea() {
        let zone = Geometry.zone(display: display, layout: LayoutCatalog.halves, cellIndex: 1, gap: 8)
        #expect(zone.displayID == 7)
        #expect(zone.layout == LayoutCatalog.halves)
        #expect(zone.cellIndex == 1)
        #expect(zone.cell == LayoutCatalog.halves.cells[1])
        #expect(zone.frame == CGRect(x: 504, y: 33, width: 488, height: 584))
    }
}

/// The rectangle a preview departs from when the window it comes from lies across a display seam.
@Suite struct SlidInsideTests {
    /// Displays side by side, the seam at x = 1000.
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1600, height: 900)

    /// A window already on the display does not move at all — the single-display morph is untouched.
    @Test func aRectangleAlreadyInsideIsUnchanged() {
        let r = CGRect(x: 1100, y: 100, width: 400, height: 300)
        #expect(Geometry.slid(r, inside: right) == r)
    }

    /// `O|O` becomes `|OO`: slid right until it is flush with the seam, same size.
    @Test func aStraddlingRectangleSlidesFlushAgainstTheSeam() {
        let r = CGRect(x: 800, y: 100, width: 400, height: 300)
        #expect(Geometry.slid(r, inside: right) == CGRect(x: 1000, y: 100, width: 400, height: 300))
    }

    /// The mirror: the target is the display on the left, so the rectangle slides the other way and
    /// ends flush with the same seam.
    @Test func theSlideGoesTheOtherWayForTheDisplayOnTheLeft() {
        let r = CGRect(x: 800, y: 100, width: 400, height: 300)
        #expect(Geometry.slid(r, inside: left) == CGRect(x: 600, y: 100, width: 400, height: 300))
    }

    /// Each axis is decided on its own. One that already lies inside keeps its position exactly — a
    /// window crossing a vertical seam departs from the height it really has. One that overhangs
    /// slides flush, whatever the other axis did: side-by-side displays of different heights make
    /// that ordinary, since a window high on the taller display crosses the seam in x *and* hangs
    /// off the top of the shorter one in y.
    @Test func eachAxisIsSlidOnItsOwn() {
        #expect(Geometry.slid(CGRect(x: 800, y: 100, width: 400, height: 300), inside: right)
                    == CGRect(x: 1000, y: 100, width: 400, height: 300))
        #expect(Geometry.slid(CGRect(x: 800, y: 700, width: 400, height: 300), inside: right)
                    == CGRect(x: 1000, y: 600, width: 400, height: 300))
        #expect(Geometry.slid(CGRect(x: 800, y: -50, width: 400, height: 300), inside: right)
                    == CGRect(x: 1000, y: 0, width: 400, height: 300))
    }

    /// Taller than the display is the same "never resized" rule on the other axis.
    @Test func aRectangleTooTallToFitIsNotShrunk() {
        let slid = Geometry.slid(CGRect(x: 1100, y: -50, width: 400, height: 1000), inside: right)
        #expect(slid.height == 1000)
        #expect(slid.minY == right.minY)
        #expect(slid.maxY > right.maxY)
    }

    /// Never a resize. A rectangle wider than the display stays its own width and ends flush with the
    /// edge it overhangs, overhanging the far one instead.
    @Test func aRectangleTooWideToFitIsNotShrunk() {
        let r = CGRect(x: 900, y: 100, width: 1200, height: 300)
        let slid = Geometry.slid(r, inside: left)
        #expect(slid.size == r.size)
        #expect(slid.maxX == left.maxX)
        #expect(slid.minX < left.minX)
    }

    /// Stacked displays are the same rule on the other axis.
    @Test func stackedDisplaysSlideVertically() {
        let below = CGRect(x: 0, y: 800, width: 1000, height: 600)
        let r = CGRect(x: 100, y: 700, width: 300, height: 200)
        #expect(Geometry.slid(r, inside: below) == CGRect(x: 100, y: 800, width: 300, height: 200))
    }

    // Two displays side by side, the seam at x = 1000.
    @Test func aSnapDepartsFromInsideItsDisplayWhenTheWindowLiesAcrossASeam() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let released = CGRect(x: 700, y: 100, width: 600, height: 400)
        #expect(Geometry.departure(of: released, onto: right, otherDisplays: [left])
                == CGRect(x: 1000, y: 100, width: 600, height: 400))
    }

    @Test func aWindowHangingPastAnEdgeWithNoDisplayBeyondItLeavesFromWhereItIs() {
        let only = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let released = CGRect(x: 700, y: 600, width: 600, height: 400)
        #expect(Geometry.departure(of: released, onto: only, otherDisplays: []) == released)
        let above = CGRect(x: 0, y: -800, width: 1000, height: 800)
        #expect(Geometry.departure(of: released, onto: only, otherDisplays: [above]) == released)
    }

    @Test func aWindowWhollyOnItsDisplayLeavesFromWhereItIs() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let released = CGRect(x: 1200, y: 100, width: 600, height: 400)
        #expect(Geometry.departure(of: released, onto: right, otherDisplays: [left]) == released)
    }
}
