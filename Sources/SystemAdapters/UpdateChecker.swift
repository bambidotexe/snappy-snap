import CryptoKit
import Foundation
import os
import SnapCore

/// The app's two requests to the network: GitHub's latest release, and that release's disk image. The
/// first is made shortly after launch, weekly after that, and when the Settings button asks; the second
/// only ever after a click on Update. Nothing is fetched, and nothing installed, without that click.
///
/// Completions are called on the session's queue, never on the main actor. The caller hops.
public enum UpdateChecker {
    /// Where an update is fetched and unpacked: `~/Library/Application Support/SnappySnap/updates`.
    public static var updatesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnappySnap/updates", isDirectory: true)
    }

    /// `SNAPPYSNAP_UPDATE_FEED` points a build at a stand-in for GitHub's reply: a `file://` or
    /// `http://` URL of a latest-release JSON, whose `browser_download_url` may be a `file://` URL
    /// too. It is how the whole update is exercised without publishing a release.
    public static var feedURL: URL {
        ProcessInfo.processInfo.environment["SNAPPYSNAP_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? UpdateCheck.latestReleaseAPI
    }

    /// Asks GitHub for the repository's latest release and reports what it means. The cache is
    /// bypassed: a user pressing the button a second time is asking about now, not about the reply
    /// that came ten minutes ago.
    public static func check(current: String, session: URLSession = .shared,
                             completion: @escaping @Sendable (Result<UpdateDecision, Error>) -> Void) {
        var request = URLRequest(url: feedURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Settings.Fixed.updateCheckTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            // A stand-in feed read from a file has no status: it is the reply itself.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            completion(UpdateCheck.interpret(status: status, body: data ?? Data(), current: current)
                .mapError { $0 as Error })
        }.resume()
    }
}

/// One fetch of a release's disk image, reporting its progress. The finished file is held against what
/// GitHub said about the asset (its length, its SHA-256) before anyone is told it is there: a download
/// cut short or altered on the way never reaches the disk image tools. Both closures are called on the
/// session's queue; after `cancel()` neither is called again.
public final class UpdateDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The file is not the one GitHub described.
        case damaged
    }

    private struct State {
        var session: URLSession?
        var ended = false
    }

    private let release: LatestRelease
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onDone: @Sendable (Result<URL, Error>) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `destination` is the file the image is written as; a file already there is replaced.
    public init(release: LatestRelease, destination: URL,
                onProgress: @escaping @Sendable (Int64, Int64) -> Void,
                onDone: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.release = release
        self.destination = destination
        self.onProgress = onProgress
        self.onDone = onDone
    }

    public func start() {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
        session.downloadTask(with: release.dmgURL).resume()
    }

    public func cancel() {
        guard let session = claimEnd() else { return }
        session.invalidateAndCancel()
    }

    /// The session, for the first caller only: a download ends once, by finishing, failing or being
    /// cancelled.
    private func claimEnd() -> URLSession? {
        state.withLock { state in
            guard !state.ended else { return nil }
            state.ended = true
            return state.session
        }
    }

    private func end(_ result: Result<URL, Error>) {
        guard let session = claimEnd() else { return }
        session.finishTasksAndInvalidate()
        onDone(result)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard !state.withLock(\.ended) else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// The temporary file is gone once this returns, so it is moved and checked here.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        do {
            // A download task reports success on a 404 and hands over the error page it was served.
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
               !(200...299).contains(status) {
                throw UpdateFailure.httpStatus(status)
            }
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.moveItem(at: location, to: destination)
            guard try Self.matches(release, file: destination) else {
                try? files.removeItem(at: destination)
                throw Failure.damaged
            }
            end(.success(destination))
        } catch {
            end(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { end(.failure(error)) }
    }

    /// Whatever GitHub stated about the asset has to hold; what it did not state is not held against
    /// the file.
    static func matches(_ release: LatestRelease, file: URL) throws -> Bool {
        if let size = release.dmgSize {
            let actual = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard actual?.int64Value == size else { return false }
        }
        guard let expected = release.dmgSHA256 else { return true }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
