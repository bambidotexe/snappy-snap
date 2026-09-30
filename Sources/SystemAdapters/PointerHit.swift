import AppKit
import CoreGraphics

/// What the window server says is under a point: the window a click there would reach, and who owns
/// it. Public API, no permission, no window name.
///
/// Measured: the hit test **skips click-through windows** (a mouse-taking panel under a click-through
/// one at level 1000 is the answer, not the overlay), and it **skips a window at alpha 0 or 0.02**, so
/// an overlay fading in is not hit for its first frames. A call costs 0.05 ms; the owner lookup
/// 0.12 ms.
@MainActor
public enum PointerHit {
    /// The number of the frontmost window a click at `point` (CG space) would reach, or of the
    /// frontmost one **below** `window` when a window number is given. 0 when there is none.
    public static func windowNumber(at point: CGPoint, below window: Int = 0) -> Int {
        // The vertical flip is its own inverse: the same transform takes CG space to Cocoa.
        let cocoa = CoordinateSpace.cgPoint(fromCocoa: point)
        return NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: window)
    }

    /// The process that owns a window, or nil for 0 or a window the list no longer carries.
    public static func ownerPID(ofWindow number: Int) -> pid_t? {
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number))
                          as? [[String: Any]])?.first else { return nil }
        return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    /// The frontmost application's process, the one whose windows set their own cursor.
    public static var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
