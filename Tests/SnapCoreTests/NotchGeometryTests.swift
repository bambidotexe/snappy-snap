import Testing
import CoreGraphics
import Foundation
@testable import SnapCore

@Suite struct NotchGeometryTests {
    /// The built-in display as measured: 1512 × 982, with a camera housing of 185 × 32 at x 663.5.
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 34, width: 1512, height: 889),
                              notch: CGRect(x: 663.5, y: 0, width: 185, height: 32))
    /// Four cells of 96 with three spacings of 8.
    let row = CGSize(width: 408, height: 64)

    @Test func theHousingIsTheDisplaysOwnAndTheCollapsedShapeSitsInsideIt() throws {
        let g = try #require(NotchGeometry(display: builtIn, rowSize: row))
        #expect(g.housing == CGRect(x: 663.5, y: 0, width: 185, height: 32))
        // 2 pt in on either side, so the resting shape never draws a pixel the housing does not hide.
        #expect(g.collapsed == CGRect(x: 665.5, y: 0, width: 181, height: 32))
        #expect(g.housing.contains(g.collapsed))
    }

    /// A display with no housing — or one AppKit reports with no area — has no notch shape at all:
    /// it draws the island.
    @Test func aDisplayWithNoHousingHasNoNotchGeometry() {
        let external = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
                                   visibleFrame: CGRect(x: 1512, y: -175, width: 1920, height: 1055))
        #expect(NotchGeometry(display: external, rowSize: row) == nil)
        var degenerate = builtIn
        degenerate.notch = CGRect(x: 700, y: 0, width: 0, height: 32)
        #expect(NotchGeometry(display: degenerate, rowSize: row) == nil)
    }

    @Test func theExpandedShapeHoldsTheRowUnderTheHousing() throws {
        let g = try #require(NotchGeometry(display: builtIn, rowSize: row))
        // 408 + 2 × 20 = 448 wide, centred on the housing's 756; 32 + 0 + 64 + 20 = 116 tall.
        #expect(g.expanded == CGRect(x: 532, y: 0, width: 448, height: 116))
        // The row is centred, and hangs from the housing's bottom edge.
        #expect(g.rowOrigin(rowWidth: 408) == CGPoint(x: 552, y: 32))
        // Five cells: 512 + 40.
        #expect(try #require(NotchGeometry(display: builtIn, rowSize: CGSize(width: 512, height: 64))).expanded
            == CGRect(x: 480, y: 0, width: 552, height: 116))
    }

    /// The row hangs from the housing's bottom edge — nothing between them — and is inset the same on
    /// the three sides that are not the housing.
    @Test func theRowHangsFromTheHousingAndIsInsetEquallyOnTheOtherThreeSides() throws {
        #expect(NotchGeometry.rowTopGap == 0)
        #expect(NotchGeometry.bottomPadding == NotchGeometry.sidePadding)
        let g = try #require(NotchGeometry(display: builtIn, rowSize: row))
        let origin = g.rowOrigin(rowWidth: row.width)
        #expect(origin.y == g.housing.maxY)
        #expect(Double(origin.x - g.expanded.minX) == NotchGeometry.sidePadding)
        #expect(Double(g.expanded.maxX - (origin.x + row.width)) == NotchGeometry.sidePadding)
        #expect(Double(g.expanded.maxY - (origin.y + row.height)) == NotchGeometry.sidePadding)
    }

    @Test func theExpandedShapeIsNeverNarrowerThanTheHousing() throws {
        let g = try #require(NotchGeometry(display: builtIn, rowSize: .zero))
        #expect(g.expanded.width == 185)
        #expect(g.expanded.midX == g.housing.midX)
    }

    /// The panel is what stays still while the shape grows, so it has to hold the grown shape, the
    /// blur field around it and the open spring's overshoot — and start at the screen's edge, which is
    /// what the shape grows out of.
    @Test func thePanelHoldsTheShapeAndItsBlurFieldAndStartsAtTheScreensEdge() throws {
        let g = try #require(NotchGeometry(display: builtIn, rowSize: CGSize(width: 512, height: 64)))
        #expect(g.panel == CGRect(x: 400, y: 0, width: 712, height: 196))
        #expect(g.panel.contains(g.expanded))
        #expect(g.panel.minY == builtIn.frame.minY)
        // Under 1 % of the blur at the panel's side and bottom edges.
        #expect(g.backdrop.blurWeight(at: CGPoint(x: g.panel.minX, y: 60)) < 0.01)
        #expect(g.backdrop.blurWeight(at: CGPoint(x: 756, y: g.panel.maxY)) < 0.01)
    }

    @Test func theStayAndLumaRegionsGrowOnTheThreeSidesThatAreNotTheScreensEdge() throws {
        let g = try #require(NotchGeometry(display: builtIn, rowSize: row))
        #expect(g.stayRegion(margin: 16) == CGRect(x: 516, y: 0, width: 480, height: 132))
        #expect(g.backdrop.lumaRegion == CGRect(x: 516, y: 0, width: 480, height: 132))
    }

    /// The outline has two thresholds so a backdrop sitting on one cannot make it blink, and the
    /// closing spring must not overshoot, or the shape would dip below the housing on its way in.
    @Test func theOutlineHasHysteresisAndOnlyTheOpeningSpringBounces() {
        #expect(NotchGeometry.outlineAppearsBelowLuma < NotchGeometry.outlineDisappearsAboveLuma)
        #expect(NotchGeometry.outlineOpacityWithoutLuma < NotchGeometry.outlineOpacity)
        #expect(NotchGeometry.openBounce > 0)
        #expect(NotchGeometry.closeBounce <= 0)
        #expect(NotchGeometry.cellsFadeInDelay + NotchGeometry.cellsFadeIn < NotchGeometry.openDuration)
        #expect(NotchGeometry.cellsFadeOut < NotchGeometry.closeDuration)
    }
}
