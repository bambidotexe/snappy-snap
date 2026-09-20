import Foundation

/// A launch the user did not ask for, and which therefore opens no window.
///
/// Opening the bundle is how a person asks for Settings, so a cold launch that was not a login item shows
/// the window. `Scripts/install.sh` opens the bundle too, for its own reasons, and the window it got was a
/// window nobody asked for: a reinstall should put the new version in place and otherwise be invisible.
///
/// The marker is a file rather than a launch argument because a launch argument does not survive an app
/// being restarted by something else on its way up.
public enum QuietLaunch {
    /// The file the installer writes and the next launch consumes.
    public static var markerURL: URL { Uninstall.supportDirectory.appendingPathComponent("quiet-launch") }

    /// How long a marker counts for. Long enough to cover the launch the installer is about to make, short
    /// enough that one left behind by an install that died cannot silence a launch the user asks for by
    /// hand minutes later.
    public static let window: TimeInterval = 120

    public static func isFresh(writtenAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        // A marker from the future is a clock that moved, not a fresh marker.
        return age >= 0 && age <= window
    }

    /// Written before anything can start the app, by whatever is about to start it for its own reasons:
    /// `Scripts/install.sh`, and the update that puts a new version in place and opens it again.
    public static func mark() {
        let files = FileManager.default
        try? files.createDirectory(at: Uninstall.supportDirectory, withIntermediateDirectories: true)
        files.createFile(atPath: markerURL.path, contents: nil)
    }

    /// True when this launch was the installer's. Reads the marker and removes it, so it counts once: a
    /// second launch, which is the user asking, shows the window as it always did.
    @discardableResult
    public static func consume(now: Date = Date()) -> Bool {
        let url = markerURL
        guard let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        try? FileManager.default.removeItem(at: url)
        return isFresh(writtenAt: written, now: now)
    }
}
