import Testing
import CoreGraphics
@testable import SnapCore

/// The snap bar in the notch appearance on a display with no camera housing: the same cells and the
/// same hit test, laid out inside the island, arming on its capsule.
@Suite struct SnapBarGeometryIslandTests {
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 34, width: 1512, height: 889),
                              notch: CGRect(x: 663.5, y: 0, width: 185, height: 32))
    let external = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1512, y: -175, width: 1920, height: 1055))

    var notchSettings: Settings {
        var s = Settings()
        s.snapBarAppearance = .notch
        return s
    }

    var floatingSettings: Settings {
        var s = Settings()
        s.snapBarAppearance = .bar
        return s
    }

    func bar(on display: DisplayInfo, pairing: Bool = false, settings: Settings? = nil) -> SnapBarGeometry {
        let s = settings ?? notchSettings
        return SnapBarGeometry(layouts: LayoutCatalog.snapBar, display: display, settings: s,
                               pairCell: PairCell(hasPartner: pairing, display: display, gap: s.gap))
    }

    /// The housing decides: a display that has one gets the notch shape and no island, one that has
    /// none gets the island and no notch shape, and the floating bar gets neither anywhere.
    @Test func theHousingDecidesBetweenTheNotchShapeAndTheIsland() {
        #expect(bar(on: builtIn).notch != nil)
        #expect(bar(on: builtIn).island == nil)
        #expect(bar(on: external).notch == nil)
        #expect(bar(on: external).island != nil)
        #expect(bar(on: external, settings: floatingSettings).island == nil)
        #expect(bar(on: external, settings: floatingSettings).notch == nil)
        var degenerate = builtIn
        degenerate.notch = CGRect(x: 700, y: 0, width: 0, height: 32)
        #expect(bar(on: degenerate).island != nil)
    }

    @Test func theFrameIsTheGrownIslandAndThePanelIsLargerAndFixed() throws {
        let g = bar(on: external)
        let island = try #require(g.island)
        #expect(g.frame == CGRect(x: 2244, y: -197, width: 456, height: 112))
        #expect(g.frame == island.expanded)
        #expect(g.panelFrame == CGRect(x: 2164, y: -200, width: 616, height: 195))
        #expect(bar(on: external, pairing: true).frame == CGRect(x: 2192, y: -197, width: 560, height: 112))
        #expect(bar(on: external, pairing: true).panelFrame == CGRect(x: 2112, y: -200, width: 720, height: 195))
    }

    @Test func theCellsAreInsetByThePaddingAndLocalRectsAreRelativeToThePanel() {
        let g = bar(on: external)
        #expect(g.cellRect(0) == CGRect(x: 2268, y: -173, width: 96, height: 64))
        #expect(g.cellRect(3) == CGRect(x: 2580, y: -173, width: 96, height: 64))
        #expect(g.localCellRect(0) == CGRect(x: 104, y: 27, width: 96, height: 64))
        let paired = bar(on: external, pairing: true)
        #expect(paired.pairCellRect == CGRect(x: 2216, y: -173, width: 96, height: 64))
        #expect(paired.cellRect(0) == CGRect(x: 2320, y: -173, width: 96, height: 64))
    }

    /// The whole grown island is the bar: its cells are cells, the rest of it is the background,
    /// which is Fill, and nothing outside it is a hit — not the panel, not the strip above it.
    @Test func theIslandIsTheHitRegionAndTheStripAboveItIsNot() {
        let g = bar(on: external)
        #expect(g.hit(CGPoint(x: 2472, y: -190)) == .background)
        #expect(g.hit(CGPoint(x: 2260, y: -100)) == .background)
        #expect(g.hit(CGPoint(x: 2276, y: -150)) == .cell(layoutIndex: 0, cellIndex: 0))
        #expect(g.hit(CGPoint(x: 2350, y: -150)) == .cell(layoutIndex: 0, cellIndex: 1))
        #expect(g.hit(CGPoint(x: 2472, y: -199)) == nil)
        #expect(g.panelFrame.contains(CGPoint(x: 2240, y: -150)))
        #expect(g.hit(CGPoint(x: 2240, y: -150)) == nil)
        #expect(bar(on: external, pairing: true).hit(CGPoint(x: 2230, y: -150)) == .pair)
    }

    /// It arms on the capsule's rectangle extended up to the screen's edge, and nowhere else along
    /// the edge — which still resolves to Fill, since the top zone does not know the island exists.
    @Test func itArmsOnTheCapsuleAndTheStripAboveItWhileTheTopZoneKeepsTheWholeEdge() {
        let s = notchSettings
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2472, y: -200), display: external, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2342, y: -173), display: external, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2340, y: -190), display: external, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2472, y: -171), display: external, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2000, y: -195), display: external, settings: s))
        let fill = ZoneResolver.resolve(cursor: CGPoint(x: 2472, y: -199), display: external, sharedEdges: [],
                                        barHit: nil, snapBarLayouts: LayoutCatalog.snapBar, gap: s.gap, settings: s)
        #expect(fill?.zone == Geometry.zone(display: external, layout: LayoutCatalog.fill, cellIndex: 0, gap: s.gap))
    }

    @Test func theIslandStaysGrownWhileThePointerIsInsideItsGrownRegion() {
        let g = bar(on: external)
        #expect(g.shouldShow(cursor: CGPoint(x: 2472, y: -190), display: external, visible: false))
        #expect(!g.shouldShow(cursor: CGPoint(x: 2276, y: -150), display: external, visible: false))
        #expect(g.shouldShow(cursor: CGPoint(x: 2276, y: -150), display: external, visible: true))
        #expect(g.shouldShow(cursor: CGPoint(x: 2240, y: -80), display: external, visible: true))
        #expect(g.shouldShow(cursor: CGPoint(x: 2260, y: -199.5), display: external, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 2220, y: -150), display: external, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 2472, y: -60), display: external, visible: true))
        // The top band elsewhere on the edge keeps the floating bar up; it does not keep the island.
        #expect(!g.shouldShow(cursor: CGPoint(x: 1800, y: -198), display: external, visible: true))
    }
}
