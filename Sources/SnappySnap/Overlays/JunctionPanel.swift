import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// The junction knob: a circle in `OverlayAppearance.shapeColor` with the handle pill's shadow, at a
/// diameter derived from the pill's measured thickness so the two read as one family.
///
/// The shape carries the affordance on its own — it has to, because the cursor is not always there:
/// the system's own move glyph sits over the knob only while private interfaces are on and
/// SkyLight's connection symbols are present. A round knob where two straight bars cross is what
/// says "this one moves in both directions" when they are not.
struct JunctionKnobView: View {
    var body: some View {
        Circle()
            .fill(OverlayAppearance.shapeColor)
            .frame(width: JunctionGeometry.knobDiameter, height: JunctionGeometry.knobDiameter)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One panel for the whole app: only one junction is ever hovered.
///
/// It reuses `HandleContentView` — the keepalive, the band test and the drag flag are the same
/// machinery the pill needs, and the glyph is the only difference. Mouse down, drag and up all
/// arrive through the event tap in `JunctionHandleController`; the panel takes mouse events only so
/// the window server hands it the cursor region rather than leaving the window underneath free to
/// take it back, and so the press is swallowed instead of reaching whatever is behind the crossing.
final class JunctionPanel: OverlayPanel {
    static let fadeDuration: TimeInterval = HandlePanel.fadeDuration

    private let content = HandleContentView()
    /// Where the last layout put it, so `setDragging` can redo it at the new size.
    private var lastPoint: CGPoint?
    /// The hover band the knob is currently drawn for, in CG space — what the cursor keepalive tests
    /// the pointer against, from the same `JunctionGeometry.band` the controller hit-tests with.
    private var band: CGRect = .zero

    init() {
        super.init(acceptsMouse: true, level: .handleBar)
        let hosting = NSHostingView(rootView: JunctionKnobView())
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        contentView = content
        alphaValue = 0
    }

    func show(at point: CGPoint) {
        layout(at: point)
        // AppKit has no omnidirectional resize cursor, so this is the system's own move glyph,
        // read from HIServices' cursor resources — `.crosshair` when it cannot be read. The keepalive
        // started here tests the pointer against `band`, the very rect `JunctionHandleController`
        // hit-tests a press with.
        content.startAsserting(BackgroundCursor.move) { [weak self] in
            guard let self else { return false }
            return self.band.contains(BackgroundCursor.pointerLocation)
        }
        ignoresMouseEvents = false
        fadeIn(duration: Self.fadeDuration)
    }

    /// Slides the knob to a new crossing during a drag. No animation: the knob follows the previews
    /// the drag is drawing, and an animator here would lag the pointer they are all glued to.
    func move(to point: CGPoint) { layout(at: point) }

    func setDragging(_ dragging: Bool) {
        content.setDragging(dragging)
        // The panel grows on both axes for the drag, so re-lay it out at once rather than waiting for
        // the first drag event to arrive.
        if let lastPoint { layout(at: lastPoint) }
    }

    /// Stops the cursor assertion without taking the knob down, for the caller that owns this
    /// panel's visibility.
    func stopAsserting() { content.stopAsserting() }

    func dismiss() {
        guard isFadedIn else { return }
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        fadeOut(duration: Self.fadeDuration)
    }

    /// See `HandlePanel.hideAtOnce`: same as `dismiss()`, but with no fade. Only ever called on a hover
    /// with nothing being dragged.
    override func hideAtOnce() {
        guard isVisible else { return }
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        super.hideAtOnce()
    }

    /// The shared interruption fade, doing everything `dismiss` does besides the timing. See
    /// `HandlePanel`.
    override func fadeOutForInterruption() {
        guard isVisible else { return }
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        super.fadeOutForInterruption()
    }

    private func layout(at point: CGPoint) {
        lastPoint = point
        band = JunctionGeometry.band(at: point)
        let rect = JunctionGeometry.panelRect(at: point, dragging: content.isDragging)
        setFrame(CoordinateSpace.cocoaRect(fromCG: rect), display: true)
    }
}
