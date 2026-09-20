import AppKit

/// Converts between Cocoa coordinates (origin bottom-left of the primary display, y up)
/// and CG space (origin top-left of the primary display, y down). Everything in
/// SnapCore is CG space; only NSScreen/NSWindow use Cocoa.
public enum CoordinateSpace {
    /// Height of the primary display (index 0 in `NSScreen.screens`, the one at origin).
    @MainActor public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    public static func cgRect(fromCocoa r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // The vertical flip is its own inverse, so converting the other way is the same transform.
    public static func cocoaRect(fromCG r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        cgRect(fromCocoa: r, primaryHeight: h)
    }

    public static func cgPoint(fromCocoa p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    @MainActor public static func cgRect(fromCocoa r: CGRect) -> CGRect { cgRect(fromCocoa: r, primaryHeight: primaryHeight) }
    @MainActor public static func cocoaRect(fromCG r: CGRect) -> CGRect { cocoaRect(fromCG: r, primaryHeight: primaryHeight) }
    @MainActor public static func cgPoint(fromCocoa p: CGPoint) -> CGPoint { cgPoint(fromCocoa: p, primaryHeight: primaryHeight) }
}
