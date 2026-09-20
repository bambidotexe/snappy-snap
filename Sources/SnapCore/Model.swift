import CoreGraphics

/// A display in CG space (origin top-left of the primary display, y down).
public struct DisplayInfo: Hashable, Sendable {
    public var id: UInt32
    /// Full display bounds. The cursor can reach every point of it.
    public var frame: CGRect
    /// Working area: `frame` minus menu bar and Dock. Windows are placed inside it.
    public var visibleFrame: CGRect
    /// The camera housing at the top of the display, in CG space, or nil on a display that has none.
    /// Measured on the built-in 1512 × 982 display: x 663.5, y 0, 185 × 32.
    public var notch: CGRect?
    /// `NSScreen.localizedName`, handed over as a plain value because SnapCore never imports AppKit.
    /// Empty when nothing said.
    public var name: String
    /// Whether macOS reports this as the built-in display (`CGDisplayIsBuiltin`), handed over as a plain
    /// value because SnapCore asks macOS nothing.
    public var isBuiltIn: Bool

    /// The camera housing when the display has one with any area — AppKit can report a housing of no
    /// width — and nil otherwise. It is what decides between the notch shape and the island.
    public var housing: CGRect? {
        guard let notch, notch.width > 0, notch.height > 0 else { return nil }
        return notch
    }

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, notch: CGRect? = nil, name: String = "",
                isBuiltIn: Bool = false) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notch = notch
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

/// An on-screen window of a regular app, from the CoreGraphics window list.
public struct WindowInfo: Hashable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var frame: CGRect
    /// 0 is frontmost. Only the relative order is meaningful.
    public var zIndex: Int

    public init(id: UInt32, pid: Int32, frame: CGRect, zIndex: Int) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.zIndex = zIndex
    }
}

public enum Edge: Hashable, Sendable, CaseIterable {
    case left, right, top, bottom
}

extension CGRect {
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rounds x, y, width and height independently to the nearest integer point.
    public func roundedToPoints() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    public func isApproximatelyEqual(to other: CGRect, tolerance: Double) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

extension DisplayInfo {
    /// Edges of this display that touch another display (within 1 pt) with some overlap along the edge.
    public func sharedEdges(among displays: [DisplayInfo]) -> Set<Edge> {
        var edges = Set<Edge>()
        for other in displays where other.id != id {
            let verticalOverlap = min(frame.maxY, other.frame.maxY) - max(frame.minY, other.frame.minY)
            let horizontalOverlap = min(frame.maxX, other.frame.maxX) - max(frame.minX, other.frame.minX)
            if verticalOverlap > 0 {
                if abs(other.frame.minX - frame.maxX) <= 1 { edges.insert(.right) }
                if abs(other.frame.maxX - frame.minX) <= 1 { edges.insert(.left) }
            }
            if horizontalOverlap > 0 {
                if abs(other.frame.minY - frame.maxY) <= 1 { edges.insert(.bottom) }
                if abs(other.frame.maxY - frame.minY) <= 1 { edges.insert(.top) }
            }
        }
        return edges
    }
}
