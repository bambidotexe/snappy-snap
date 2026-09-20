import Testing
import Foundation
import SnapCore
@testable import SystemAdapters

/// Runs the real helper text under `/bin/sh` against a throwaway folder. The three tools it would call on
/// a real Mac (`open`, `ps`, `launchctl`) are stand-ins written by the test, which the helper takes from
/// its environment. A class, for its `deinit`: the folder goes whatever the test did.
@Suite final class UpdateInstallScriptTests {
    private let root: URL
    private var destination: URL { root.appending(path: "Applications/Probe.app") }
    private var staged: URL { root.appending(path: "updates/staged/Probe.app") }
    private var backup: URL { root.appending(path: "updates/previous/Probe.app") }
    private var resultFile: URL { root.appending(path: "updates/result") }
    private var calls: URL { root.appending(path: "calls.txt") }
    private var processList: URL { root.appending(path: "ps.txt") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "UpdateInstallScriptTests-\(UUID().uuidString)")
        try makeBundle(at: destination, marker: "old")
        try makeBundle(at: staged, marker: "new")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `open` can play the new version reading the outcome, or lock the helper's folder; `ps` answers
        // the helper's question about one pid for real, and can stop listing the app after a number of
        // answers.
        try writeTool("open", #"""
            echo "open $*" >> "$CALLS"
            [ -n "${OPEN_READS_RESULT:-}" ] && /bin/mv "$OPEN_READS_RESULT" "$OPEN_READS_RESULT.read"
            [ -n "${OPEN_LOCKS:-}" ] && /bin/chmod 555 "$OPEN_LOCKS"
            exit ${OPEN_EXIT:-0}
            """#)
        try writeTool("ps", #"""
            case "$*" in *stat=*) exec /bin/ps "$@" ;; esac
            if [ -n "${PS_ANSWERS:-}" ]; then
                n=$(cat "$PS_ANSWERS.count" 2>/dev/null || echo 0); echo $((n + 1)) > "$PS_ANSWERS.count"
                if [ "$n" -ge "$PS_ANSWERS_LIMIT" ] && { [ -z "${PS_ANSWERS_RESUME:-}" ] || [ "$n" -lt "$PS_ANSWERS_RESUME" ]; }; then exit 0; fi
            fi
            cat "$PS_OUTPUT" 2>/dev/null; exit 0
            """#)
        try writeTool("launchctl", #"echo "launchctl $*" >> "$CALLS"; exit ${LAUNCHCTL_EXIT:-0}"#)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: root.appending(path: "updates/previous").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(at url: URL, marker: String) throws {
        let macOS = url.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: macOS.appending(path: "Probe"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appending(path: "Probe").path)
        try marker.write(to: url.appending(path: "Contents/marker"), atomically: true, encoding: .utf8)
    }

    private func writeTool(_ name: String, _ body: String) throws {
        let url = root.appending(path: "tools/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func marker(of bundle: URL) -> String? {
        try? String(contentsOf: bundle.appending(path: "Contents/marker"), encoding: .utf8)
    }

    private func recordedCalls() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A pid nothing runs under any more.
    private func deadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func plan(pid: Int32, service: String? = nil, settle: Int = 0) -> UpdateInstallPlan {
        UpdateInstallPlan(pid: pid, destination: destination, staged: staged, backup: backup, resultFile: resultFile,
                          logFile: root.appending(path: "updates/install.log"), executableName: "Probe",
                          version: "1.2.0", launchdService: service, quitWait: 1, launchWait: 1, settle: settle)
    }

    /// The app is listed for the helper's first look and gone at the next: it started, then it was no
    /// longer there.
    private var startsThenGoes: [String: String] {
        ["PS_ANSWERS": root.appending(path: "ps-answers").path, "PS_ANSWERS_LIMIT": "1"]
    }

    /// The same, but listed again from the `resume`-th look on: it started, went, and came back.
    private func startsGoesAndComesBack(resume: Int) -> [String: String] {
        startsThenGoes.merging(["PS_ANSWERS_RESUME": String(resume)]) { $1 }
    }

    private func run(_ plan: UpdateInstallPlan, newVersionStarts: Bool, listedAs listed: String? = nil,
                     environment extra: [String: String] = [:]) throws {
        let script = root.appending(path: "install.sh")
        try UpdateInstallScript.text.write(to: script, atomically: true, encoding: .utf8)
        let line = listed ?? plan.destination.appending(path: "Contents/MacOS/Probe").path
        try (newVersionStarts ? line + "\n" : "").write(to: processList, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path] + plan.arguments
        process.environment = ["PATH": "/usr/bin:/bin", "CALLS": calls.path, "PS_OUTPUT": processList.path,
                               "UPDATE_HELPER_OPEN": root.appending(path: "tools/open").path,
                               "UPDATE_HELPER_PS": root.appending(path: "tools/ps").path,
                               "UPDATE_HELPER_LAUNCHCTL": root.appending(path: "tools/launchctl").path]
            .merging(extra) { $1 }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func result() -> UpdateResult? {
        (try? String(contentsOf: resultFile, encoding: .utf8)).flatMap { UpdateResult(line: $0) }
    }

    @Test func itPutsTheNewVersionInPlaceStartsItAndClearsThePreviousOne() throws {
        try run(plan(pid: deadPid()), newVersionStarts: true)
        #expect(marker(of: destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(result() == .installed(version: "1.2.0"))
        #expect(recordedCalls() == ["open \(destination.path)"])
    }

    @Test func itTouchesNothingWhileTheAppIsStillRunning() throws {
        try run(plan(pid: getpid()), newVersionStarts: true)
        #expect(marker(of: destination) == "old")
        #expect(marker(of: staged) == "new")
        #expect(result() == nil, "the app that never quit is still there to say so itself")
        #expect(recordedCalls() == [])
    }

    @Test func aMissingNewVersionLeavesThePreviousOneInPlaceAndStartsItAgain() throws {
        try FileManager.default.removeItem(at: staged)
        try run(plan(pid: deadPid()), newVersionStarts: true)
        #expect(marker(of: destination) == "old")
        #expect(result() == .failed(version: "1.2.0", reason: .replace))
        #expect(recordedCalls() == ["open \(destination.path)"])
    }

    @Test func aNewVersionThatNeverStartsIsRolledBackAndThePreviousOneStarted() throws {
        try run(plan(pid: deadPid()), newVersionStarts: false)
        #expect(marker(of: destination) == "old")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(result() == .failed(version: "1.2.0", reason: .launch))
        #expect(recordedCalls() == ["open \(destination.path)", "open \(destination.path)"])
    }

    @Test func aNewVersionThatCannotBeOpenedIsRolledBackAtOnce() throws {
        try run(plan(pid: deadPid()), newVersionStarts: true, environment: ["OPEN_EXIT": "1"])
        #expect(marker(of: destination) == "old")
        #expect(result() == .failed(version: "1.2.0", reason: .launch))
    }

    @Test func aVersionThatReadTheOutcomeAndWasThenQuitStaysInstalled() throws {
        try run(plan(pid: deadPid(), settle: 1), newVersionStarts: true,
                environment: startsThenGoes.merging(["OPEN_READS_RESULT": resultFile.path]) { $1 })
        // Its quit is the user's business, not a failed update.
        #expect(marker(of: destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: resultFile.path + ".read"), "the helper tidies the mark it waited for")
        #expect(recordedCalls() == ["open \(destination.path)"])
    }

    @Test func aVersionThatWentBeforeReadingTheOutcomeCrashedAndIsRolledBack() throws {
        try run(plan(pid: deadPid(), settle: 1), newVersionStarts: true, environment: startsThenGoes)
        #expect(marker(of: destination) == "old")
        #expect(result() == .failed(version: "1.2.0", reason: .launch))
    }

    /// An app that bootstraps a launchd job quits so that the job's own copy can take its place, and for
    /// that moment nothing is running. The second look is what tells that apart from a crash.
    @Test func aVersionThatIsGoneWhileItChangesHandsStaysInstalled() throws {
        try run(plan(pid: deadPid(), settle: 1), newVersionStarts: true,
                environment: startsGoesAndComesBack(resume: 3))
        #expect(marker(of: destination) == "new")
        #expect(result() == .installed(version: "1.2.0"))
    }

    @Test func aPreviousCopyThatCannotBePutBackIsSaidSoAndStaysWhereItIs() throws {
        try run(plan(pid: deadPid()), newVersionStarts: false,
                environment: ["OPEN_LOCKS": backup.deletingLastPathComponent().path])
        // Nothing could move: what is there stays there.
        #expect(marker(of: destination) == "new")
        #expect(marker(of: backup) == "old")
        #expect(result() == .failed(version: "1.2.0", reason: .stranded))
    }

    @Test func anAppReachedThroughASymbolicLinkIsRecognisedByItsRealPath() throws {
        let link = root.appending(path: "Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination.deletingLastPathComponent())
        var plan = plan(pid: try deadPid())
        plan.destination = link.appending(path: "Probe.app")
        // `ps` lists the path the kernel ran, with every link resolved.
        let resolved = try #require(realpath(destination.path, nil))
        defer { free(resolved) }
        try run(plan, newVersionStarts: true, listedAs: String(cString: resolved) + "/Contents/MacOS/Probe")
        #expect(marker(of: destination) == "new")
        #expect(result() == .installed(version: "1.2.0"))
    }

    @Test func aLaunchdJobIsStartedThroughLaunchdAndOpenedWhenLaunchdWillNot() throws {
        try run(plan(pid: deadPid(), service: "gui/501/io.example.agent"), newVersionStarts: true,
                environment: ["LAUNCHCTL_EXIT": "113"])
        #expect(marker(of: destination) == "new")
        #expect(recordedCalls() == ["launchctl kickstart gui/501/io.example.agent", "open \(destination.path)"])
        #expect(result() == .installed(version: "1.2.0"))
    }

    @Test func pathsWithSpacesSurvive() throws {
        let spaced = root.appending(path: "My Apps/Probe.app")
        try makeBundle(at: spaced, marker: "old")
        var plan = plan(pid: try deadPid())
        plan.destination = spaced
        try run(plan, newVersionStarts: true)
        #expect(marker(of: spaced) == "new")
        #expect(recordedCalls() == ["open \(spaced.path)"])
    }
}

@Suite struct DetachedProcessTests {
    private func contents(of url: URL, within seconds: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") { return text }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    @Test func theChildRunsInAProcessGroupOfItsOwnWithTheGivenEnvironmentOnly() throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "DetachedProcessTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let pid = try DetachedProcess.spawn(
            executable: "/bin/sh",
            arguments: ["-c", #"echo "$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ') $PROBE ${HOME:-nohome}" > "$0""#, out.path],
            environment: ["PROBE": "seen"])
        let fields = try #require(contents(of: out)).split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try #require(fields.count == 3)
        // pgid == its own pid: launchd's sweep of the app's group cannot reach it.
        #expect(Int32(fields[0]) == pid)
        #expect(Int32(fields[0]) != getpgrp())
        #expect(fields[1] == "seen")
        #expect(fields[2] == "nohome", "nothing of the app's environment leaks into the helper")
    }

    @Test func aMissingExecutableThrows() {
        #expect(throws: DetachedProcess.SpawnError.self) {
            try DetachedProcess.spawn(executable: "/nonexistent/tool", arguments: [], environment: [:])
        }
    }

    @Test func aDownloadIsHeldAgainstWhatGitHubSaidAboutIt() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "UpdateDownloadTests-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello".utf8).write(to: file)
        let url = URL(string: "https://example.invalid/S.dmg")!
        // sha256("hello")
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        func release(size: Int64?, sha: String?) -> LatestRelease {
            LatestRelease(version: ReleaseVersion(1, 2, 0), dmgURL: url, dmgSize: size, dmgSHA256: sha)
        }
        #expect(try UpdateDownload.matches(release(size: 5, sha: digest), file: file))
        #expect(try UpdateDownload.matches(release(size: nil, sha: nil), file: file), "nothing stated, nothing held against it")
        #expect(try !UpdateDownload.matches(release(size: 6, sha: digest), file: file))
        #expect(try !UpdateDownload.matches(release(size: 5, sha: String(repeating: "0", count: 64)), file: file))
    }
}
