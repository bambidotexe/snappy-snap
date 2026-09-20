import AppKit
import SnapCore
import SystemAdapters

/// A flat black sheet over the whole of one display, under the gesture's own overlays.
///
/// The handle drag draws its outcome rather than performing it, so for as long as the button is down
/// the two previews are the only thing on screen that means anything and every real window behind them
/// is stale. Dimming the rest is what makes that readable: the previews stay at full brightness because
/// they sit at a higher `OverlayLevel`, and everything the user is *not* being asked about goes back
/// 30 %.
///
/// **`frame`, not `visibleFrame` — the menu bar and the Dock dim too.** A bright menu bar and a bright
/// Dock framing a dimmed desktop read as a panel that failed to cover the display rather than as a
/// distinction. The dim is a modal picture — nothing visible is true until the button comes up — and a
/// modal picture with two bright strips in it is not one. `OverlayLevel.dim` is at `.statusBar` (25)
/// for exactly this: it clears the main-menu level (24) and the Dock (20).
///
/// **Click-through, and it has to be.** The pill's press, drag and release are hit-tested in
/// `HandleBarController` against the global event stream, but the panel that draws the pill takes mouse
/// events for its cursor, and a sheet swallowing events over the whole display would put a
/// never-activating app's panel between the pointer and every window under it.
final class DimPanel: OverlayPanel {
    init() {
        super.init(acceptsMouse: false, level: .dim)
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(DimGroup.dimAlpha).cgColor
        contentView = view
        alphaValue = 0
    }
}

/// One `DimPanel` per display, raised and lowered together.
///
/// The panels are pooled the way `WindowPreviewGroup` pools its previews and for the same two reasons:
/// releasing one mid-fade takes the fade off the screen with it, and an `NSPanel` per gesture is not
/// free. The pool is bounded by the number of displays.
///
/// **The whole desktop dims, not the display the pair is on.** A handle drag is a modal moment — until
/// the button comes up nothing the user can see is true — and a single bright display beside two dim
/// ones reads as a rendering fault rather than as a distinction.
@MainActor
final class DimGroup {
    /// How far back the rest of the screen goes. One constant, deliberately not a user-facing setting.
    static let dimAlpha: CGFloat = 0.30
    /// Short enough that it is over before the first `.dragged` event, long enough not to flash.
    static let fadeDuration: TimeInterval = 0.12

    private var panels: [DimPanel] = []

    /// Frames in **CG space** — `DisplayInfo.frame`, the display's full bounds — converted at this
    /// boundary, which is where every other overlay in this app converts.
    func fadeIn(over displays: [DisplayInfo]) {
        while panels.count < displays.count { panels.append(DimPanel()) }
        for (panel, display) in zip(panels, displays) {
            // Before the fade, and without the animator: a panel reused from a previous gesture may
            // have been sized for a display arrangement that no longer exists.
            panel.setFrame(CoordinateSpace.cocoaRect(fromCG: display.frame), display: false)
            panel.fadeIn(duration: Self.fadeDuration)
        }
        // A display that has gone away since the last gesture leaves a panel behind; it is faded out
        // rather than released, for the reason the pool exists.
        for panel in panels.dropFirst(displays.count) { panel.fadeOut(duration: Self.fadeDuration) }
    }

    /// Idempotent — `OverlayPanel.fadeOut` answers nothing for a panel that is not up — which is what
    /// lets the release, a cancel and an orphaned gesture all call it.
    func fadeOut() {
        for panel in panels { panel.fadeOut(duration: Self.fadeDuration) }
    }

    /// The shared interruption fade, for the interruption path only. The dim is an on-screen surface
    /// of a live gesture like any other, so it leaves with the rest. `fadeOut` above stays for the
    /// ordinary release, which is where this feature's own 120 ms is the feel of the gesture rather
    /// than the speed of a dismissal.
    func fadeOutForInterruption() {
        for panel in panels { panel.fadeOutForInterruption() }
    }
}
