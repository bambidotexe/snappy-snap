import Foundation

/// When the Command key holds the handle features off the screen.
///
/// **What it buys.** The pill and the knob are drawn in the gap between two windows, which is exactly
/// where macOS puts a window's own resize edge. While a handle is on offer it claims the press, so
/// that edge cannot be reached and a single window cannot be resized by hand. Holding **Command (⌘)**
/// takes the handles away entirely — nothing drawn, nothing claimed, no cursor asserted — and the
/// press lands on the window underneath, where macOS resizes it natively. Releasing Command restores
/// the ordinary behaviour with no special case: the next hover offers a handle again.
///
/// **A drag already in flight is never suppressed.** Command answers what has *not* been grabbed yet.
/// Once a pill or a knob is being dragged, the pill is no longer an offer to take away — it is the
/// divider the user is holding, with previews and a dim behind it and two windows waiting to be
/// written on release. Suppressing that mid-gesture would drop the previews and leave the windows
/// where the last pass put them, which is a lost drag rather than a cancelled one. So a modifier
/// pressed by accident during a divider drag is invisible, and the release lands as it would have.
///
/// **Why the rule is stated once, here.** Three places ask it: the pill's suspension clause, the
/// knob's, and the moment the key goes down and both must leave the screen immediately. Three copies
/// of `commandDown && !ownDragLive` would be three chances for one of them to drift, and the one that
/// drifted would be the one that drops a live drag.
public enum HandleSuppression {
    /// True while this handle feature must show nothing and claim nothing.
    ///
    /// - Parameters:
    ///   - commandDown: whether Command is held, read from the event tap's `flagsChanged` events.
    ///   - ownDragLive: whether *this* feature's own drag is live. The pill asks about the pill's
    ///     drag and the knob about the knob's: a knob drag does not protect the pill, which stands
    ///     down for a knob drag anyway, by a different clause.
    public static func suppressed(commandDown: Bool, ownDragLive: Bool) -> Bool {
        commandDown && !ownDragLive
    }
}
