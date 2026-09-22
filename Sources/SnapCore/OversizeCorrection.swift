import CoreGraphics
import Foundation

/// The oversize watcher's rules: when a window has outgrown the gap, what it is asked for, what a
/// landing a little too large is asked for next, and when a refusal is still the same refusal.
public enum OversizeCorrection {
    /// Slack on every comparison against the available area. A window that misses the area by half a
    /// point has not been zoomed and is not worth a write.
    public static let tolerance: Double = 1

    /// The frame `frame` should be given inside `area`, or nil when it is already inside it.
    ///
    /// **Oversized means "wider than the gap leaves room for"**: bigger than the whole area minus
    /// the margin. The space a snapped window is given on an axis is `area` less the gap at each
    /// end, so anything wider than that on that axis has outgrown the arrangement and is brought
    /// back to it. The threshold is `2 * gap` off the area and is read from the gap rather than
    /// written down, so it follows the gap instead of outliving it.
    ///
    /// Asking instead for "fills or overflows the area" fires far too late: a window a gap's width
    /// short of the screen edge is already breaking the arrangement everything else in it keeps.
    /// `tolerance` is the slack that keeps a window at exactly the right size — the one this
    /// feature has just placed — from reading as oversized on the next pass.
    ///
    /// **Only the offending axis is touched.** A window as wide as the display but half its height is
    /// given the gap on the left and right and keeps its height and its top edge — the user put it
    /// there. Both axes is the ordinary case (a zoom), and it comes out as the working area inset by
    /// the gap, which is exactly where a top-edge snap would have put it.
    public static func correction(for frame: CGRect, in area: CGRect, gap: Double) -> CGRect? {
        let wide = Double(frame.width) - (Double(area.width) - 2 * gap) > tolerance
        let tall = Double(frame.height) - (Double(area.height) - 2 * gap) > tolerance
        guard wide || tall else { return nil }
        var wanted = frame
        if wide {
            wanted.origin.x = area.minX + gap
            wanted.size.width = area.width - 2 * gap
        }
        if tall {
            wanted.origin.y = area.minY + gap
            wanted.size.height = area.height - 2 * gap
        }
        return wanted
    }

    /// The second ask for a window that landed a little larger than `asked`, or nil when there is none
    /// to make.
    ///
    /// **An application that rounds its size to a grid lands up to half a cell over**: Terminal rounds
    /// to the nearest whole row and column (`HandleDragMath.roundingAllowance`), so the gap's own size
    /// comes back up to 9 pt too tall and reads as oversized. Asking for the size as far *under* as the
    /// landing was *over* rounds to the cell below, which fits inside the gap: the window ends up
    /// to one cell short of the gap rather than over it.
    ///
    /// Only an overshoot within `HandleDragMath.roundingAllowance` is asked again. More than that is a
    /// window refusing to shrink, and asking it for less would be asking it again for nothing. Each
    /// axis is decided alone, and an axis that landed inside keeps what it was asked.
    public static func gridRetry(asked: CGRect, landed: CGRect) -> CGRect? {
        let allowance = HandleDragMath.roundingAllowance
        let overWidth = Double(landed.width) - Double(asked.width)
        let overHeight = Double(landed.height) - Double(asked.height)
        guard overWidth <= allowance, overHeight <= allowance else { return nil }
        guard overWidth > tolerance || overHeight > tolerance else { return nil }
        var retry = asked
        if overWidth > tolerance { retry.size.width = asked.width - CGFloat(overWidth) }
        if overHeight > tolerance { retry.size.height = asked.height - CGFloat(overHeight) }
        return retry
    }

    /// Whether a window is still at the size it refused at. **Only the size counts**: moving a window
    /// that would not come inside is not a new size to correct, and correcting it would take it back
    /// to the gap's edge every time the user puts it somewhere else.
    public static func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(Double(a.width) - Double(b.width)) <= tolerance && abs(Double(a.height) - Double(b.height)) <= tolerance
    }
}
