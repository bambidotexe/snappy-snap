import CoreGraphics

/// How much of a window the windows in front of it leave to be seen — from frames and stacking order
/// alone, which is all the window list gives without Screen Recording.
public enum Occlusion {
    /// The share of `frame`'s area that no rectangle in `covers` hides: 1 with nothing in front of it,
    /// 0 when it is covered entirely. Covers that overlap each other hide their common part once.
    ///
    /// The edges of the covers cut `frame` into a grid of cells, each of which is either wholly hidden
    /// or wholly visible, so the answer is exact. A desktop has tens of windows at most.
    public static func visibleFraction(of frame: CGRect, under covers: [CGRect]) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let hiding = covers.map { $0.intersection(frame) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !hiding.isEmpty else { return 1 }
        let xs = Set(hiding.flatMap { [Double($0.minX), Double($0.maxX)] } + [Double(frame.minX), Double(frame.maxX)]).sorted()
        let ys = Set(hiding.flatMap { [Double($0.minY), Double($0.maxY)] } + [Double(frame.minY), Double(frame.maxY)]).sorted()
        var hidden = 0.0
        for (left, right) in zip(xs, xs.dropFirst()) {
            for (top, bottom) in zip(ys, ys.dropFirst()) {
                let centre = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
                if hiding.contains(where: { $0.contains(centre) }) { hidden += (right - left) * (bottom - top) }
            }
        }
        return max(0, 1 - hidden / (Double(frame.width) * Double(frame.height)))
    }
}

/// Which windows a drop on an edge treats as standing beside it: the ones it takes the free space
/// from, and asks for room when the dragged window needs more than is free.
///
/// **A neighbour looks tiled and can be seen.** Standing against one side of the working area is what
/// any window does that was pushed up under the menu bar or into a corner of the screen, and a drop
/// whose edge was pulled to such a window is a drop nobody can predict; a window nobody can see is a
/// divider nobody can see. So a neighbour stands inside the working area, against **at least two** of
/// its sides — a half stands against three, a quarter or a middle column against two — and at least
/// half of it is not covered by the windows in front of it.
///
/// Who placed it is not asked. A window the user tiled by hand counts exactly as one this app snapped.
public enum NeighbourEvidence {
    /// How far beyond the gap a window's edge may be from the working area's and still stand against
    /// it: a window placed by another tool, or by hand, is never exactly one gap away.
    public static let alignmentSlack: Double = 4
    public static let requiredSides = 2
    /// No measurement establishes this number. It is "the user can see most of it", stated as a share.
    public static let requiredVisibleFraction = 0.5
    /// How far outside the working area a frame may reach and still be inside it.
    public static let areaTolerance: Double = 1

    /// Why a window is not a neighbour. `description` is what the drag logs.
    public enum Rejection: Hashable, Sendable, CustomStringConvertible {
        case outsideTheArea
        case touches(sides: Int)
        case hidden(visible: Double)

        public var description: String {
            switch self {
            case .outsideTheArea: "it reaches outside the working area"
            case .touches(let sides): "it stands against \(sides) side(s) of the working area, not \(NeighbourEvidence.requiredSides)"
            case .hidden(let visible): "only \(Int((visible * 100).rounded())) % of it is visible"
            }
        }
    }

    /// How many sides of `area` the frame stands against: anywhere from flush with it to one gap and
    /// `alignmentSlack` inside it.
    public static func alignedSides(of frame: CGRect, in area: CGRect, gap: Double) -> Int {
        let reach = max(gap, 0) + alignmentSlack
        return [frame.minX - area.minX, area.maxX - frame.maxX, frame.minY - area.minY, area.maxY - frame.maxY]
            .filter { $0 <= reach }.count
    }

    /// Nil when `window` counts as a neighbour. `others` is every other window on screen, with the
    /// dragged one left out: it is about to be somewhere else, and what it covers now says nothing.
    public static func rejection(of window: SnapOccupant, among others: [SnapOccupant], area: CGRect, gap: Double) -> Rejection? {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0,
              frame.minX >= area.minX - areaTolerance, frame.maxX <= area.maxX + areaTolerance,
              frame.minY >= area.minY - areaTolerance, frame.maxY <= area.maxY + areaTolerance else {
            return .outsideTheArea
        }
        let sides = alignedSides(of: frame, in: area, gap: gap)
        guard sides >= requiredSides else { return .touches(sides: sides) }
        let inFront = others.filter { $0.windowID != window.windowID && $0.zIndex < window.zIndex }.map(\.frame)
        let visible = Occlusion.visibleFraction(of: frame, under: inFront)
        guard visible >= requiredVisibleFraction else { return .hidden(visible: visible) }
        return nil
    }

    /// `windows` split into the neighbours and, for the log, the rest with the reason each was left out.
    public static func neighbours(among windows: [SnapOccupant], area: CGRect, gap: Double)
        -> (accepted: [SnapOccupant], rejected: [(window: SnapOccupant, reason: Rejection)]) {
        var accepted: [SnapOccupant] = []
        var rejected: [(window: SnapOccupant, reason: Rejection)] = []
        for window in windows {
            if let reason = rejection(of: window, among: windows, area: area, gap: gap) {
                rejected.append((window, reason))
            } else {
                accepted.append(window)
            }
        }
        return (accepted, rejected)
    }
}
