import SnapCore

/// Shared mutable state of the snapping engine: what we snapped and where it was before.
@MainActor
final class SnapState {
    var registry = SnapRegistry()
}
