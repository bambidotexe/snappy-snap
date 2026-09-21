import Foundation
import SnapCore

/// Shared mutable state of the snapping engine: what we snapped and where it was before, and when a snap
/// last landed.
@MainActor
final class SnapState {
    var registry = SnapRegistry()
    /// When a window last landed where a snap put it, this launch. The Health page's proof the snapping
    /// is alive; nothing decides anything from it.
    var lastSnap: Date?
}
