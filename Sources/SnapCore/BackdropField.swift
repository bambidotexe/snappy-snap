import CoreGraphics
import Foundation

/// What is laid out around a black shape at the top of a display: the backdrop blur's field, the
/// region the backdrop's luminance is read in, and the panel that holds both. It is a function of
/// the grown shape's rectangle and of the screen's top edge, above which nothing is drawn or read.
///
/// Shared by the notch shape and the island, which differ in their silhouette and in nothing here.
public struct BackdropField: Hashable, Sendable {
    /// The variable blur's `inputRadius`. Measured with a black/white edge under the filter and
    /// luminance probes on the dark side, at radii 8, 16, 24 and 32: the blur is a gaussian whose
    /// **σ is 2 × inputRadius × the mask's alpha**, in points on a 2× display (rms error under 0.01,
    /// and linear in alpha from 0.2 to 1). So 11 is σ 22 pt at full weight and 11 pt at the shape's
    /// edge, where the field is at 0.5.
    public static let blurRadius: Double = 11
    /// The field is the silhouette convolved with a gaussian of this σ: weight 0.5 at the shape's
    /// edge, 0.23 at 20 pt, 0.10 at 35 pt, 0.03 at 50 pt, under 0.01 at 63 pt — a blur of σ 11, 5.1,
    /// 2.1, 0.7 and 0.2 pt at those distances. Only σ sets the reach: the weight on the edge is 0.5
    /// whatever it is, so the blur's strength there does not depend on it. Tuned by eye; keep
    /// `panelMargin` at its reach plus the spring's overshoot.
    public static let sigma: Double = 27
    /// What the panel keeps around the silhouette on the left, right and bottom: where the field has
    /// fallen under 1 % (63 pt), and more than an opening spring's overshoot needs (15 pt).
    public static let panelMargin: Double = 80
    /// How far around the silhouette the backdrop's luminance is read.
    public static let lumaMargin: Double = 16

    /// The grown shape's rectangle, in CG space.
    public let silhouette: CGRect
    /// The top edge of the display the shape is on.
    public let screenTop: Double

    public init(silhouette: CGRect, screenTop: Double) {
        self.silhouette = silhouette
        self.screenTop = screenTop
    }

    /// The panel the shape is drawn in. It starts at the screen's edge and never moves or resizes
    /// while the shape animates.
    public var panel: CGRect {
        CGRect(x: silhouette.minX - Self.panelMargin, y: screenTop,
               width: silhouette.width + Self.panelMargin * 2,
               height: silhouette.maxY + Self.panelMargin - screenTop)
    }

    /// Where the backdrop's luminance is read for the contrast outline.
    public var lumaRegion: CGRect {
        let top = max(screenTop, silhouette.minY - Self.lumaMargin)
        return CGRect(x: silhouette.minX - Self.lumaMargin, y: top,
                      width: silhouette.width + Self.lumaMargin * 2,
                      height: silhouette.maxY + Self.lumaMargin - top)
    }

    /// The field's weight, 0…1, at a point in CG space: the fraction of `blurRadius` the backdrop is
    /// blurred by there — 0.5 on the silhouette's edge, falling with the complementary error function
    /// outside it and rising to 1 inside, where the shape covers it anyway.
    public func blurWeight(at point: CGPoint) -> Double {
        0.5 * erfc(Self.signedDistance(from: point, to: silhouette) / (Self.sigma * 2.0.squareRoot()))
    }

    /// Distance from `point` to `rect`'s boundary: positive outside, negative inside.
    public static func signedDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if dx > 0 || dy > 0 { return (dx * dx + dy * dy).squareRoot() }
        return -min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }
}
