import AppKit
import ServiceManagement

/// Which part of taking SnappySnap off a Mac did not work. The words a user reads are the app target's:
/// this one only says which step, and what the system said about it.
public enum UninstallStep: Sendable, Hashable {
    case accessibilityGrant
    case loginItem
    case bundleToTrash
    case storedState
}

public struct UninstallFailure: Sendable, Hashable {
    public let step: UninstallStep
    public let reason: String
    public init(step: UninstallStep, reason: String) {
        self.step = step
        self.reason = reason
    }
}

/// Everything SnappySnap put on a Mac outside its own bundle, taken off.
///
/// **Dragging the bundle to the Trash is not an uninstall.** It removes the app and nothing else: the
/// login item registered with `SMAppService` stays, so System Settings › General › Login Items goes on
/// listing an app that is not there and offering to start it, and the Accessibility grant stays in the
/// privacy list, where a later build signed by the same team inherits a decision nobody remembers making.
public enum Uninstall {
    /// Our own folder under Application Support. `UpdateChecker.updatesDirectory` is inside it, so this
    /// takes a half-fetched disk image and a finished install's leftovers with it.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnappySnap", isDirectory: true)
    }

    /// What is left of SnappySnap after this, for a check that it really has gone: the bundle, the
    /// preferences and the folder. The two paths are absolute; the middle one is a preferences domain.
    public static func remains(bundleIdentifier: String) -> [String] {
        ["/Applications/SnappySnap.app", bundleIdentifier, supportDirectory.path]
    }

    /// The grant and the login item, in that order, while the bundle they both name is still where they
    /// name it. `tccutil reset` against a bundle identifier with no bundle behind it fails, and nothing
    /// puts that right afterwards, so this runs before the app goes anywhere.
    @MainActor
    public static func removeSystemRegistrations(bundleIdentifier: String) -> [UninstallFailure] {
        var failed: [UninstallFailure] = []
        if !resetAccessibilityGrant(bundleIdentifier) {
            failed.append(.init(step: .accessibilityGrant, reason: ""))
        }
        if LoginItem.isEnabled {
            do { try LoginItem.setEnabled(false) }
            catch { failed.append(.init(step: .loginItem, reason: error.localizedDescription)) }
        }
        _ = resetNotificationGrant(bundleIdentifier)
        return failed
    }

    /// Notification authorization lives in usernoted's group preferences, and no public API puts it back
    /// to "not asked yet". Left behind, a reinstall inherits a decision the user made once about an app
    /// they have since removed, and can never be asked again. Its failure is not worth a sentence: an
    /// update this app cannot announce is the whole of the cost.
    private static func resetNotificationGrant(_ bundleIdentifier: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist")
        guard let data = try? Data(contentsOf: url),
              var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let apps = plist["apps"] as? [[String: Any]] else { return false }
        let kept = apps.filter { ($0["bundle-id"] as? String) != bundleIdentifier }
        guard kept.count != apps.count else { return true }
        plist["apps"] = kept
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              (try? out.write(to: url)) != nil else { return false }
        for daemon in ["usernoted", "NotificationCenter"] { run("/usr/bin/killall", [daemon]) }
        return true
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// How long the helper waits for this process to go before giving up, in tenths of a second. A helper
    /// that could spin for ever is worse than one that stops: what it does after the wait is a handful of
    /// removals of paths nothing holds open.
    public static let helperWaitTenths = 600

    /// The preferences and the folder, **handed to a process that outlives this one.**
    ///
    /// Removing them here does not work, and that was seen on a real uninstall: the quit puts the parked
    /// windows back and `ParkedWindowsStore` and `MinimumSizeStore` write into the preferences as it does,
    /// and `cfprefsd` writes the domain out again as the process exits whatever happens, leaving an empty
    /// plist where a Mac that never had SnappySnap has no file at all. So the helper waits for the pid.
    ///
    /// The caches, the HTTP storage and the saved window state go too. They are not dangerous, but they
    /// are named after the bundle identifier and belong to nothing else.
    public static func helperScript(pid: Int32, bundleIdentifier: String, home: String) -> String {
        let library = home + "/Library"
        let paths = [
            supportDirectory.path,
            "\(library)/Preferences/\(bundleIdentifier).plist",
            "\(library)/Caches/\(bundleIdentifier)",
            "\(library)/HTTPStorages/\(bundleIdentifier)",
            "\(library)/HTTPStorages/\(bundleIdentifier).binarycookies",
            "\(library)/Saved Application State/\(bundleIdentifier).savedState",
        ]
        return ([
            "i=0",
            "while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt \(helperWaitTenths) ]; do /bin/sleep 0.1; i=$((i+1)); done",
            // Before the file is removed, or cfprefsd writes its cache back over the gap.
            "/usr/bin/defaults delete \(bundleIdentifier) 2>/dev/null",
            "/bin/rm -rf " + paths.map(shellQuoted).joined(separator: " "),
            // One per host identifier, so a glob rather than a path; `find` keeps the glob away from a home
            // folder whose name has a space in it.
            "/usr/bin/find \(shellQuoted(library + "/Preferences/ByHost")) -maxdepth 1 -name \(shellQuoted(bundleIdentifier + ".*.plist")) -delete 2>/dev/null",
        ] as [String]).joined(separator: "\n") + "\n"
    }

    /// Starts that helper. Called just before the quit.
    public static func startHelper(bundleIdentifier: String) -> UninstallFailure? {
        let script = helperScript(pid: getpid(), bundleIdentifier: bundleIdentifier,
                                  home: FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            try DetachedProcess.spawn(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
            return nil
        } catch {
            return .init(step: .storedState, reason: "\(error)")
        }
    }

    /// Single quotes, with any quote in the path closed and reopened around an escaped one. The home folder
    /// is the user's to name, spaces and all.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The Trash, not a delete: the app the user has just removed is still there to put back.
    @MainActor
    public static func moveBundleToTrash(_ completion: @escaping @MainActor (UninstallFailure?) -> Void) {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            let failure = error.map { UninstallFailure(step: .bundleToTrash, reason: $0.localizedDescription) }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// `tccutil reset` exits non-zero when it has nothing to reset as well as when it fails, so a grant
    /// that was never given reads as a failure here. The caller shows a sentence naming where to look,
    /// which is true either way.
    private static func resetAccessibilityGrant(_ bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
