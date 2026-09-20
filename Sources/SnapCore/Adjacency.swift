import CoreGraphics

/// Two windows whose facing edges are close enough to share a handle.
public struct HandlePair: Hashable, Sendable {
    public enum Orientation: Hashable, Sendable {
        /// `a` is left of `b`; the divider is vertical.
        case horizontal
        /// `a` is above `b`; the divider is horizontal.
        case vertical
    }

    public var a: WindowInfo
    public var b: WindowInfo
    public var orientation: Orientation
    /// Signed distance between the facing edges: `b.min − a.max`. Negative means a slight overlap.
    public var gap: Double
    /// Extent shared by the two facing edges, along the divider (y for horizontal, x for vertical).
    public var overlapStart: Double
    public var overlapEnd: Double

    public init(a: WindowInfo, b: WindowInfo, orientation: Orientation, gap: Double, overlapStart: Double, overlapEnd: Double) {
        self.a = a; self.b = b; self.orientation = orientation
        self.gap = gap; self.overlapStart = overlapStart; self.overlapEnd = overlapEnd
    }

    public var overlapLength: Double { overlapEnd - overlapStart }

    /// Center of the gap on the axis perpendicular to the divider (x for horizontal, y for vertical).
    public var divider: Double {
        switch orientation {
        case .horizontal: a.frame.maxX + gap / 2
        case .vertical: a.frame.maxY + gap / 2
        }
    }

    /// The region between the facing edges over the overlap. Thickness is `|gap|`.
    public var gapRect: CGRect { band(thickness: abs(gap)) }

    /// The gap widened to at least `minThickness`, for hit testing.
    public func hoverBand(minThickness: Double) -> CGRect { band(thickness: max(abs(gap), minThickness)) }

    private func band(thickness t: Double) -> CGRect {
        switch orientation {
        case .horizontal: CGRect(x: divider - t / 2, y: overlapStart, width: t, height: overlapLength)
        case .vertical: CGRect(x: overlapStart, y: divider - t / 2, width: overlapLength, height: t)
        }
    }
}

public enum AdjacencyDetector {
    /// Slight overlaps up to 1 pt still count, to absorb rounding by the target apps.
    public static let minGap: Double = -1

    /// All handle pairs among `windows`, sorted by (a.id, b.id).
    ///
    /// No occlusion is judged here: a divider's two windows are simply the frontmost windows visible on
    /// either side of it. Where several windows compete for the same side — stacked at the same
    /// position, so their frames mutually intersect — only the frontmost of them is offered as a
    /// candidate; two windows that do not intersect each other are both offered, because they are
    /// genuinely different neighbours. Occlusion of the drawn pill is `occluder(of:…)`'s question,
    /// asked later, at the one rect that is actually shown.
    public static func pairs(in windows: [WindowInfo], maxGap: Double, minOverlap: Double) -> [HandlePair] {
        var raw: [HandlePair] = []
        for a in windows {
            for b in windows where a.id != b.id {
                if let pair = pair(a, b, .horizontal, maxGap: maxGap, minOverlap: minOverlap)
                        ?? pair(a, b, .vertical, maxGap: maxGap, minOverlap: minOverlap) {
                    raw.append(pair)
                }
            }
        }
        let result = raw.filter { candidate in !raw.contains { isDominant($0, over: candidate) } }
        return result.sorted { ($0.a.id, $0.b.id) < ($1.a.id, $1.b.id) }
    }

    /// The frontmost window that is in front of `pair.a` or `pair.b` and intersects `pillRect` — the
    /// rect the pill is actually drawn in, not the whole length of the divider. A window in front of
    /// only one of the two members still counts: it is what the user sees over the pill.
    public static func occluder(of pair: HandlePair, pillRect: CGRect, in windows: [WindowInfo]) -> WindowInfo? {
        windows
            .filter { w in
                w.id != pair.a.id && w.id != pair.b.id
                    && (w.zIndex < pair.a.zIndex || w.zIndex < pair.b.zIndex)
                    && w.frame.intersects(pillRect)
            }
            .min { $0.zIndex < $1.zIndex }
    }

    private static func pair(_ a: WindowInfo, _ b: WindowInfo, _ orientation: HandlePair.Orientation,
                             maxGap: Double, minOverlap: Double) -> HandlePair? {
        let gap: Double, start: Double, end: Double
        switch orientation {
        case .horizontal:
            gap = b.frame.minX - a.frame.maxX
            start = max(a.frame.minY, b.frame.minY)
            end = min(a.frame.maxY, b.frame.maxY)
        case .vertical:
            gap = b.frame.minY - a.frame.maxY
            start = max(a.frame.minX, b.frame.minX)
            end = min(a.frame.maxX, b.frame.maxX)
        }
        guard gap >= minGap, gap <= maxGap, end - start >= minOverlap else { return nil }
        return HandlePair(a: a, b: b, orientation: orientation, gap: gap, overlapStart: start, overlapEnd: end)
    }

    /// Whether `other` beats `candidate` for the same slot: they share an anchor on one side of the
    /// divider (the same `a` or the same `b`) while disagreeing on the other, and `other`'s free-side
    /// window is in front of and intersects `candidate`'s — the "stacked identical frames" case.
    /// Windows that do not intersect are different neighbours, not competitors, and both stand.
    private static func isDominant(_ other: HandlePair, over candidate: HandlePair) -> Bool {
        guard other.orientation == candidate.orientation else { return false }
        if other.a.id == candidate.a.id, other.b.id != candidate.b.id,
           other.b.zIndex < candidate.b.zIndex, other.b.frame.intersects(candidate.b.frame) {
            return true
        }
        if other.b.id == candidate.b.id, other.a.id != candidate.a.id,
           other.a.zIndex < candidate.a.zIndex, other.a.frame.intersects(candidate.a.frame) {
            return true
        }
        return false
    }
}
