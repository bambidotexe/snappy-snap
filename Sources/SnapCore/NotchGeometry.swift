import CoreGraphics
import Foundation

/// The notch appearance's geometry, in CG space: where the snap bar's black shape rests, what it
/// grows to, the panel that holds it, and the numbers that draw it. Pure arithmetic over one display
/// and one row of cells, shared by hit testing (`SnapBarGeometry`) and drawing (`NotchBarView`).
///
/// The shape has two states and nothing between them that is not an interpolation: **collapsed**, the
/// size of the display's camera housing, and **expanded**, wide and tall enough for the cell row.
/// It exists only for a display that has a housing; one that has none draws the island (`IslandGeometry`).
///
/// The drawing numbers are fitted to the reference the appearance follows — a shipping notch
/// utility's expanded shape, sampled from a 2× capture over a white window — by rendering this app's
/// own `NotchShape` offline and comparing the two edges row by row:
///
/// - the top corners are **concave** quarter circles of 17 pt that flare *outside* the body, so the
///   shape flows out of the screen's top edge (the fit is exact on every sampled row but the
///   one-pixel tip);
/// - the bottom corners are SwiftUI **continuous** corners of 34 pt (rms error 0.65 px over twelve
///   samples). A circular arc cannot fit them: the curve starts 40 pt before the corner on either
///   side while its diagonal sits under 10 pt in;
/// - the shadow is one gaussian: black at 0.60, σ 21 pt, 6 pt down. Fitted jointly to the grey
///   levels sampled over white beside the shape and below it — 24 samples out to 60 pt — it leaves an
///   rms error of half a grey level.
public struct NotchGeometry: Hashable, Sendable {
    /// Between the cell row and the shape's left and right edges.
    public static let sidePadding: Double = 20
    /// Between the housing's bottom edge and the top of the cell row: none, so the row hangs from the
    /// physical notch rather than floating under it.
    public static let rowTopGap: Double = 0
    /// Between the bottom of the cell row and the shape's bottom edge. Equal to `sidePadding`, so the
    /// row is inset the same on the three sides that are not the housing.
    public static let bottomPadding: Double = 20
    /// How far the collapsed shape sits inside the housing on either side, so that it never draws a
    /// pixel the housing does not already hide.
    public static let collapsedInset: Double = 2

    public static let collapsedTopRadius: Double = 6
    public static let collapsedBottomRadius: Double = 12
    public static let expandedTopRadius: Double = 17
    public static let expandedBottomRadius: Double = 34

    /// SwiftUI's `shadow(radius:)` is a gaussian whose σ equals the radius (measured offline through
    /// `ImageRenderer`: σ/radius 1.005–1.009 at radii 10, 20 and 40), so the measured σ is the radius.
    public static let shadowOpacity: Double = 0.60
    public static let shadowRadius: Double = 21
    public static let shadowOffsetY: Double = 6

    /// The contrast outline: a 1 pt stroke inside the shape's edge, shown while the backdrop behind the
    /// shape is too dark to read a black shape against. Two thresholds, so a backdrop sitting on one
    /// does not make the outline flicker.
    public static let outlineOpacity: Double = 0.22
    public static let outlineAppearsBelowLuma: Double = 0.18
    public static let outlineDisappearsAboveLuma: Double = 0.24
    /// With no way to read the backdrop, the outline is a constant hairline instead: faint enough to
    /// vanish over a light backdrop, enough to keep the edge over a dark one.
    public static let outlineOpacityWithoutLuma: Double = 0.10

    /// `Spring(duration:bounce:)`. Opening overshoots and settles; closing is overdamped and never
    /// crosses its target, so the shape cannot dip below the housing on its way in.
    public static let openDuration: Double = 0.5
    public static let openBounce: Double = 0.375
    public static let closeDuration: Double = 0.35
    public static let closeBounce: Double = -0.2
    /// The cells arrive after the shape has room for them and leave before it has taken it back.
    public static let cellsFadeIn: Double = 0.18
    public static let cellsFadeInDelay: Double = 0.10
    public static let cellsFadeOut: Double = 0.08

    /// The display's camera housing.
    public let housing: CGRect
    /// The shape at rest.
    public let collapsed: CGRect
    /// The shape grown to hold the cell row. This is the bar's hit region.
    public let expanded: CGRect
    /// The blur field, luminance region and panel around the grown shape.
    public let backdrop: BackdropField
    /// The panel both states are drawn in. It never moves or resizes while the shape animates.
    public let panel: CGRect

    /// Nil on a display with no camera housing.
    ///
    /// - Parameter rowSize: the cell row alone — no padding — as `SnapBarGeometry` lays it out.
    public init?(display: DisplayInfo, rowSize: CGSize) {
        guard let housing = display.housing else { return nil }
        self.housing = housing
        collapsed = CGRect(x: housing.minX + Self.collapsedInset, y: housing.minY,
                           width: housing.width - Self.collapsedInset * 2, height: housing.height)
        let width = max(housing.width, rowSize.width + Self.sidePadding * 2)
        let height = housing.height + Self.rowTopGap + rowSize.height + Self.bottomPadding
        expanded = CGRect(x: housing.midX - width / 2, y: housing.minY, width: width, height: height)
        backdrop = BackdropField(silhouette: expanded, screenTop: expanded.minY)
        panel = backdrop.panel
    }

    /// Where the cell row's top-left corner goes: centred under the housing, `rowTopGap` below it.
    public func rowOrigin(rowWidth: Double) -> CGPoint {
        CGPoint(x: expanded.midX - rowWidth / 2, y: housing.maxY + Self.rowTopGap)
    }

    /// The region the pointer has to stay in for an expanded shape to stay expanded: the shape, grown
    /// on the three sides that are not the screen's edge.
    public func stayRegion(margin: Double) -> CGRect {
        CGRect(x: expanded.minX - margin, y: expanded.minY,
               width: expanded.width + margin * 2, height: expanded.height + margin)
    }
}
