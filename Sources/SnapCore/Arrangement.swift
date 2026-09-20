import CoreGraphics

/// What a window will and will not take, as far as anybody knows.
public struct SizeLimits: Hashable, Sendable {
    /// What it will not go below: a measured minimum, or what an unmeasured window is presumed to take
    /// (`MinimumSizePolicy.presumedFloor`). Never "unknown" — an arrangement has to be solved with a number.
    public var minimum: CGSize
    /// What it will not grow beyond on that axis, or nil when nothing says it has a limit. macOS
    /// publishes no maximum size either, so this is only ever learned from a landing that came back
    /// smaller than it was asked for.
    public var maximumWidth: Double?
    public var maximumHeight: Double?

    public init(minimum: CGSize, maximumWidth: Double? = nil, maximumHeight: Double? = nil) {
        self.minimum = minimum
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }
}

/// One participant of an arrangement: a window, or a cell nobody has been put in yet.
public struct ArrangementBox: Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case window(UInt32)
        /// A still-open cell of a layout, by its index.
        case cell(Int)
    }

    public var id: ID
    /// The frame this box would like, in CG space, gap included: its layout cell, or for a window that
    /// is merely standing beside a drop, where it stands.
    public var preferred: CGRect
    public var limits: SizeLimits

    public init(id: ID, preferred: CGRect, limits: SizeLimits) {
        self.id = id
        self.preferred = preferred
        self.limits = limits
    }
}

/// Windows and open cells that have to share one working area without overlapping.
///
/// Every snap is one of these. What differs between a snap-bar drop, a Snap Assist pick and a drop on
/// an edge is only **who is in it**: a bar drop holds the chosen layout and nothing that was on screen
/// before; an edge drop holds the dragged window and the tiled windows beside it.
public struct Arrangement: Hashable, Sendable {
    public var area: CGRect
    public var gap: Double
    /// True for a layout: every edge standing at one coordinate is one divider, so a grid stays a
    /// grid and the other row follows when one window needs room. False for an edge drop: only the
    /// facing edges of two boxes are one divider, so a row is never resized for the sake of a window
    /// in another row.
    public var aligned: Bool
    public var boxes: [ArrangementBox]

    public init(area: CGRect, gap: Double, aligned: Bool, boxes: [ArrangementBox]) {
        self.area = area
        self.gap = gap
        self.aligned = aligned
        self.boxes = boxes
    }

    public func solve() -> ArrangementSolution { ArrangementSolver.solve(self) }
}

public struct ArrangementSolution: Hashable, Sendable {
    /// Where every box goes, in CG space, gap included. Not rounded.
    public var frames: [ArrangementBox.ID: CGRect]

    public init(frames: [ArrangementBox.ID: CGRect]) {
        self.frames = frames
    }

    /// How far `id` runs past the right and the bottom of `area`'s gap. Zero for a box that is inside.
    public func overflow(of id: ArrangementBox.ID, in area: CGRect, gap: Double) -> CGSize {
        guard let frame = frames[id] else { return .zero }
        return CGSize(width: max(0, frame.maxX - (area.maxX - gap)),
                      height: max(0, frame.maxY - (area.maxY - gap)))
    }
}

/// Where the boxes of an arrangement go.
///
/// The rules, in the order they yield to each other, one axis at a time:
///
/// 1. Nothing starts before the working area's left or top edge.
/// 2. Every box gets at least its minimum.
/// 3. Boxes that stand apart stay apart, in the order they were in.
/// 4. Everything stays inside the working area — given up only when 1–3 cannot otherwise hold, by the
///    smallest amount that makes them hold, and **only past the right or the bottom edge**. A window
///    that cannot fit hangs off the display; it never overlaps its neighbour in the middle of it.
/// 5. A divider stays where it is preferred, and when it is forced it moves the least it can.
///
/// **Dividers are the variables.** Frames are grown by half a gap and the area shrunk by half a gap,
/// so neighbours share an exact edge (`Geometry.frame(for:in:gap:)` builds cells the same way) and a
/// minimum is the window's own plus one gap. Every constraint is then a difference between two lines —
/// a box's minimum, `X[hi] − X[lo] ≥ minimum`; two boxes in order, `X[lo of the later] − X[hi of the
/// earlier] ≥ 0` — which a longest path solves exactly: the path from the low edge is the earliest a
/// line can stand, the path to the high edge the latest, and the amount by which the first exceeds the
/// second anywhere is the overflow, which is thereby the smallest possible.
///
/// **Overflow is per box, not per line.** The area's own high edge never moves. A box that ends at it
/// and cannot fit runs past it alone, and every other box ending there stays inside.
///
/// A maximum yields to a minimum: a hole beside a window that will not grow is better than an overlap
/// with one that will not shrink.
///
/// Nothing here rounds; the engine rounds when it applies a frame.
public enum ArrangementSolver {
    /// How far apart two coordinates may be and still be the same edge, and how little two boxes may
    /// share of an axis and still not be facing each other.
    public static let tolerance: Double = 1

    public static func solve(_ arrangement: Arrangement) -> ArrangementSolution {
        let half = arrangement.gap / 2
        let area = arrangement.area.insetBy(dx: half, dy: half)
        var frames: [ArrangementBox.ID: CGRect] = [:]
        var raws: [Raw] = []
        for box in arrangement.boxes {
            // A box with no size is not standing anywhere: it constrains nothing and is handed back.
            guard box.preferred.width > tolerance, box.preferred.height > tolerance else {
                frames[box.id] = box.preferred
                continue
            }
            raws.append(Raw(box: box, gap: arrangement.gap))
        }

        // The axes are solved on their own, which is exact for boxes that face each other and blind to
        // a pair standing diagonally: one that grows on both axes can reach the other. Such a pair is
        // put in order on the axis where it takes the smaller push, and the axes are solved again.
        var ordered: [SnapAxis: [Ordering]] = [.horizontal: [], .vertical: []]
        var solved = solveAxes(raws, area: area, aligned: arrangement.aligned, ordered: ordered)
        for _ in 0..<(2 * raws.count * raws.count) {
            guard let collision = firstCollision(raws, solved, gap: arrangement.gap) else { break }
            guard !ordered[collision.axis, default: []].contains(collision.ordering) else { break }
            ordered[collision.axis, default: []].append(collision.ordering)
            solved = solveAxes(raws, area: area, aligned: arrangement.aligned, ordered: ordered)
        }

        for (raw, rect) in zip(raws, solved) {
            frames[raw.id] = rect.insetBy(dx: half, dy: half)
        }
        return ArrangementSolution(frames: frames)
    }

    // MARK: - Two axes

    /// A box in the solver's own space: grown by half a gap, its limits grown by a whole one.
    private struct Raw {
        let id: ArrangementBox.ID
        /// The frame as it is on screen: what decides whether two boxes stand apart, face each other,
        /// and in which order.
        let real: CGRect
        /// The frame grown by half a gap: what the dividers are read from.
        let rect: CGRect
        let minimum: CGSize
        let maximumWidth: Double?
        let maximumHeight: Double?

        init(box: ArrangementBox, gap: Double) {
            id = box.id
            real = box.preferred
            rect = box.preferred.insetBy(dx: -gap / 2, dy: -gap / 2)
            // Never under a point: a box that has been pushed along must not come out of it with no size.
            minimum = CGSize(width: max(box.limits.minimum.width, 1) + gap, height: max(box.limits.minimum.height, 1) + gap)
            maximumWidth = box.limits.maximumWidth.map { $0 + gap }
            maximumHeight = box.limits.maximumHeight.map { $0 + gap }
        }

        func span(_ axis: SnapAxis) -> Span {
            Span(low: axis.low(rect), high: axis.high(rect), realLow: axis.low(real), realHigh: axis.high(real),
                 crossLow: axis.cross.low(real), crossHigh: axis.cross.high(real),
                 minimum: axis.length(minimum), maximum: axis == .horizontal ? maximumWidth : maximumHeight)
        }
    }

    /// "`first` stands wholly before `second` on this axis", by index into the boxes.
    private struct Ordering: Hashable {
        let first: Int
        let second: Int
    }

    private static func solveAxes(_ raws: [Raw], area: CGRect, aligned: Bool, ordered: [SnapAxis: [Ordering]]) -> [CGRect] {
        let xs = solve(raws.map { $0.span(.horizontal) }, areaLow: area.minX, areaHigh: area.maxX,
                       aligned: aligned, ordered: ordered[.horizontal] ?? [])
        let ys = solve(raws.map { $0.span(.vertical) }, areaLow: area.minY, areaHigh: area.maxY,
                       aligned: aligned, ordered: ordered[.vertical] ?? [])
        return raws.indices.map { CGRect(x: xs[$0].low, y: ys[$0].low, width: xs[$0].high - xs[$0].low, height: ys[$0].high - ys[$0].low) }
    }

    /// A solved frame as it will be on screen: the half gap it was grown by taken off again.
    private static func onScreen(_ solved: CGRect, gap: Double) -> CGRect {
        solved.insetBy(dx: gap / 2, dy: gap / 2)
    }

    private static func apart(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return overlap.isNull || overlap.width <= tolerance || overlap.height <= tolerance
    }

    /// The first two boxes that stood apart and no longer do, with the axis to put them in order on:
    /// the one on which their order is known and the overlap is the smaller, horizontal on a tie.
    private static func firstCollision(_ raws: [Raw], _ solved: [CGRect], gap: Double) -> (axis: SnapAxis, ordering: Ordering)? {
        for i in raws.indices {
            for j in raws.indices where i < j {
                guard apart(raws[i].real, raws[j].real),
                      !apart(onScreen(solved[i], gap: gap), onScreen(solved[j], gap: gap)) else { continue }
                var best: (axis: SnapAxis, ordering: Ordering, depth: Double)?
                for axis in [SnapAxis.horizontal, .vertical] {
                    let ordering: Ordering
                    if axis.high(raws[i].real) <= axis.low(raws[j].real) + tolerance {
                        ordering = Ordering(first: i, second: j)
                    } else if axis.high(raws[j].real) <= axis.low(raws[i].real) + tolerance {
                        ordering = Ordering(first: j, second: i)
                    } else {
                        continue
                    }
                    let depth = min(axis.high(solved[i]), axis.high(solved[j])) - max(axis.low(solved[i]), axis.low(solved[j]))
                    if best == nil || depth < best!.depth { best = (axis, ordering, depth) }
                }
                if let best { return (best.axis, best.ordering) }
            }
        }
        return nil
    }

    // MARK: - One axis

    private struct Span {
        /// The edges the dividers are read from: the frame grown by half a gap.
        let low: Double
        let high: Double
        /// The edges as they are on screen, and the extent on the other axis likewise.
        let realLow: Double
        let realHigh: Double
        let crossLow: Double
        let crossHigh: Double
        let minimum: Double
        let maximum: Double?

        func faces(_ other: Span) -> Bool {
            min(crossHigh, other.crossHigh) - max(crossLow, other.crossLow) > tolerance
        }
    }

    private struct Line {
        var preferred: Double
        /// Standing on one of the area's own edges, which never move.
        var atAreaLow = false
        var atAreaHigh = false
        var isFixed: Bool { atAreaLow || atAreaHigh }
    }

    /// `X[to] − X[from] ≥ weight`.
    private struct Constraint {
        let from: Int
        let to: Int
        let weight: Double
    }

    private static func solve(_ spans: [Span], areaLow: Double, areaHigh: Double, aligned: Bool,
                              ordered: [Ordering]) -> [(low: Double, high: Double)] {
        guard !spans.isEmpty else { return [] }
        let (lines, lowLine, highLine) = lines(of: spans, areaLow: areaLow, areaHigh: areaHigh, aligned: aligned)

        var constraints: [Constraint] = []
        for index in spans.indices where lowLine[index] != highLine[index] {
            constraints.append(Constraint(from: lowLine[index], to: highLine[index], weight: spans[index].minimum))
        }
        // Two boxes in order stay in order, one gap apart — or as far apart as they already are when
        // that is less: windows tiled by something that leaves no gap touch each other, and grown by
        // half a gap they overlap. They are still two windows in an order; the weight below is what
        // keeps them from being pulled apart when nothing needs room, and from passing through each
        // other when something does.
        func order(_ first: Int, before second: Int) {
            guard highLine[first] != lowLine[second] else { return }
            constraints.append(Constraint(from: highLine[first], to: lowLine[second],
                                          weight: min(0, spans[second].low - spans[first].high)))
        }
        for i in spans.indices {
            for j in spans.indices where i != j && spans[i].faces(spans[j])
                && spans[i].realHigh <= spans[j].realLow + tolerance {
                order(i, before: j)
            }
        }
        for ordering in ordered { order(ordering.first, before: ordering.second) }

        let sequence = topologicalOrder(lines, constraints)
        let floor = lines.map { $0.atAreaLow ? areaLow : $0.atAreaHigh ? areaHigh : min(areaLow, $0.preferred) }
        let ceiling = lines.map { $0.atAreaLow ? areaLow : $0.atAreaHigh ? areaHigh : max(areaHigh, $0.preferred) }

        // The earliest each line can stand, the latest, and the smallest overflow that reconciles them.
        var earliest = floor
        for k in sequence where !lines[k].isFixed {
            for c in constraints where c.to == k { earliest[k] = max(earliest[k], earliest[c.from] + c.weight) }
        }
        var latest = ceiling
        for k in sequence.reversed() where !lines[k].isFixed {
            for c in constraints where c.from == k { latest[k] = min(latest[k], latest[c.to] - c.weight) }
        }
        let overflow = max(0, lines.indices.filter { !lines[$0].isFixed }.map { earliest[$0] - latest[$0] }.max() ?? 0)

        var position = floor
        for k in sequence where !lines[k].isFixed {
            var low = floor[k]
            for c in constraints where c.to == k { low = max(low, position[c.from] + c.weight) }
            var want = lines[k].preferred
            for index in spans.indices {
                let span = spans[index]
                // A box between two dividers that needs more than its share takes it from both sides
                // evenly; whatever one side cannot give, the bounds ask of the other.
                if lowLine[index] == k, !lines[highLine[index]].isFixed {
                    let deficit = span.minimum - (lines[highLine[index]].preferred - lines[k].preferred)
                    if deficit > tolerance { want = min(want, lines[k].preferred - deficit / 2) }
                }
                // A box that will not grow lets its divider come in, so that its neighbour fills.
                if highLine[index] == k, let maximum = span.maximum {
                    want = min(want, position[lowLine[index]] + maximum)
                }
            }
            for index in spans.indices where lowLine[index] == k && lines[highLine[index]].atAreaHigh {
                if let maximum = spans[index].maximum { want = max(want, areaHigh - maximum) }
            }
            position[k] = min(max(want, low), latest[k] + overflow)
        }

        return spans.indices.map { index in
            let span = spans[index]
            let low = position[lowLine[index]]
            var high = position[highLine[index]]
            if lines[highLine[index]].atAreaHigh { high = max(areaHigh, low + span.minimum) }
            if let maximum = span.maximum { high = max(low + span.minimum, min(high, low + maximum)) }
            return (low, high)
        }
    }

    /// The dividers of one axis, and for each box the line its low and its high edge stand on.
    ///
    /// Aligned: every edge within `tolerance` of another is the same line, whoever it belongs to.
    /// Otherwise only an edge and the edge **facing** it across a divider are. Either way an edge on
    /// one of the area's own edges stands on that edge exactly.
    private static func lines(of spans: [Span], areaLow: Double, areaHigh: Double, aligned: Bool)
        -> (lines: [Line], lowLine: [Int], highLine: [Int]) {
        // Edge `2 * box` is its low edge, `2 * box + 1` its high one.
        let values = spans.flatMap { [$0.low, $0.high] }
        var group = Array(values.indices)
        func root(_ edge: Int) -> Int {
            var edge = edge
            while group[edge] != edge { edge = group[edge] }
            return edge
        }
        func join(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { group[max(ra, rb)] = min(ra, rb) }
        }

        if aligned {
            let sorted = values.indices.sorted { values[$0] < values[$1] || (values[$0] == values[$1] && $0 < $1) }
            var start = sorted[0]
            for edge in sorted.dropFirst() {
                if values[edge] - values[start] <= tolerance { join(start, edge) } else { start = edge }
            }
        } else {
            for i in spans.indices {
                for j in spans.indices where i != j && spans[i].faces(spans[j])
                    && abs(spans[i].high - spans[j].low) <= tolerance {
                    join(2 * i + 1, 2 * j)
                }
            }
        }

        var lines: [Line] = []
        var lineOfRoot: [Int: Int] = [:]
        var lineOfEdge = Array(repeating: 0, count: values.count)
        for edge in values.indices {
            let r = root(edge)
            if lineOfRoot[r] == nil {
                lineOfRoot[r] = lines.count
                lines.append(Line(preferred: values[r]))
            }
            let line = lineOfRoot[r]!
            lineOfEdge[edge] = line
            // A box *starts* on the area's low edge and *ends* on its high one. A box lying outside the
            // area whose far edge merely touches the near edge of the area is not standing on it, and
            // pinning that edge would hold the box under its minimum.
            let isLowEdge = edge % 2 == 0
            if isLowEdge, abs(values[edge] - areaLow) <= tolerance { lines[line].atAreaLow = true }
            if !isLowEdge, abs(values[edge] - areaHigh) <= tolerance { lines[line].atAreaHigh = true }
        }
        for index in lines.indices {
            if lines[index].atAreaLow { lines[index].preferred = areaLow }
            if lines[index].atAreaHigh { lines[index].preferred = areaHigh }
        }
        return (lines, spans.indices.map { lineOfEdge[2 * $0] }, spans.indices.map { lineOfEdge[2 * $0 + 1] })
    }

    /// The lines in an order no constraint runs against, lowest preferred position first among those
    /// that are ready. Every constraint runs from an earlier edge to a later one, so there is no cycle;
    /// a line left over by one all the same is placed by its position.
    private static func topologicalOrder(_ lines: [Line], _ constraints: [Constraint]) -> [Int] {
        var pending = Array(repeating: 0, count: lines.count)
        for c in constraints { pending[c.to] += 1 }
        var remaining = Set(lines.indices)
        var order: [Int] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { pending[$0] == 0 }
            let next = (ready.isEmpty ? remaining : ready).min {
                (lines[$0].preferred, $0) < (lines[$1].preferred, $1)
            }!
            remaining.remove(next)
            order.append(next)
            for c in constraints where c.from == next { pending[c.to] -= 1 }
        }
        return order
    }
}
