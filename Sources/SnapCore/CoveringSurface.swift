import CoreGraphics

/// A window that takes no part in snapping and can still **hide a handle**: the pill and the knob are
/// not drawn over it.
///
/// Which windows take part is a narrow question — layer 0, a regular application, 50 pt a side — and
/// what can sit on top of a gap between two of them is a wider one. A note widget a menu-bar
/// application floats over the desktop fails the first on two counts (measured: owner's activation
/// policy *accessory*, window layer 3) and covers the pill's spot as surely as a browser window does.
public enum CoveringSurface {
    /// Whether an on-screen window that is not a participant covers what is under it: **every layer
    /// from the ordinary one up to, and not including, the Dock's.** That is an accessory
    /// application's ordinary window (0), a floating panel (3), a modal panel (8), a utility window
    /// (19). From the Dock's layer (20) upwards the window list is full of windows that cover the
    /// whole display and draw nothing over most of it — the Dock's own, the menu bar, other
    /// applications' click-through overlays (measured here: one at layer 1000 over the entire
    /// display) — and nothing the list carries tells a transparent window from an opaque one, so
    /// none of them counts.
    public static func covers(layer: Int, dockLayer: Int) -> Bool {
        layer >= 0 && layer < dockLayer
    }

    /// Where a coverer stands among the participants, whose `zIndex` is their position front to back
    /// among themselves: **in front of every participant listed after it, behind every one listed
    /// before it.** With `n` participants in front of it that is `n − 1` — below the `n`th
    /// participant's own index, and not below the one before it.
    public static func zIndex(participantsInFront n: Int) -> Int { n - 1 }
}
