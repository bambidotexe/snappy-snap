import Testing
import CoreGraphics
@testable import SnapCore

/// The rule that rounds a drawn zone: a corner sitting at a corner of its cell is concentric with the
/// cell's own corner, everything else stays tight. Measured against the same rects the bar draws, so a
/// layout is described by the cell it is in and nothing else.
@Suite struct SnapBarZoneCornerTests {
    /// A cell at the origin, the shipped 96 × 64.
    let cell = CGRect(x: 0, y: 0, width: 96, height: 64)
    var outer: Double { SnapBarGeometry.zoneOuterRadius }
    var inner: Double { SnapBarGeometry.zoneRadius }

    /// The zone of `layout`'s cell `index` as it is drawn inside `cell`.
    func zone(_ layout: Layout, _ index: Int, in cell: CGRect? = nil) -> CGRect {
        Geometry.frame(for: layout.cells[index], in: cell ?? self.cell, gap: SnapBarGeometry.innerGap)
    }

    func radii(_ layout: Layout, _ index: Int, in cell: CGRect? = nil) -> SnapBarGeometry.ZoneCornerRadii {
        SnapBarGeometry.zoneCornerRadii(zone: zone(layout, index, in: cell), in: cell ?? self.cell)
    }

    // MARK: - The number itself

    @Test func theOuterRadiusIsConcentricWithTheCell() {
        // A curve inset by `innerGap` from a radius-8 curve has radius 5. Equal radii would converge
        // through the bend and the rim would read thinner there than along the straight edges.
        #expect(SnapBarGeometry.zoneOuterRadius == SnapBarGeometry.cellRadius - SnapBarGeometry.innerGap)
        #expect(SnapBarGeometry.zoneOuterRadius == 5)
    }

    // MARK: - One zone filling the cell

    @Test func aZoneFillingTheCellRoundsWideAtEveryCorner() {
        let whole = Layout(id: "whole", cells: [UnitRect(0, 0, 1, 1)])
        let r = radii(whole, 0)
        #expect(r == SnapBarGeometry.ZoneCornerRadii(topLeading: outer, bottomLeading: outer,
                                                     bottomTrailing: outer, topTrailing: outer))
    }

    // MARK: - Halves

    @Test func halvesRoundWideOnlyDownTheirOuterSide() throws {
        let halves = try #require(LayoutCatalog.snapBar.first)
        // Two cells side by side: the left one is wide at its two left corners and tight at the seam.
        let left = radii(halves, 0)
        #expect(left.topLeading == outer)
        #expect(left.bottomLeading == outer)
        #expect(left.topTrailing == inner)
        #expect(left.bottomTrailing == inner)

        let right = radii(halves, 1)
        #expect(right.topTrailing == outer)
        #expect(right.bottomTrailing == outer)
        #expect(right.topLeading == inner)
        #expect(right.bottomLeading == inner)
    }

    // MARK: - A 2 × 2 grid

    @Test func eachZoneOfAGridRoundsWideAtExactlyItsOutwardCorner() {
        let grid = Layout(id: "grid", cells: [UnitRect(0, 0, 0.5, 0.5), UnitRect(0.5, 0, 0.5, 0.5),
                                             UnitRect(0, 0.5, 0.5, 0.5), UnitRect(0.5, 0.5, 0.5, 0.5)])
        // Top-left zone: wide at top-leading only. Its other three corners each face a seam.
        #expect(radii(grid, 0) == SnapBarGeometry.ZoneCornerRadii(topLeading: outer, bottomLeading: inner,
                                                                  bottomTrailing: inner, topTrailing: inner))
        #expect(radii(grid, 1) == SnapBarGeometry.ZoneCornerRadii(topLeading: inner, bottomLeading: inner,
                                                                  bottomTrailing: inner, topTrailing: outer))
        #expect(radii(grid, 2) == SnapBarGeometry.ZoneCornerRadii(topLeading: inner, bottomLeading: outer,
                                                                  bottomTrailing: inner, topTrailing: inner))
        #expect(radii(grid, 3) == SnapBarGeometry.ZoneCornerRadii(topLeading: inner, bottomLeading: inner,
                                                                  bottomTrailing: outer, topTrailing: inner))
    }

    // MARK: - The rule's edge: one axis is not enough

    @Test func aCornerTouchingOneEdgeOnlyStaysTight() {
        // Three rows in one column. The middle one spans the cell's full width, so both of its top
        // corners lie on the cell's left and right edges — but neither lies on its top edge, and a wide
        // corner there would round away from the zone it sits flush beneath.
        let rows = Layout(id: "rows", cells: [UnitRect(0, 0, 1, 1.0 / 3), UnitRect(0, 1.0 / 3, 1, 1.0 / 3),
                                             UnitRect(0, 2.0 / 3, 1, 1.0 / 3)])
        let middle = radii(rows, 1)
        #expect(middle == SnapBarGeometry.ZoneCornerRadii(topLeading: inner, bottomLeading: inner,
                                                          bottomTrailing: inner, topTrailing: inner))
        // The top row keeps its two top corners, which do lie on both.
        let top = radii(rows, 0)
        #expect(top.topLeading == outer)
        #expect(top.topTrailing == outer)
        #expect(top.bottomLeading == inner)
        #expect(top.bottomTrailing == inner)
    }

    // MARK: - Independent of where the cell is

    @Test func theRuleFollowsTheCellRatherThanTheOrigin() throws {
        let halves = try #require(LayoutCatalog.snapBar.first)
        // A cell anywhere else on the bar, at a fractional origin: the rule is relative to its own rect.
        let moved = CGRect(x: 516.5, y: 56.25, width: 96, height: 64)
        #expect(radii(halves, 0, in: moved) == radii(halves, 0))
    }

    // MARK: - The pair cell

    @Test func thePairCellsHalvesFollowTheSameRule() {
        // The pair cell is not one of `layouts`, and is rounded by the cell it is drawn in like the rest.
        let left = radii(PairCell.layout, PairCell.draggedCellIndex)
        let right = radii(PairCell.layout, PairCell.partnerCellIndex)
        #expect(left.topLeading == outer)
        #expect(left.bottomLeading == outer)
        #expect(left.topTrailing == inner)
        #expect(right.topTrailing == outer)
        #expect(right.topLeading == inner)
    }
}
