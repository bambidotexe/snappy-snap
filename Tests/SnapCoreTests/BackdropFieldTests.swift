import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct BackdropFieldTests {
    /// A shape flush with the screen's top edge, as the notch shape is.
    let flush = BackdropField(silhouette: CGRect(x: 532, y: 0, width: 448, height: 116), screenTop: 0)
    /// A shape floating 3 pt under the top edge of a display that starts at y −200, as the island is.
    let floating = BackdropField(silhouette: CGRect(x: 2248, y: -197, width: 448, height: 104), screenTop: -200)

    @Test func thePanelStartsAtTheScreensEdgeAndHoldsTheFieldOnTheOtherThreeSides() {
        #expect(flush.panel == CGRect(x: 452, y: 0, width: 608, height: 196))
        #expect(floating.panel == CGRect(x: 2168, y: -200, width: 608, height: 187))
        // Under 1 % of the blur at the panel's side and bottom edges.
        #expect(floating.blurWeight(at: CGPoint(x: floating.panel.minX, y: -150)) < 0.01)
        #expect(floating.blurWeight(at: CGPoint(x: 2472, y: floating.panel.maxY)) < 0.01)
    }

    @Test func theLumaRegionGrowsOnEverySideButNeverAboveTheScreen() {
        #expect(flush.lumaRegion == CGRect(x: 516, y: 0, width: 480, height: 132))
        #expect(floating.lumaRegion == CGRect(x: 2232, y: -200, width: 480, height: 123))
    }

    /// The field is the silhouette convolved with a gaussian of σ 27: half on the edge, the normal
    /// tail outside, and towards one inside.
    @Test func theFieldIsHalfOnTheEdgeAndFallsWithTheNormalTail() {
        let onEdge = flush.blurWeight(at: CGPoint(x: 532, y: 60))
        let oneSigmaOut = flush.blurWeight(at: CGPoint(x: 505, y: 60))
        let twoSigmaBelow = flush.blurWeight(at: CGPoint(x: 756, y: 170))
        // The deepest point of a 116 pt shape is 58 pt from its nearest edge — 2.15 σ.
        let deepInside = flush.blurWeight(at: CGPoint(x: 756, y: 58))
        #expect(abs(onEdge - 0.5) < 1e-9)
        #expect(abs(oneSigmaOut - 0.158655) < 1e-5)
        #expect(abs(twoSigmaBelow - 0.022750) < 1e-5)
        #expect(abs(deepInside - 0.984149) < 1e-5)
        #expect(abs(flush.blurWeight(at: CGPoint(x: 980 + 27, y: 60)) - oneSigmaOut) < 1e-9)
    }

    /// The reach: the field is still over 1 % at 50 pt from the shape and under it at 63 pt, and the
    /// panel's margin holds that reach with the opening spring's overshoot to spare.
    @Test func theFieldHasFallenUnderOnePercentAt63PointsAndThePanelHoldsIt() {
        #expect(flush.blurWeight(at: CGPoint(x: 532 - 50, y: 60)) > 0.01)
        #expect(flush.blurWeight(at: CGPoint(x: 532 - 63, y: 60)) < 0.01)
        #expect(BackdropField.panelMargin >= 63 + 15)
    }

    @Test func signedDistanceIsEuclideanOutsideAndNegativeInside() {
        let rect = CGRect(x: 100, y: 0, width: 200, height: 100)
        #expect(BackdropField.signedDistance(from: CGPoint(x: 330, y: 140), to: rect) == 50)
        #expect(BackdropField.signedDistance(from: CGPoint(x: 60, y: 50), to: rect) == 40)
        #expect(BackdropField.signedDistance(from: CGPoint(x: 110, y: 50), to: rect) == -10)
        #expect(BackdropField.signedDistance(from: CGPoint(x: 100, y: 50), to: rect) == 0)
    }
}

@Suite struct DisplayHousingTests {
    /// A housing AppKit reports with no area is no housing.
    @Test func aHousingWithNoAreaIsNoHousing() {
        var display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 34, width: 1512, height: 889),
                                  notch: CGRect(x: 663.5, y: 0, width: 185, height: 32))
        #expect(display.housing == CGRect(x: 663.5, y: 0, width: 185, height: 32))
        display.notch = CGRect(x: 700, y: 0, width: 0, height: 32)
        #expect(display.housing == nil)
        display.notch = nil
        #expect(display.housing == nil)
    }
}
