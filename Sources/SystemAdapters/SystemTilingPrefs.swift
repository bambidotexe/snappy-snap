import Foundation

/// macOS's own tiling switches, as Desktop & Dock names them.
public struct SystemTilingState: Hashable, Sendable {
    /// "Drag windows to left or right edge of screen to tile"
    public var edgeTiling: Bool
    /// "Drag windows to menu bar to fill screen"
    public var topTiling: Bool
    /// "Tiled windows have margins"
    public var margins: Bool
    /// "Hold ⌥ key while dragging windows to tile"
    public var optionTiling: Bool

    public init(edgeTiling: Bool, topTiling: Bool, margins: Bool, optionTiling: Bool = false) {
        self.edgeTiling = edgeTiling
        self.topTiling = topTiling
        self.margins = margins
        self.optionTiling = optionTiling
    }

    /// True when the system's own drag tiling would fight SnappySnap.
    public var conflicts: Bool { edgeTiling || topTiling }

    /// Whether the system's margins say what the app's gap switch says. macOS applies its margins to
    /// the placements this app does not own, a title bar double-clicked or the green button's tiling
    /// menu, so the two agree when both leave a gap or neither does.
    public func marginsAgree(withGap gapEnabled: Bool) -> Bool { margins == gapEnabled }
}

/// Reads the system tiling switches from the WindowManager preference domain. All default to on, like macOS.
public enum SystemTilingPrefs {
    public static func read() -> SystemTilingState {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        func flag(_ key: String) -> Bool {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? true
        }
        return SystemTilingState(
            edgeTiling: flag("EnableTilingByEdgeDrag"),
            topTiling: flag("EnableTopTilingByEdgeDrag"),
            margins: flag("EnableTiledWindowMargins"),
            optionTiling: flag("EnableTilingOptionAccelerator")
        )
    }
}
