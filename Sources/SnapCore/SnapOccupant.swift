import CoreGraphics

/// Which way a length runs. Everything that places windows does the same arithmetic twice — once
/// across, once down — and this is what lets it be written once.
public enum SnapAxis: Hashable, Sendable {
    case horizontal
    case vertical

    var cross: SnapAxis { self == .horizontal ? .vertical : .horizontal }

    func low(_ r: CGRect) -> Double { self == .horizontal ? r.minX : r.minY }
    func high(_ r: CGRect) -> Double { self == .horizontal ? r.maxX : r.maxY }
    func length(_ s: CGSize) -> Double { self == .horizontal ? s.width : s.height }
}

/// A window on screen, as a drop sees it: where it stands, what it will not shrink below, and how far
/// back it is.
///
/// **It does not matter who put it there.** A window the user sized by hand stands where it stands
/// exactly as much as one this app snapped, so the registry is never asked; what decides whether it
/// takes part in a drop is its frame and whether it can be seen.
///
/// The frame is where the window is *now*, not any zone it was once snapped into: a window resized
/// after its snap — with the handle pill, or by its own corner — moved the divider, and the divider is
/// what the next drop has to respect.
public struct SnapOccupant: Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    /// Where the window is now, in CG space.
    public var frame: CGRect
    /// What this window will not shrink below, or **nil when nobody has measured it**. Nil is not zero.
    public var minimum: CGSize?
    /// 0 is frontmost, as `WindowInfo.zIndex`. Only the relative order is read: a window with a
    /// smaller index is in front of this one.
    public var zIndex: Int

    public init(windowID: UInt32, pid: Int32, frame: CGRect, minimum: CGSize?, zIndex: Int = 0) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
        self.minimum = minimum
        self.zIndex = zIndex
    }
}
