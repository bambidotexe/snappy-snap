import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct IslandGeometryTests {
    /// A display with no housing, to the right of the built-in and 200 pt above it, so that every
    /// display-relative term differs from its absolute-zero twin. midX 2472, top −200.
    let external = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1512, y: -175, width: 1920, height: 1055))
    /// Four cells of 96 with three spacings of 8.
    let row = CGSize(width: 408, height: 64)

    /// The reference utility's widest island is 246 pt; ours covers it with 8 pt to spare on either
    /// side, at the reference's own height.
    @Test func theCollapsedIslandCoversTheReferencesWidestWithAMargin() {
        #expect(IslandGeometry.collapsedWidth == 262)
        #expect(IslandGeometry.collapsedWidth == IslandGeometry.referenceWidestWidth + IslandGeometry.coverMargin * 2)
        #expect(IslandGeometry.height == 25)
        #expect(IslandGeometry.collapsedRadius == IslandGeometry.height / 2)
    }

    @Test func everyStateFloatsThreePointsUnderTheTopEdgeAndIsCentredOnTheDisplay() {
        let g = IslandGeometry(display: external, rowSize: row)
        #expect(g.circle == CGRect(x: 2459.5, y: -197, width: 25, height: 25))
        #expect(g.collapsed == CGRect(x: 2341, y: -197, width: 262, height: 25))
        #expect(g.expanded == CGRect(x: 2244, y: -197, width: 456, height: 112))
        for rect in [g.circle, g.collapsed, g.expanded] {
            #expect(rect.midX == 2472)
            #expect(rect.minY == external.frame.minY + 3)
        }
        // Five cells: 512 + 48.
        #expect(IslandGeometry(display: external, rowSize: CGSize(width: 512, height: 64)).expanded
            == CGRect(x: 2192, y: -197, width: 560, height: 112))
    }

    /// No side of the island is the screen's edge, so the row is inset the same on all four.
    @Test func theRowIsInsetEquallyOnAllFourSides() {
        let g = IslandGeometry(display: external, rowSize: row)
        let origin = g.rowOrigin(rowWidth: row.width)
        #expect(origin == CGPoint(x: 2268, y: -173))
        #expect(Double(origin.x - g.expanded.minX) == IslandGeometry.padding)
        #expect(Double(origin.y - g.expanded.minY) == IslandGeometry.padding)
        #expect(Double(g.expanded.maxX - (origin.x + row.width)) == IslandGeometry.padding)
        #expect(Double(g.expanded.maxY - (origin.y + row.height)) == IslandGeometry.padding)
    }

    @Test func theExpandedShapeIsNeverNarrowerThanTheCapsule() {
        let g = IslandGeometry(display: external, rowSize: CGSize(width: 96, height: 64))
        #expect(g.expanded.width == 262)
        #expect(g.expanded.midX == 2472)
    }

    /// The capsule's rectangle, extended up to the screen's edge: the 3 pt above it are not a dead
    /// strip, so a pointer pressed against the edge arms it.
    @Test func itArmsOnTheCapsuleAndTheStripAboveIt() {
        let g = IslandGeometry(display: external, rowSize: row)
        #expect(g.armRegion == CGRect(x: 2341, y: -200, width: 262, height: 28))
        #expect(IslandGeometry.armRegion(of: external) == g.armRegion)
        #expect(g.armRegion.contains(CGPoint(x: 2472, y: -200)))
        #expect(g.armRegion.contains(g.collapsed))
    }

    @Test func itStaysInsideTheGrownShapeAndUpToTheScreensEdge() {
        let g = IslandGeometry(display: external, rowSize: row)
        #expect(g.stayRegion(margin: 16) == CGRect(x: 2228, y: -200, width: 488, height: 131))
        #expect(g.stayRegion(margin: 16).contains(g.armRegion))
    }

    @Test func thePanelHoldsEveryStateAndTheBlurFieldAndStartsAtTheScreensEdge() {
        let g = IslandGeometry(display: external, rowSize: row)
        #expect(g.panel == CGRect(x: 2164, y: -200, width: 616, height: 195))
        #expect(g.panel.minY == external.frame.minY)
        #expect(g.panel.contains(g.expanded))
        #expect(g.backdrop.silhouette == g.expanded)
        #expect(g.backdrop.lumaRegion == CGRect(x: 2228, y: -200, width: 488, height: 131))
    }

    @Test func eachStateHasItsRect() {
        let g = IslandGeometry(display: external, rowSize: row)
        #expect(g.rect(for: .hidden) == g.circle)
        #expect(g.rect(for: .circle) == g.circle)
        #expect(g.rect(for: .capsule) == g.collapsed)
        #expect(g.rect(for: .expanded) == g.expanded)
    }
}
