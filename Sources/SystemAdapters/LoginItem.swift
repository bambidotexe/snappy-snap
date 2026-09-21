import ServiceManagement
import SnapCore

/// Launch at login. The state lives in `SMAppService` and nowhere else: the user can remove SnappySnap in
/// System Settings › General › Login Items & Extensions without opening the app, so every reader asks the
/// system rather than a copy.
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The same answer with one more distinction: registered, then switched off in System Settings, which is
    /// a login that will not happen although the app asked for it. The Health page reports that one.
    public static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        default: .disabled
        }
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
