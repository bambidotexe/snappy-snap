import CoreGraphics

/// A drop on a side edge, a corner or the top of a display, as an arrangement.
///
/// **A side or a corner** (`plan`) holds the dragged window and the tiled windows standing beside it, in
/// two steps. *Taking what is free* decides the frame the dragged window would like: its zone, with
/// every edge that faces a neighbour moved to that neighbour's facing edge, one gap clear — a window on
/// the left third leaves the right two-thirds, one on the left two-thirds leaves the right third.
/// *The arrangement* then holds that frame and the neighbours where they stand, and
/// `ArrangementSolver` does the rest: a dragged window that needs more than is free takes it from its
/// neighbours down to their minimum, and what still does not fit leaves past the right or bottom edge.
///
/// A window lying *under* the zone is covered, as it is by every snapping system: it is not beside the
/// drop, it takes no part, and nothing is promised about it.
///
/// **The top** (`maximised`) holds the dragged window alone. It is a maximize, unconditionally: no
/// window on screen is consulted, none is moved, and none can make the frame smaller than the whole
/// working area.
public enum EdgeDrop {
    /// How much of the zone's extent on the other axis a window must cover before it may move one of
    /// the zone's edges. More than half: past it, the window owns more of the strip beyond that edge
    /// than it leaves free. A quarter-height window beside a full-height zone says nothing about that
    /// zone's width.
    public static let facingShare: Double = 0.5

    /// What a drop hands back: the arrangement, which of its boxes is the dragged window, and the frame
    /// that window took before any minimum was looked at.
    public struct Plan: Hashable, Sendable {
        public var arrangement: Arrangement
        public var dragged: ArrangementBox.ID
        public var freeFrame: CGRect
    }

    /// A drop on the top edge: the dragged window takes the whole working area, alone.
    ///
    /// Nothing else is in the arrangement, so nothing else can move: a window standing on a half is
    /// covered by the maximize like any other window under the zone, and it is not asked to give room
    /// because nothing is asking. The only frame the dragged window can end with other than the zone is
    /// one its own minimum forces past the right or bottom edge.
    public static func maximised(zone: CGRect, area: CGRect, gap: Double, draggedID: UInt32,
                                 draggedLimits: SizeLimits) -> Plan {
        let dragged = ArrangementBox(id: .window(draggedID), preferred: zone, limits: draggedLimits)
        return Plan(arrangement: Arrangement(area: area, gap: gap, aligned: false, boxes: [dragged]),
                    dragged: dragged.id, freeFrame: zone)
    }

    /// A drop on a side edge or a corner: the dragged window and the tiled windows standing beside it.
    public static func plan(zone: CGRect, area: CGRect, gap: Double, draggedID: UInt32, draggedLimits: SizeLimits,
                            neighbours: [SnapOccupant], fills: Bool) -> Plan {
        let beside = neighbours.filter { $0.windowID != draggedID }
        let free = freeFrame(zone: zone, area: area, gap: gap, neighbours: beside, fills: fills)
        let dragged = ArrangementBox(id: .window(draggedID), preferred: free, limits: draggedLimits)
        // A neighbour the free frame still reaches is one the zone lies over: it is covered, not beside.
        let boxes = beside.filter { apart($0.frame, free) }.map {
            ArrangementBox(id: .window($0.windowID), preferred: $0.frame,
                           limits: SizeLimits(minimum: MinimumSizePolicy.presumed($0.minimum)))
        }
        return Plan(arrangement: Arrangement(area: area, gap: gap, aligned: false, boxes: [dragged] + boxes),
                    dragged: dragged.id, freeFrame: free)
    }

    /// The zone after taking what is free, **on both axes at once**.
    ///
    /// Adjusting each axis against the nominal zone is how a corner drop grows into the window standing
    /// diagonally from it: across, towards a narrow window beside it, and down, towards a short one
    /// below it, each of which is right alone and which together reach the fourth window. So the second
    /// axis is adjusted against the extent the first has already taken, where that fourth window is in
    /// the way. Both orders are tried and the larger frame wins; a tie keeps across first.
    ///
    /// `fills` off keeps the zone: the neighbours still stand in the arrangement and still give room.
    public static func freeFrame(zone: CGRect, area: CGRect, gap: Double, neighbours: [SnapOccupant], fills: Bool) -> CGRect {
        guard fills else { return zone }
        func adjusted(first: SnapAxis) -> CGRect {
            [first, first.cross].reduce(zone) { frame, axis in
                adjust(frame, nominal: zone, on: axis, area: area, gap: gap, neighbours: neighbours)
            }
        }
        let across = adjusted(first: .horizontal)
        let down = adjusted(first: .vertical)
        return down.width * down.height > across.width * across.height + 0.5 ? down : across
    }

    private static let tolerance = ArrangementSolver.tolerance

    private static func apart(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return overlap.isNull || overlap.width <= tolerance || overlap.height <= tolerance
    }

    /// One axis of `freeFrame`, against the extent `frame` already has on the other.
    ///
    /// A neighbour stands **beside** the zone on the low side when it starts before the zone and ends
    /// before the zone's far edge — whether it is smaller than the space it was given (the zone grows)
    /// or larger (the zone shrinks). One that spans the zone is lying under it and says nothing. Where
    /// several stand on one side, the nearest facing edge is the boundary.
    ///
    /// An edge that moves **outward** stops one gap short of any other neighbour in the same rows: the
    /// one that moved it owns most of the strip, not all of it.
    private static func adjust(_ frame: CGRect, nominal zone: CGRect, on axis: SnapAxis, area: CGRect, gap: Double,
                               neighbours: [SnapOccupant]) -> CGRect {
        let cross = axis.cross
        let span = cross.high(frame) - cross.low(frame)
        func shared(_ window: SnapOccupant) -> Double {
            min(cross.high(window.frame), cross.high(frame)) - max(cross.low(window.frame), cross.low(frame))
        }
        let zoneLow = axis.low(zone), zoneHigh = axis.high(zone)
        var low = zoneLow, high = zoneHigh

        let owners = neighbours.filter { shared($0) > span * facingShare }
        if let edge = owners.filter({ axis.low($0.frame) < zoneLow - tolerance && axis.high($0.frame) < zoneHigh - tolerance })
            .map({ axis.high($0.frame) }).max() {
            low = min(max(edge + gap, axis.low(area) + gap), zoneHigh)
        }
        if let edge = owners.filter({ axis.high($0.frame) > zoneHigh + tolerance && axis.low($0.frame) > zoneLow + tolerance })
            .map({ axis.low($0.frame) }).min() {
            high = max(min(edge - gap, axis.high(area) - gap), zoneLow)
        }

        let inTheRows = neighbours.filter { shared($0) > tolerance }
        if let nearest = inTheRows.filter({ axis.high($0.frame) <= zoneLow + tolerance }).map({ axis.high($0.frame) + gap }).max() {
            low = max(low, min(zoneLow, nearest))
        }
        if let nearest = inTheRows.filter({ axis.low($0.frame) >= zoneHigh - tolerance }).map({ axis.low($0.frame) - gap }).min() {
            high = min(high, max(zoneHigh, nearest))
        }

        // Two windows that already overlap would leave a zone of nothing: keep the nominal edges and let
        // the minimums speak.
        guard high - low > tolerance else { return frame }
        return axis == .horizontal
            ? CGRect(x: low, y: frame.minY, width: high - low, height: frame.height)
            : CGRect(x: frame.minX, y: low, width: frame.width, height: high - low)
    }
}
