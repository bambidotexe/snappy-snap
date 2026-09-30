/// The two decisions around the cursor a pill or a knob sets, made from window numbers and process
/// ids the window server hands back. The measurements behind them are `pitfalls.md` 58.
public enum HandleCursor {
    /// Whether something the user can click sits **in front of** the handle at the pointer: a menu, a
    /// menu-bar application's popover, Control Center. `topmost` is the window a click there would
    /// reach, `belowHandle` the one it would reach if the handle were not there.
    ///
    /// Neither answer is taken alone. The window server skips a window at alpha 0 — and one at 0.02 —
    /// so for the first frames of the fade-in a click reaches the window *under* the handle, which is
    /// not a covered handle. Only a window that is neither the handle nor what lies beneath it covers
    /// it. The hit test also skips click-through windows, so a transparent overlay drawn over a whole
    /// display covers nothing.
    public static func isCovered(topmost: Int, belowHandle: Int, handle: Int) -> Bool {
        topmost != handle && topmost != belowHandle
    }

    /// The window whose owner gets the pointer when the handle stops asserting: the topmost one, or
    /// the one beneath the handle when the handle is itself on top — its own panel has no cursor to
    /// give back.
    public static func windowUnderPointer(topmost: Int, belowHandle: Int, handle: Int) -> Int {
        topmost == handle ? belowHandle : topmost
    }

    /// Whether stopping sets the arrow once. **Only over a window of an application that is not the
    /// frontmost one**, or over no window at all. Measured: the frontmost application puts its own
    /// cursor back the instant the handle stops, and setting an arrow there would stomp its I-beam; any
    /// other application never does, so the handle's resize glyph would stay over it until the pointer
    /// reached the frontmost application's windows again.
    public static func handsBackArrow(ownerPID: Int32?, frontmostPID: Int32?) -> Bool {
        guard let ownerPID else { return true }
        return ownerPID != frontmostPID
    }
}
