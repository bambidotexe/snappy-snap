import AppKit
import SnapCore
import SystemAdapters

/// Several zone previews at once, one per window a gesture is about to move.
///
/// The handle drag resizes nothing while the divider moves: it draws the outcome instead, one preview
/// per member at the frame that member will take, and moves the windows on release. That is the same
/// picture a pair drop shows through `ZonePreviewController` — the same panel type, the same level, the
/// same look — differing only in how many are up and in what makes them move.
///
/// Panels are keyed by **slot**, not by window: a gesture's members are ordered for its whole life, so
/// slot 0 keeps its panel from the first event to the release, and the pool is bounded by the widest
/// gesture ever made (two for a pill, four for a junction knob) rather than growing by one for every
/// window the user ever dragged a divider on. Dismissed panels are kept for the next gesture, for the
/// reason `ZonePreviewController` keeps its own: releasing a panel mid-fade takes the fade off the
/// screen with it, and rebuilding an `NSPanel` with a hosting view per gesture is not free.
@MainActor
final class WindowPreviewGroup {
    private var panels: [ZonePreviewPanel] = []

    /// Frames in **CG space**, in the gesture's own order. `origins` are the members' frames as the
    /// press read them, in the same order: a slot that is not up yet morphs out of its window the way
    /// a snap preview morphs out of the dragged one, and every later call glues it to its frame.
    ///
    /// Passed whole on every event rather than diffed — the arithmetic behind the frames is pure and
    /// the panels are the cheap part of this feature, so there is nothing to save by tracking which of
    /// two or four rects changed.
    func track(_ frames: [CGRect], appearingFrom origins: [CGRect]) {
        while panels.count < frames.count { panels.append(ZonePreviewPanel()) }
        for (slot, frame) in frames.enumerated() {
            let origin = slot < origins.count ? CoordinateSpace.cocoaRect(fromCG: origins[slot]) : nil
            panels[slot].track(frame: CoordinateSpace.cocoaRect(fromCG: frame), appearingFrom: origin)
        }
    }

    /// Fades every preview out. Idempotent — `ZonePreviewPanel.dismiss` answers nothing for a panel
    /// that is not up — which is what lets a cancel and a release both call it.
    func dismiss() {
        for panel in panels { panel.dismiss() }
    }

    /// The shared interruption fade, for the interruption path only — the previews of a live handle or
    /// knob drag are on-screen surfaces of that gesture and leave with the rest. `dismiss` above keeps
    /// the previews' own 100 ms for the ordinary release.
    func dismissForInterruption() {
        for panel in panels { panel.fadeOutForInterruption() }
    }
}
