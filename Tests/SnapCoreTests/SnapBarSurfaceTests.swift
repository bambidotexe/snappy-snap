import Testing
import CoreGraphics
@testable import SnapCore

/// What each appearance comes to on a display with a camera housing and on one without, and that the
/// geometry, the arming test and the top zone all follow the surface rather than the setting.
@Suite struct SnapBarSurfaceTests {
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 34, width: 1512, height: 889),
                              notch: CGRect(x: 663.5, y: 0, width: 185, height: 32))
    let external = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1512, y: -175, width: 1920, height: 1055))

    func settings(_ appearance: SnapBarAppearance) -> Settings {
        var s = Settings()
        s.snapBarAppearance = appearance
        return s
    }

    func bar(_ appearance: SnapBarAppearance, on display: DisplayInfo) -> SnapBarGeometry {
        let s = settings(appearance)
        return SnapBarGeometry(layouts: LayoutCatalog.snapBar, display: display, settings: s,
                               pairCell: PairCell(hasPartner: false, display: display, gap: s.gap))
    }

    @Test func theHousingDecidesWhatEachAppearanceComesTo() {
        #expect(SnapBarAppearance.bar.surface(on: builtIn) == .floatingBar)
        #expect(SnapBarAppearance.bar.surface(on: external) == .floatingBar)
        #expect(SnapBarAppearance.notch.surface(on: builtIn) == .notchShape)
        #expect(SnapBarAppearance.notch.surface(on: external) == .island)
        #expect(SnapBarAppearance.notchOrBar.surface(on: builtIn) == .notchShape)
        #expect(SnapBarAppearance.notchOrBar.surface(on: external) == .floatingBar)
        // A housing AppKit reports with no area is no housing.
        var degenerate = builtIn
        degenerate.notch = CGRect(x: 700, y: 0, width: 0, height: 32)
        #expect(SnapBarAppearance.notch.surface(on: degenerate) == .island)
        #expect(SnapBarAppearance.notchOrBar.surface(on: degenerate) == .floatingBar)
    }

    /// Settings draws each appearance on a MacBook and on an external display, which it knows only by
    /// whether they have a housing. That is the same rule a real display gets, not a second one.
    @Test func aDisplayKnownOnlyByItsHousingGetsTheSameSurface() {
        for appearance in SnapBarAppearance.allCases {
            #expect(appearance.surface(withHousing: true) == appearance.surface(on: builtIn))
            #expect(appearance.surface(withHousing: false) == appearance.surface(on: external))
        }
    }

    /// The geometry is built for the surface, and says which one it was built for.
    @Test func theGeometryFollowsTheSurface() {
        for appearance in SnapBarAppearance.allCases {
            for display in [builtIn, external] {
                #expect(bar(appearance, on: display).surface == appearance.surface(on: display))
            }
        }
        // The mixed appearance on a display with no housing is the floating bar exactly: the same
        // frame, a panel that is its frame, and neither black shape.
        let mixed = bar(.notchOrBar, on: external)
        #expect(mixed.notch == nil)
        #expect(mixed.island == nil)
        #expect(mixed.panelFrame == mixed.frame)
        #expect(mixed.frame == bar(.bar, on: external).frame)
        // And on a display with a housing it is the notch shape exactly.
        #expect(bar(.notchOrBar, on: builtIn).frame == bar(.notch, on: builtIn).frame)
        #expect(bar(.notchOrBar, on: builtIn).panelFrame == bar(.notch, on: builtIn).panelFrame)
    }

    /// The mixed appearance arms on the housing where there is one and on the top band elsewhere — and
    /// never on the island's capsule, which it does not draw.
    @Test func theMixedAppearanceArmsLikeTheSurfaceItDraws() {
        let s = settings(.notchOrBar)
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 756, y: 10), display: builtIn, settings: s))
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 300, y: 5), display: builtIn, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2000, y: -195), display: external, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2472, y: -195), display: external, settings: s))
        // 26 pt under the top edge is inside the island's arming region, which is 28 pt tall, and
        // outside the top band, which is 24.
        #expect(s.edgeBand < 26)
        #expect(!SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2472, y: -174), display: external, settings: s))
        #expect(SnapBarGeometry.isWithinArmingBand(cursor: CGPoint(x: 2472, y: -174), display: external,
                                                   settings: settings(.notch)))
    }
}
