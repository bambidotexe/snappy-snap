import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct ZoneResolverTests {
    // Display A: 1440×900 laptop, menu bar 25, Dock 75. Display B: 1920×1080 to its right.
    let a = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800))
    let b = DisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                        visibleFrame: CGRect(x: 1440, y: 25, width: 1920, height: 1055))
    let gap = 8.0

    func resolve(_ x: Double, _ y: Double, display: DisplayInfo? = nil, shared: Set<Edge> = [],
                 bar: SnapBarHit? = nil, pairing: Bool = false,
                 settings: Settings = Settings(), sticky: Double = 0,
                 option: Bool = false) -> ZoneResolution? {
        let display = display ?? a
        return ZoneResolver.resolve(cursor: CGPoint(x: x, y: y), display: display, sharedEdges: shared,
                                    barHit: bar, snapBarLayouts: LayoutCatalog.snapBar,
                                    pairCell: PairCell(hasPartner: pairing, display: display, gap: gap),
                                    gap: gap, settings: settings, stickyBand: sticky,
                                    optionHeld: option)
    }

    /// Settings with Option's halves switched on; everything else shipped.
    var withOption: Settings {
        var s = Settings()
        s.optionHalves = true
        return s
    }

    func expectZone(_ r: ZoneResolution?, _ layout: Layout, _ index: Int,
                    origin: ZoneOrigin = .screenEdge, display: DisplayInfo? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = ZoneResolution(zone: Geometry.zone(display: display ?? a, layout: layout, cellIndex: index, gap: gap),
                                      origin: origin)
        #expect(r == expected, sourceLocation: sourceLocation)
    }

    @Test func leftEdgeGivesLeftHalf() {
        expectZone(resolve(0, 450), LayoutCatalog.halves, 0)
        expectZone(resolve(1, 450), LayoutCatalog.halves, 0)
    }

    @Test func beyondTheBandIsNothing() { #expect(resolve(25, 450) == nil) }

    @Test func rightEdgeGivesRightHalf() { expectZone(resolve(1439, 450), LayoutCatalog.halves, 1) }

    @Test func cornersOnSideEdges() {
        expectZone(resolve(0, 50), LayoutCatalog.grid2x2, 0)
        expectZone(resolve(0, 120), LayoutCatalog.grid2x2, 0)
        expectZone(resolve(0, 121), LayoutCatalog.halves, 0)
        expectZone(resolve(0, 899), LayoutCatalog.grid2x2, 2)
        expectZone(resolve(1439, 30), LayoutCatalog.grid2x2, 1)
        expectZone(resolve(1439, 880), LayoutCatalog.grid2x2, 3)
    }

    @Test func cornersOnTopEdge() {
        expectZone(resolve(100, 0), LayoutCatalog.grid2x2, 0)
        expectZone(resolve(1400, 0), LayoutCatalog.grid2x2, 1)
    }

    @Test func topEdgeMiddleIsFill() {
        expectZone(resolve(700, 0), LayoutCatalog.fill, 0)
        expectZone(resolve(700, 1), LayoutCatalog.fill, 0)
    }

    @Test func bottomEdgeAndMiddleDoNothing() {
        #expect(resolve(700, 899) == nil)
        #expect(resolve(700, 450) == nil)
    }

    @Test func disabledRulesFallThrough() {
        var s = Settings()
        s.corners = false
        expectZone(resolve(0, 50, settings: s), LayoutCatalog.halves, 0)
        s.sideHalves = false
        #expect(resolve(0, 450, settings: s) == nil)
        s.topFill = false
        #expect(resolve(700, 0, settings: s) == nil)
    }

    @Test func snapBarHitWinsOverEdges() {
        expectZone(resolve(0, 450, bar: .cell(layoutIndex: 2, cellIndex: 1)), LayoutCatalog.leftHalfRightQuarters, 1,
                   origin: .snapBar)
        expectZone(resolve(700, 300, bar: .background), LayoutCatalog.fill, 0, origin: .snapBar)
        #expect(resolve(700, 300, bar: .cell(layoutIndex: 9, cellIndex: 0)) == nil)
    }

    /// A drop in the pair cell places the dragged window on the left and the partner on the
    /// right — both halves from one hit, and both are the halves layout's own zones, so the drop is
    /// indistinguishable from a drop on the bar's halves cell.
    @Test func thePairCellResolvesBothHalvesAtOnce() {
        let left = Geometry.zone(display: a, layout: LayoutCatalog.halves, cellIndex: 0, gap: gap)
        let right = Geometry.zone(display: a, layout: LayoutCatalog.halves, cellIndex: 1, gap: gap)
        #expect(resolve(700, 60, bar: .pair, pairing: true)
            == ZoneResolution(zone: left, origin: .pairCell, partnerZone: right))
        // The zone is the one a halves drop would produce, including its layout id and cell index.
        #expect(resolve(700, 60, bar: .pair, pairing: true)?.zone
            == resolve(700, 60, bar: .cell(layoutIndex: 0, cellIndex: 0))?.zone)
    }

    /// The sides never depend on where the drop landed — so every point of the cell yields **one
    /// identical value**, which is what keeps the zone from being dropped and re-acquired as the
    /// cursor crosses the gap between the halves.
    @Test func everyPointOfThePairCellResolvesToTheSameThing() {
        let one = resolve(700, 60, bar: .pair, pairing: true)
        #expect(one != nil)
        // Different cursor positions, same bar hit: the resolution cannot vary with the cursor, because
        // nothing it is built from reads the cursor.
        for (x, y) in [(500.0, 56.0), (700.0, 60.0), (900.0, 120.0)] {
            #expect(resolve(x, y, bar: .pair, pairing: true) == one)
        }
    }

    /// The pair cell is conditional, and the resolver is told whether the bar has one rather than
    /// assuming it: a pair hit that could not have come from a bar the user saw places nothing.
    @Test func aPairHitWithoutAPairCellResolvesToNothing() {
        #expect(resolve(700, 60, bar: .pair) == nil)
    }

    /// A pair drop must not start a choosing phase. Its own origin is how that is expressed, so
    /// nothing else can be `.pairCell` and it cannot be `.snapBar`; and `partnerZone` is nil for
    /// every resolution that is not a pair drop, including the plain halves cell that lands a
    /// window in exactly the same frame.
    @Test func onlyAPairDropCarriesAPairOriginAndAPartnerZone() {
        #expect(resolve(700, 60, bar: .pair, pairing: true)?.origin == .pairCell)
        let others = [resolve(700, 60, bar: .cell(layoutIndex: 0, cellIndex: 0), pairing: true),
                      resolve(700, 300, bar: .background, pairing: true),
                      resolve(0, 450, pairing: true), resolve(700, 0, pairing: true)]
        for other in others {
            #expect(other?.origin != .pairCell)
            #expect(other?.partnerZone == nil)
        }
    }

    @Test func snapBarDisabledIgnoresHit() {
        var s = Settings()
        s.snapBar = false
        expectZone(resolve(0, 450, bar: .background, settings: s), LayoutCatalog.halves, 0)
        // The pair cell is part of the bar, so it goes with it: the left edge answers instead, and with
        // no partner zone — a drop there must place one window, not two.
        expectZone(resolve(0, 450, bar: .pair, pairing: true, settings: s), LayoutCatalog.halves, 0)
        #expect(resolve(0, 450, bar: .pair, pairing: true, settings: s)?.partnerZone == nil)
    }

    /// Snap Assist runs after a drop made from the snap bar and after nothing else, so a resolution
    /// has to say which it is — and every edge, corner and top zone has to say `.screenEdge`,
    /// including the ones the bar can also produce.
    @Test func onlyTheBarResolvesWithASnapBarOrigin() {
        #expect(resolve(0, 450, bar: .cell(layoutIndex: 0, cellIndex: 0))?.origin == .snapBar)
        #expect(resolve(700, 300, bar: .background)?.origin == .snapBar)
        for edge in [resolve(0, 450), resolve(1439, 450), resolve(700, 0), resolve(0, 50), resolve(1439, 880)] {
            #expect(edge?.origin == .screenEdge)
        }
        // Same layout and cell from either route: the zone alone cannot tell them apart.
        #expect(resolve(0, 450)?.zone == resolve(0, 450, bar: .cell(layoutIndex: 0, cellIndex: 0))?.zone)
    }

    /// A shared edge arms on the same terms as any other — no setting, no dwell — within a band of
    /// `sharedEdgeBand` rather than `edgeBand`.
    @Test func aSharedEdgeArmsLikeAnyOtherWithinTheWiderBand() {
        let s = Settings()
        expectZone(resolve(1441, 500, display: b, shared: [.left]), LayoutCatalog.halves, 0, display: b)
        expectZone(resolve(1440 + s.sharedEdgeBand, 500, display: b, shared: [.left]), LayoutCatalog.halves, 0, display: b)
        #expect(resolve(1441 + s.sharedEdgeBand, 500, display: b, shared: [.left]) == nil)
        // A corner on a shared edge is a corner like any other.
        expectZone(resolve(1441, 50, display: b, shared: [.left]), LayoutCatalog.grid2x2, 0, display: b)
    }

    /// The band is the only difference, and it applies to the shared edge alone: display B's own
    /// right edge faces nothing and keeps the ordinary 24 pt.
    @Test func anOuterEdgeOfADisplayWithANeighbourKeepsTheNarrowBand() {
        let s = Settings()
        expectZone(resolve(3359, 500, display: b, shared: [.left]), LayoutCatalog.halves, 1, display: b)
        expectZone(resolve(3360 - s.edgeBand, 500, display: b, shared: [.left]), LayoutCatalog.halves, 1, display: b)
        #expect(resolve(3359 - s.edgeBand, 500, display: b, shared: [.left]) == nil)
    }

    /// The point of the whole rule: a lone display and a display with a neighbour resolve the same
    /// point to the same zone, the wider band aside.
    @Test func aDisplayResolvesTheSameWhetherOrNotItHasANeighbour() {
        for (x, y) in [(1441.0, 500.0), (1450.0, 50.0), (3359.0, 500.0), (2400.0, 26.0)] {
            #expect(resolve(x, y, display: b, shared: [.left])?.zone
                        == resolve(x, y, display: b, shared: [])?.zone)
        }
    }

    @Test func sharedEdgesAreDetectedBetweenDisplays() {
        #expect(a.sharedEdges(among: [a, b]) == [.right])
        #expect(b.sharedEdges(among: [a, b]) == [.left])
        #expect(a.sharedEdges(among: [a]) == [])
        let below = DisplayInfo(id: 3, frame: CGRect(x: 100, y: 900, width: 800, height: 600),
                                visibleFrame: CGRect(x: 100, y: 900, width: 800, height: 600))
        #expect(a.sharedEdges(among: [a, below]) == [.bottom])
        #expect(below.sharedEdges(among: [a, below]) == [.top])
    }

    @Test func defaultBandActivatesWithoutTouchingTheEdge() {
        let s = Settings()                                                   // edgeBand 24
        expectZone(resolve(20, 450, settings: s), LayoutCatalog.halves, 0)
        expectZone(resolve(24, 450, settings: s), LayoutCatalog.halves, 0)
        #expect(resolve(25, 450, settings: s) == nil)
        expectZone(resolve(1416, 450, settings: s), LayoutCatalog.halves, 1)
        expectZone(resolve(700, 20, settings: s), LayoutCatalog.fill, 0)
        expectZone(resolve(20, 50, settings: s), LayoutCatalog.grid2x2, 0)   // corner inside the band
    }

    @Test func hysteresisKeepsAnActiveZoneALittleFurtherOut() {
        let s = Settings()
        expectZone(resolve(36, 450, settings: s, sticky: ZoneResolver.releaseHysteresis), LayoutCatalog.halves, 0)
        #expect(resolve(37, 450, settings: s, sticky: ZoneResolver.releaseHysteresis) == nil)
        #expect(resolve(30, 450, settings: s) == nil)                        // not active → plain band
    }

    @Test func hysteresisCountsFromTheSharedEdgesOwnBand() {
        let s = Settings()
        let outermost = 1440 + s.sharedEdgeBand + ZoneResolver.releaseHysteresis
        expectZone(resolve(outermost, 500, display: b, shared: [.left], sticky: ZoneResolver.releaseHysteresis),
                   LayoutCatalog.halves, 0, display: b)
        #expect(resolve(outermost + 1, 500, display: b, shared: [.left], sticky: ZoneResolver.releaseHysteresis) == nil)
    }

    // MARK: - Option's halves

    /// Display A is 1440 wide, so its midpoint is 720. With Option held every point that is not a
    /// corner or the top band is a half, however far it stands from the edge.
    @Test func optionGrowsTheSideBandsUntilTheyMeetInTheMiddle() {
        expectZone(resolve(1, 450, settings: withOption, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(400, 450, settings: withOption, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(719, 450, settings: withOption, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(720, 450, settings: withOption, option: true), LayoutCatalog.halves, 1)
        expectZone(resolve(1000, 450, settings: withOption, option: true), LayoutCatalog.halves, 1)
        expectZone(resolve(1439, 450, settings: withOption, option: true), LayoutCatalog.halves, 1)
    }

    /// The one boundary in the resolver with no hysteresis. A sticky centre reads as a dead band the
    /// pointer has to overshoot to leave and overshoot again to come back to.
    @Test func theCentreLineHasNoHysteresisWhicheverHalfIsArmed() {
        let sticky = ZoneResolver.releaseHysteresis
        expectZone(resolve(719, 450, settings: withOption, sticky: sticky, option: true),
                   LayoutCatalog.halves, 0)
        expectZone(resolve(720, 450, settings: withOption, sticky: sticky, option: true),
                   LayoutCatalog.halves, 1)
    }

    /// Corners keep their own geometry: the ordinary edge band crossed with the corner band, and
    /// nothing wider. So a point 300 in from the left and 60 down is the left half, not a quarter.
    @Test func optionLeavesTheCornersExactlyWhereTheyWere() {
        expectZone(resolve(10, 60, settings: withOption, option: true), LayoutCatalog.grid2x2, 0)
        expectZone(resolve(10, 860, settings: withOption, option: true), LayoutCatalog.grid2x2, 2)
        expectZone(resolve(1430, 60, settings: withOption, option: true), LayoutCatalog.grid2x2, 1)
        expectZone(resolve(300, 60, settings: withOption, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(300, 860, settings: withOption, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(1000, 60, settings: withOption, option: true), LayoutCatalog.halves, 1)
    }

    /// Fill keeps its own 24 pt band and is resolved ahead of the grown halves, which would otherwise
    /// swallow it and leave no way to maximize with the key held.
    @Test func optionLeavesTheTopBandReachable() {
        expectZone(resolve(400, 20, settings: withOption, option: true), LayoutCatalog.fill, 0)
        expectZone(resolve(1000, 20, settings: withOption, option: true), LayoutCatalog.fill, 0)
        expectZone(resolve(400, 25, settings: withOption, option: true), LayoutCatalog.halves, 0)
    }

    /// With Fill switched off the top band is a half like everywhere else, rather than nothing.
    @Test func optionFillsTheTopBandWithAHalfWhenFillIsOff() {
        var s = withOption
        s.topFill = false
        expectZone(resolve(400, 5, settings: s, option: true), LayoutCatalog.halves, 0)
        expectZone(resolve(1000, 5, settings: s, option: true), LayoutCatalog.halves, 1)
    }

    /// Display B stands to A's right, so its left edge is shared and arms from 48 pt rather than 24.
    /// Option suspends that: both halves of B meet at B's own midpoint, 1440 + 960 = 2400.
    @Test func optionSplitsASharedEdgeDisplayExactlyInHalf() {
        expectZone(resolve(2399, 500, display: b, shared: [.left], settings: withOption, option: true),
                   LayoutCatalog.halves, 0, display: b)
        expectZone(resolve(2400, 500, display: b, shared: [.left], settings: withOption, option: true),
                   LayoutCatalog.halves, 1, display: b)
        // And the shared band still arms nothing wider than the midpoint on the far side of it.
        expectZone(resolve(1500, 500, display: b, shared: [.left], settings: withOption, option: true),
                   LayoutCatalog.halves, 0, display: b)
    }

    /// Two switches govern it, and either one off leaves the ordinary narrow bands alone.
    @Test func optionDoesNothingWithEitherSwitchOff() {
        #expect(resolve(400, 450, settings: Settings(), option: true) == nil)
        var noHalves = withOption
        noHalves.sideHalves = false
        #expect(resolve(400, 450, settings: noHalves, option: true) == nil)
        #expect(resolve(400, 450, settings: withOption) == nil)
    }

    /// The bar outranks Option as it outranks everything. The drag session takes the bar off the
    /// screen while the key is held and hands in no hit, but a hit handed in is still the answer.
    @Test func aBarHitStillOutranksOptionsHalves() {
        expectZone(resolve(700, 10, bar: .cell(layoutIndex: 0, cellIndex: 0), settings: withOption,
                           option: true),
                   LayoutCatalog.snapBar[0], 0, origin: .snapBar)
    }
}
