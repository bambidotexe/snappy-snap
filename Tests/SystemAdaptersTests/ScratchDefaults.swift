import Foundation

/// A `UserDefaults` suite per call, kept out of `~/Library/Preferences` altogether. A suite named by an
/// absolute path is stored at that path (`<path>.plist`) — `cfprefsd` never touches the Preferences
/// folder for it — so every suite made here lives in a folder under the temporary directory that goes
/// with the test.
///
/// Why not a UUID suite name removed at the end of the test: `cfprefsd` writes the emptied plist five to
/// ten seconds *after the test process has exited* (0 files at +4 s, 17 at +10 s, measured), so no
/// `removePersistentDomain`, `synchronize()` or unlink run from the test can win, and one plist per test
/// stayed behind — six thousand in a week. A class, for its `deinit`: swift-testing makes one instance of
/// a suite per test, and the instance goes when the test does.
final class ScratchDefaults {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "ScratchDefaults-\(UUID().uuidString)")

    /// A fresh, empty suite named `<prefix>.<UUID>` under this instance's folder.
    func make(_ prefix: String) -> UserDefaults {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appending(path: "\(prefix).\(UUID().uuidString)").path)!
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}
