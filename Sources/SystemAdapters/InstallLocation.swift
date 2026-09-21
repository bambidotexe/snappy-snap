import Foundation
import SnapCore

/// Where the running bundle is, in the terms the Health page reports it in. The decision is
/// `HealthRules.location`; this reads the two facts it needs.
public enum InstallLocation {
    public static func current(bundleURL: URL = Bundle.main.bundleURL) -> AppLocation {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return HealthRules.location(bundlePath: bundleURL.path,
                                    home: FileManager.default.homeDirectoryForCurrentUser.path,
                                    readOnlyVolume: readOnly)
    }
}
