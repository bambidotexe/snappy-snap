import AppKit

/// The trackpad's haptic actuator.
///
/// One pattern, `.alignment` — what macOS itself plays when an alignment guide snaps, and the lightest
/// of the three it offers. The choice lives here rather than in `Settings.Fixed` because it is an
/// AppKit value and `SnapCore` imports no AppKit; the switch over it is `Settings.hapticFeedback`,
/// which the caller passes in, so this type knows an actuator and not which feature rang it.
///
/// **A Mac with no Force Touch trackpad has no actuator and `perform` is a silent no-op there**, so a
/// user dragging with a mouse feels nothing. AppKit offers no way to ask whether a tap was felt, or
/// whether there is hardware to feel it with, so nothing here reports back and a call site can only
/// log that it asked.
@MainActor
public struct Haptics {
    private let performer: any NSHapticFeedbackPerformer

    public init(performer: any NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer) {
        self.performer = performer
    }

    /// Taps once, or does nothing when the user has haptics off. The switch is a parameter rather than
    /// a branch at the call site so that every route to the actuator passes through the same guard.
    public func tap(enabled: Bool) {
        guard enabled else { return }
        performer.perform(.alignment, performanceTime: .now)
    }
}
