import Testing
import CoreGraphics
@testable import SnapCore

/// The snap bar in the notch appearance: the same cells and the same hit test, laid out inside the
/// grown shape, and arming on the housing alone.
@Suite struct SnapBarGeometryNotchTests {
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 34, width: 1512, height: 889),
                              notch: CGRect(x: 663.5, y: 0, width: 185, height: 32))

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

    func bar(on display: DisplayInfo? = nil, pairing: Bool = false, settings: Settings? = nil) -> SnapBarGeometry {
        let s = settings ?? notchSettings
        let display = display ?? builtIn
        return SnapBarGeometry(layouts: LayoutCatalog.snapBar, display: display, settings: s,
                               pairCell: PairCell(hasPartner: pairing, display: display, gap: s.gap))
    }

    @Test func theFrameIsTheGrownShapeAndThePanelIsLargerAndFixed() throws {
        let g = bar()
        let notch = try #require(g.notch)
        #expect(g.frame == CGRect(x: 532, y: 0, width: 448, height: 116))
        #expect(g.frame == notch.expanded)
        #expect(g.panelFrame == CGRect(x: 452, y: 0, width: 608, height: 196))
        // The pair cell widens the shape by one cell and one spacing, and the panel with it.
        #expect(bar(pairing: true).frame == CGRect(x: 480, y: 0, width: 552, height: 116))
        #expect(bar(pairing: true).panelFrame == CGRect(x: 400, y: 0, width: 712, height: 196))
    }

    /// The floating bar is untouched by the notch appearance existing: no notch geometry, and a panel
    /// that is the bar's own frame.
    @Test func theFloatingBarHasNoNotchAndItsPanelIsItsFrame() {
        let g = bar(settings: floatingSettings)
        #expect(g.notch == nil)
        #expect(g.panelFrame == g.frame)
        #expect(g.localCellRect(0) == CGRect(x: 12, y: 12, width: 96, height: 64))
    }

    @Test func theCellsAreCentredUnderTheHousingAndLocalRectsAreRelativeToThePanel() {
        let g = bar()
        // Row 408 wide centred on 756 → 552; hanging from the housing's bottom edge at 32.
        #expect(g.cellRect(0) == CGRect(x: 552, y: 32, width: 96, height: 64))
        #expect(g.cellRect(3) == CGRect(x: 864, y: 32, width: 96, height: 64))
        // The view is panel-sized, so what it draws is relative to the panel, not to the shape.
        #expect(g.localCellRect(0) == CGRect(x: 100, y: 32, width: 96, height: 64))
        let paired = bar(pairing: true)
        #expect(paired.pairCellRect == CGRect(x: 500, y: 32, width: 96, height: 64))
        #expect(paired.cellRect(0) == CGRect(x: 604, y: 32, width: 96, height: 64))
        #expect(paired.localPairCellRect == CGRect(x: 100, y: 32, width: 96, height: 64))
    }

    /// The whole grown shape is the bar: its cells are cells, the rest of it — the housing included —
    /// is the background, which is Fill, and nothing outside it is a hit even inside the panel.
    @Test func theShapeIsTheHitRegionAndThePanelAroundItIsNot() {
        let g = bar()
        #expect(g.hit(CGPoint(x: 756, y: 10)) == .background)
        #expect(g.hit(CGPoint(x: 540, y: 110)) == .background)
        #expect(g.hit(CGPoint(x: 560, y: 70)) == .cell(layoutIndex: 0, cellIndex: 0))
        #expect(g.hit(CGPoint(x: 640, y: 70)) == .cell(layoutIndex: 0, cellIndex: 1))
        #expect(g.panelFrame.contains(CGPoint(x: 500, y: 60)))
        #expect(g.hit(CGPoint(x: 500, y: 60)) == nil)
        #expect(g.hit(CGPoint(x: 756, y: 130)) == nil)
        #expect(bar(pairing: true).hit(CGPoint(x: 548, y: 70)) == .pair)
    }

    /// The floating bar arms on the top zone's band; the notch shape arms on the housing alone, so in
    /// that appearance the edge away from the housing offers Fill and no bar.
    @Test func theNotchArmsOnTheHousingAloneWhileTheTopZoneKeepsTheWholeEdge() {
        let s = notchSettings
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 756, y: 10), display: builtIn, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 664, y: 31), display: builtIn, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 663, y: 10), display: builtIn, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 756, y: 33), display: builtIn, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 300, y: 5), display: builtIn, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 300, y: 5), display: builtIn, settings: floatingSettings))
        // The same point still resolves to Fill: the top zone does not know the appearance exists.
        let fill = ZoneResolver.resolve(cursor: CGPoint(x: 300, y: 5), display: builtIn, sharedEdges: [],
                                        barHit: nil, snapBarLayouts: LayoutCatalog.snapBar, gap: s.gap, settings: s)
        #expect(fill?.zone == Geometry.zone(display: builtIn, layout: LayoutCatalog.fill, cellIndex: 0, gap: s.gap))
    }

    /// Armed inside the housing; kept while the pointer is inside the grown shape plus 16 pt on the
    /// three sides that are not the screen's edge. The housing is inside that region, so there is no
    /// strip where the shape opens and closes again.
    @Test func theShapeStaysWhileThePointerIsInsideItsGrownRegion() {
        let g = bar()
        #expect(g.shouldShow(cursor: CGPoint(x: 756, y: 10), display: builtIn, visible: false))
        #expect(!g.shouldShow(cursor: CGPoint(x: 560, y: 70), display: builtIn, visible: false))
        #expect(g.shouldShow(cursor: CGPoint(x: 560, y: 70), display: builtIn, visible: true))
        #expect(g.shouldShow(cursor: CGPoint(x: 520, y: 130), display: builtIn, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 510, y: 60), display: builtIn, visible: true))
        #expect(!g.shouldShow(cursor: CGPoint(x: 756, y: 140), display: builtIn, visible: true))
        // The top band elsewhere on the edge keeps the floating bar up; it does not keep the shape.
        #expect(!g.shouldShow(cursor: CGPoint(x: 300, y: 5), display: builtIn, visible: true))
    }
}
