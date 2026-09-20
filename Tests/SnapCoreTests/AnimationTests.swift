import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct AnimationCurveTests {
    @Test func endpointsAndMidpoint() {
        #expect(AnimationCurve.easeInOut(0) == 0)
        #expect(AnimationCurve.easeInOut(1) == 1)
        #expect(abs(AnimationCurve.easeInOut(0.5) - 0.5) < 1e-9)
    }

    @Test func clampsOutsideZeroOne() {
        #expect(AnimationCurve.easeInOut(-1) == 0)
        #expect(AnimationCurve.easeInOut(2) == 1)
    }

    @Test func isMonotonic() {
        var last = -1.0
        for i in 0...100 {
            let v = AnimationCurve.easeInOut(Double(i) / 100)
            #expect(v >= last)
            last = v
        }
    }

    @Test func interpolateRects() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 200, y: 50, width: 300, height: 500)
        #expect(AnimationCurve.interpolate(from, to, progress: 0) == from)
        #expect(AnimationCurve.interpolate(from, to, progress: 1) == to)
        #expect(AnimationCurve.interpolate(from, to, progress: 0.5) == CGRect(x: 100, y: 25, width: 200, height: 300))
    }
}

/// `UnitBezier` exists so that a curve a view *plays* can also be *read* — Snap Assist hit-tests a
/// click against where a card is drawn part way through its reflow. What it has to get right is
/// therefore not "a plausible ease" but the actual shape of the four control points it is given.
@Suite struct UnitBezierTests {
    /// The control points of SwiftUI's `.easeOut` / CSS `ease-out`, which is the one Snap Assist uses.
    let easeOut = UnitBezier(0, 0, 0.58, 1)
    let linear = UnitBezier(0, 0, 1, 1)

    @Test func theEndsAreTheEndsAndOutsideThemItClamps() {
        #expect(easeOut.solve(0) == 0)
        #expect(easeOut.solve(1) == 1)
        #expect(easeOut.solve(-0.5) == 0)
        #expect(easeOut.solve(2) == 1)
    }

    /// A straight line through its own control points is the check that the solver is solving rather
    /// than approximating: every x must come back as itself, to the solver's own tolerance.
    @Test func aStraightLineIsTheIdentity() {
        for i in 0...50 {
            let x = Double(i) / 50
            #expect(abs(linear.solve(x) - x) < 1e-6, "x = \(x)")
        }
    }

    @Test func isMonotonic() {
        var last = -1.0
        for i in 0...200 {
            let value = easeOut.solve(Double(i) / 200)
            #expect(value >= last, "at \(Double(i) / 200)")
            last = value
        }
    }

    /// "Ease **out**" means fast first: the curve is above the straight line everywhere between the
    /// ends. This is the assertion that would fail if the control points were ever typed in the wrong
    /// order — the mistake that would put the hit test a card's width away from the drawing.
    @Test func easeOutRunsAheadOfLinearThroughout() {
        for i in 1...99 {
            let x = Double(i) / 100
            #expect(easeOut.solve(x) > x, "at \(x)")
        }
        // Reference values for this exact curve, so a change of control points cannot pass silently.
        #expect(abs(easeOut.solve(0.25) - 0.378138) < 1e-4)
        #expect(abs(easeOut.solve(0.5) - 0.684643) < 1e-4)
        #expect(abs(easeOut.solve(0.75) - 0.906535) < 1e-4)
    }

    /// The flat tangent at the origin is where Newton's method stalls; a curve with one at each end
    /// exercises both the stall and the bisection that has to cover for it.
    @Test func aCurveFlatAtBothEndsStillSolves() {
        let easeInOut = UnitBezier(0.42, 0, 0.58, 1)
        #expect(abs(easeInOut.solve(0.5) - 0.5) < 1e-6)
        var last = -1.0
        for i in 0...100 {
            let value = easeInOut.solve(Double(i) / 100)
            #expect(value >= last && value <= 1)
            last = value
        }
    }
}
