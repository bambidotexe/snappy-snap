import CoreGraphics

/// A concrete drop target: a cell of a layout on a display, as a frame in CG space (gap included).
public struct Zone: Hashable, Sendable {
    public var displayID: UInt32
    public var layout: Layout
    public var cellIndex: Int
    public var frame: CGRect

    public init(displayID: UInt32, layout: Layout, cellIndex: Int, frame: CGRect) {
        self.displayID = displayID
        self.layout = layout
        self.cellIndex = cellIndex
        self.frame = frame
    }

    public var cell: UnitRect { layout.cells[cellIndex] }

    /// The whole working area, in one cell: what the top edge resolves to and what nothing else
    /// resolves to. A drop on it is a maximize and holds no other window, so it is the one drop of the
    /// edge family that never reads what stands around it.
    public var isFill: Bool { layout.id == LayoutCatalog.fill.id }
}

/// The part of the zone preview's look that other geometry has to reckon with. The app layer owns
/// the rest — radius, fill, shadow — but this number is read by two layers, so it lives here once
/// rather than being written down twice.
public enum ZonePreview {
    /// Drawn *inside* the zone rect (SwiftUI `strokeBorder`), so it covers the rect's first
    /// `strokeWidth` points. That is why the snap bar's top inset has to count it.
    public static let strokeWidth: Double = 3
    /// How much more opaque the fill is on the one custom area the pointer is in than on the others.
    /// The highlight changes the fill and nothing else: same radius, same stroke, same shadow.
    public static let highlightFillWeight: Double = 2
}

public enum Geometry {

    /// `frame` translated by the smallest amount that brings it inside `display`, **never resized**.
    ///
    /// What a preview departs from when the window it comes from straddles a display seam. A preview
    /// panel is planted on one display's Space and clipped there, so a departure rectangle lying across
    /// a seam would play half its journey on a screen that panel cannot draw on. Sliding it flush
    /// against the seam keeps the window's own size and its position on the axis that does not cross —
    /// the preview leaves from the height the user is actually holding the window at.
    ///
    /// An axis already inside keeps its position exactly. An axis whose rectangle is larger than the
    /// display is left flush with the edge it overhangs, and overhangs the far one instead: being flush
    /// at the seam is the whole point, and a rectangle too big to fit cannot also be flush at the far side.
    public static func slid(_ frame: CGRect, inside display: CGRect) -> CGRect {
        var origin = frame.origin
        if frame.minX < display.minX { origin.x = display.minX }
        else if frame.maxX > display.maxX { origin.x = display.maxX - frame.width }
        if frame.minY < display.minY { origin.y = display.minY }
        else if frame.maxY > display.maxY { origin.y = display.maxY - frame.height }
        return CGRect(origin: origin, size: frame.size)
    }
    /// Where a snap onto `display` animates **from**, given the frame the window was released at.
    ///
    /// Displays have separate Spaces, so a window is drawn on one display at a time and clipped at the
    /// seam. A window released across a seam — dragged over from the display next door and let go at
    /// the edge nearest it, most of it still on the display it came from — would otherwise play its
    /// animation on that display, vanish at the seam and reappear on the target one. Slid flush
    /// against the seam first, the whole journey happens on the display it ends on; it is the
    /// departure the drop preview has already shown.
    ///
    /// **Only a frame that reaches onto another display is moved.** A window hanging past an edge with
    /// nothing beyond it is drawn where it hangs, and leaves from there.
    public static func departure(of frame: CGRect, onto display: CGRect, otherDisplays: [CGRect]) -> CGRect {
        otherDisplays.contains { $0.intersects(frame) } ? slid(frame, inside: display) : frame
    }

    /// Frame of `cell` inside `area` such that the outer inset is exactly `gap` and two
    /// adjacent cells are exactly `gap` apart. Not rounded; engines round when applying.
    public static func frame(for cell: UnitRect, in area: CGRect, gap: Double) -> CGRect {
        let half = gap / 2
        let inner = area.insetBy(dx: half, dy: half)
        let raw = CGRect(
            x: inner.minX + cell.x * inner.width,
            y: inner.minY + cell.y * inner.height,
            width: cell.width * inner.width,
            height: cell.height * inner.height
        )
        return raw.insetBy(dx: half, dy: half)
    }

    public static func zone(display: DisplayInfo, layout: Layout, cellIndex: Int, gap: Double) -> Zone {
        Zone(
            displayID: display.id,
            layout: layout,
            cellIndex: cellIndex,
            frame: frame(for: layout.cells[cellIndex], in: display.visibleFrame, gap: gap)
        )
    }

    /// Where a window of `size` belongs in `zone` — the zone's origin when it fits, and otherwise
    /// anchored to the zone's **outer** edges, the ones lying against `area`'s own.
    ///
    /// **For a write whose neighbour is then re-fitted against the result**: a handle or junction
    /// release, an oversize correction (`RefusalPolicy.anchorInward`). A window that will not shrink
    /// to the frame such a write gave it has to overhang something. Anchored to the outer edges, the
    /// overhang runs **inward**, across the divider, where the re-fit clears it. Left at the zone's
    /// origin it runs inward only for a left or top zone; for a **right** or **bottom** one the origin
    /// *is* the inner edge, so the overhang would leave the display with nothing making room for it.
    /// macOS's position clamp does not pull it back — it only keeps a 40 × 91 pt sliver of the top-left
    /// on screen, whatever the window's size.
    ///
    /// A snap does not use this. Its windows are placed by `ArrangementSolver`, which makes room among
    /// the windows of the arrangement and lets what still cannot fit hang past the right or bottom edge.
    ///
    /// The axes are independent, so a window too large on both anchors on both. Not rounded; the
    /// engine rounds when it applies a position.
    public static func anchoredOrigin(for size: CGSize, in zone: CGRect, within area: CGRect) -> CGPoint {
        CGPoint(
            x: anchored(size.width, zoneMin: zone.minX, zoneMax: zone.maxX, areaMin: area.minX, areaMax: area.maxX),
            y: anchored(size.height, zoneMin: zone.minY, zoneMax: zone.maxY, areaMin: area.minY, areaMax: area.maxY)
        )
    }

    /// One axis of `anchoredOrigin(for:in:within:)`.
    private static func anchored(_ length: Double, zoneMin: Double, zoneMax: Double,
                                 areaMin: Double, areaMax: Double) -> Double {
        // It fits: the zone's own origin, which is the frame the snap already wrote.
        guard length > zoneMax - zoneMin else { return zoneMin }
        // Bigger than the whole working area: it overhangs whichever edge we pick, so keep the
        // leading one on screen rather than pushing the title bar off the top or the left.
        guard length <= areaMax - areaMin else { return areaMin }
        // The outer edge is the zone edge nearer the area's. A tie — a zone spanning the whole axis,
        // or the middle column of three — keeps the low edge: a left zone anchors left, a top one top.
        let anchorsHigh = (areaMax - zoneMax) < (zoneMin - areaMin)
        let origin = anchorsHigh ? zoneMax - length : zoneMin
        // The tie above can still leave a window that fits the area hanging off its far edge.
        return min(max(origin, areaMin), areaMax - length)
    }
}
