import CoreGraphics
import Foundation

public enum AnimationCurve {
    /// Cubic ease-in-out, clamped to 0…1. Close to the system's window animation feel.
    public static func easeInOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    public static func interpolate(_ from: CGRect, _ to: CGRect, progress p: Double) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * p,
            y: from.minY + (to.minY - from.minY) * p,
            width: from.width + (to.width - from.width) * p,
            height: from.height + (to.height - from.height) * p
        )
    }
}

/// A cubic Bézier timing curve from (0, 0) to (1, 1), given by its two control points — the same four
/// numbers CSS, `CAMediaTimingFunction` and SwiftUI's `Animation.timingCurve(_:_:_:_:duration:)` take.
///
/// It is here, in the pure layer, so that an animation can be **evaluated** outside the view that
/// plays it. Snap Assist needs that: a click that arrives while the cards are still sliding has to be
/// answered against the frame each card is drawn at *now*, and the only way that answer can be right
/// is if the side that draws and the side that reads are the same curve rather than two lookalikes.
public struct UnitBezier: Hashable, Sendable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// The curve's y where its x is `x`, both clamped to 0…1 — i.e. eased progress from linear
    /// progress. x is solved for the Bézier parameter first (Newton, bisection where Newton stalls on
    /// a flat tangent, which `.easeOut`'s first control point at the origin gives it at x = 0).
    public func solve(_ x: Double) -> Double {
        let clamped = min(max(x, 0), 1)
        guard clamped > 0, clamped < 1 else { return clamped }
        return sampleY(parameter(forX: clamped))
    }

    private var cx: Double { 3 * x1 }
    private var bx: Double { 3 * (x2 - x1) - cx }
    private var ax: Double { 1 - cx - bx }
    private var cy: Double { 3 * y1 }
    private var by: Double { 3 * (y2 - y1) - cy }
    private var ay: Double { 1 - cy - by }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func parameter(forX x: Double) -> Double {
        let epsilon = 1e-7
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < epsilon { return t }
            let slope = slopeX(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        while low < high {
            let value = sampleX(t)
            if abs(value - x) < epsilon { return t }
            if x > value { low = t } else { high = t }
            let next = (high + low) / 2
            if next == t { break }
            t = next
        }
        return t
    }
}
