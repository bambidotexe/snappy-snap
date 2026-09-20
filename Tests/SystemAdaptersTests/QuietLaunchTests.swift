import Testing
import Foundation
@testable import SystemAdapters

/// Serialized: two of these write and remove the one marker file, which is the real one, and in parallel
/// each would see the other's.
@Suite(.serialized) struct QuietLaunchTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aMarkerJustWrittenCounts() {
        #expect(QuietLaunch.isFresh(writtenAt: now, now: now))
        #expect(QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(-QuietLaunch.window + 1), now: now))
    }

    /// One left behind by an install that died must not silence a launch the user asks for minutes later.
    @Test func anOldMarkerDoesNotCount() {
        #expect(!QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(-QuietLaunch.window - 1), now: now))
    }

    /// A marker from the future is a clock that moved, not a fresh marker.
    @Test func aMarkerFromTheFutureDoesNotCount() {
        #expect(!QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(60), now: now))
    }

    @Test func noMarkerMeansThePersonOpenedTheApp() {
        try? FileManager.default.removeItem(at: QuietLaunch.markerURL)
        #expect(!QuietLaunch.consume())
    }

    /// It counts once: the launch after a reinstall is the user, and shows the window as it always did.
    @Test func consumingAMarkerRemovesIt() throws {
        let url = QuietLaunch.markerURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
        #expect(QuietLaunch.consume())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!QuietLaunch.consume())
    }

    /// It lives where the uninstall already looks, so it is never left behind.
    @Test func theMarkerIsInsideTheFolderTheUninstallRemoves() {
        #expect(QuietLaunch.markerURL.path.hasPrefix(Uninstall.supportDirectory.path + "/"))
    }
}
