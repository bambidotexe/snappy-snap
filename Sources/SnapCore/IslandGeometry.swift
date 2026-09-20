import CoreGraphics
import Foundation

/// The island's geometry, in CG space: the notch appearance on a display with no camera housing.
/// A black capsule floats under the top edge for the length of a drag and grows to hold the cell
/// row. Pure arithmetic over one display and one row of cells, shared by hit testing
/// (`SnapBarGeometry`) and drawing (`IslandBarView`). The motion between the states is
/// `IslandPresence`'s.
///
/// The numbers follow the island a shipping notch utility draws on such a display, so that ours,
/// drawn above it, passes for the same object. They were traced row by row from captures of a 1×
/// display (1 px = 1 pt) and fitted by rendering `Path(roundedRect:cornerSize:style:)` offline:
///
/// - the reference island rests 3 pt under the screen's top edge, 25 pt tall, in all of its states;
/// - its ends are **continuous** corners of 12.5 pt (rms error 0.49 px; a circular arc, 0.69);
/// - grown, its four corners are **continuous** corners of 38 pt (rms 0.81 px; circular, 1.57);
/// - its widest resting state, the volume indicator, is 246 pt.
public struct IslandGeometry: Hashable, Sendable {
    /// Between the screen's top edge and the island, in every state.
    public static let topGap: Double = 3
    /// The capsule's height, and the circle's diameter.
    public static let height: Double = 25
    /// The reference utility's widest resting island.
    public static let referenceWidestWidth: Double = 246
    /// What the capsule keeps beyond the reference's widest on either side, so that nothing the
    /// reference shows at rest — nor the overshoot of its own springs — is seen around ours.
    public static let coverMargin: Double = 8
    public static let collapsedWidth: Double = referenceWidestWidth + coverMargin * 2
    /// Between the cell row and the grown shape's edge, the same on all four sides: no side of the
    /// island is the screen's edge or a camera housing. 24 pt is what the 38 pt corner asks for: along
    /// the corner's diagonal a cell's 8 pt corner then stands 21.5 pt from the shape's curve — about
    /// what 20 pt gives along a straight edge — where 20 pt of padding left it 16.
    public static let padding: Double = 24
    public static let collapsedRadius: Double = 12.5
    public static let expandedRadius: Double = 38
    /// The grown shape's shadow. The notch shape's numbers, fitted to the same utility over a white
    /// window at 2×: a capture of the island's own shadow has not been measured.
    public static let shadowOpacity: Double = 0.60
    public static let shadowRadius: Double = 21
    public static let shadowOffsetY: Double = 6

    /// The circle the island arrives from and departs through.
    public let circle: CGRect
    /// The capsule, up for the length of a drag.
    public let collapsed: CGRect
    /// The shape grown to hold the cell row. This is the bar's hit region.
    public let expanded: CGRect
    /// Where the pointer has to be held for the island to grow.
    public let armRegion: CGRect
    /// The blur field, luminance region and panel around the grown shape.
    public let backdrop: BackdropField

    /// The panel every state is drawn in. It never moves or resizes while the shape animates.
    public var panel: CGRect { backdrop.panel }

    /// - Parameter rowSize: the cell row alone — no padding — as `SnapBarGeometry` lays it out.
    public init(display: DisplayInfo, rowSize: CGSize) {
        let top = display.frame.minY + Self.topGap
        let midX = display.frame.midX
        circle = CGRect(x: midX - Self.height / 2, y: top, width: Self.height, height: Self.height)
        collapsed = CGRect(x: midX - Self.collapsedWidth / 2, y: top, width: Self.collapsedWidth, height: Self.height)
        let width = max(Self.collapsedWidth, rowSize.width + Self.padding * 2)
        expanded = CGRect(x: midX - width / 2, y: top, width: width, height: rowSize.height + Self.padding * 2)
        armRegion = Self.armRegion(of: display)
        backdrop = BackdropField(silhouette: expanded, screenTop: display.frame.minY)
    }

    /// The arming region alone — the capsule's rectangle extended up to the screen's top edge — for
    /// the test that runs on every drag event while the bar is down and must not build a whole
    /// geometry to answer.
    public static func armRegion(of display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.midX - collapsedWidth / 2, y: display.frame.minY,
               width: collapsedWidth, height: topGap + height)
    }

    /// Where the cell row's top-left corner goes: centred, `padding` under the shape's top edge.
    public func rowOrigin(rowWidth: Double) -> CGPoint {
        CGPoint(x: expanded.midX - rowWidth / 2, y: expanded.minY + Self.padding)
    }

    /// The region the pointer has to stay in for a grown island to stay grown: the shape, grown on
    /// its left, right and bottom, and up to the screen's edge above it.
    public func stayRegion(margin: Double) -> CGRect {
        let top = backdrop.screenTop
        return CGRect(x: expanded.minX - margin, y: top,
                      width: expanded.width + margin * 2, height: expanded.maxY + margin - top)
    }

    /// The rect a state is drawn in. `hidden` is the circle: what hides it is its scale.
    public func rect(for state: IslandState) -> CGRect {
        switch state {
        case .hidden, .circle: circle
        case .capsule: collapsed
        case .expanded: expanded
        }
    }
}
