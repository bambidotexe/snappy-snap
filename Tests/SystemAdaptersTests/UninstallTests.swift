import Testing
import Foundation
@testable import SystemAdapters

@Suite struct UninstallTests {
    private func helper(home: String = "/Users/x") -> String {
        Uninstall.helperScript(pid: 4242, bundleIdentifier: "dev.rubens.SnappySnap", home: home)
    }

    /// The one that would rot in silence: move the updates folder and the uninstall stops taking a
    /// half-fetched disk image with it, with nothing to say so.
    @Test func theUpdatesFolderIsInsideTheFolderTheUninstallRemoves() {
        #expect(UpdateChecker.updatesDirectory.path.hasPrefix(Uninstall.supportDirectory.path + "/"))
    }

    @Test func theFolderIsOursAndUnderApplicationSupport() {
        #expect(Uninstall.supportDirectory.lastPathComponent == "SnappySnap")
        #expect(Uninstall.supportDirectory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    /// What a check after an uninstall looks at: the bundle, the preferences domain, the folder.
    @Test func whatIsLeftToCheckIsTheBundleThePreferencesAndTheFolder() {
        let remains = Uninstall.remains(bundleIdentifier: "dev.rubens.SnappySnap")
        #expect(remains == ["/Applications/SnappySnap.app", "dev.rubens.SnappySnap", Uninstall.supportDirectory.path])
    }

    /// The whole reason the helper exists: the quit writes preferences as it puts the parked windows
    /// back, and cfprefsd writes the domain out again as the process exits. Nothing may run before the
    /// pid has gone.
    @Test func everyRemovalWaitsForThePidToGo() throws {
        let lines = helper().split(separator: "\n").map(String.init)
        let wait = try #require(lines.firstIndex { $0.contains("kill -0 4242") })
        for (index, line) in lines.enumerated()
        where line.contains("rm -rf") || line.contains("defaults delete") || line.contains("find") {
            #expect(index > wait, "\(line)")
        }
    }

    @Test func theWaitIsBounded() {
        #expect(helper().contains("[ $i -lt \(Uninstall.helperWaitTenths) ]"))
    }

    @Test func itTakesTheFolderThePreferencesTheCachesAndTheSavedState() {
        let script = helper()
        #expect(script.contains("'\(Uninstall.supportDirectory.path)'"))
        for tail in ["Preferences/dev.rubens.SnappySnap.plist", "Caches/dev.rubens.SnappySnap",
                     "HTTPStorages/dev.rubens.SnappySnap", "HTTPStorages/dev.rubens.SnappySnap.binarycookies",
                     "Saved Application State/dev.rubens.SnappySnap.savedState"] {
            #expect(script.contains("'/Users/x/Library/\(tail)'"), "\(tail)")
        }
    }

    /// `defaults delete` first, or cfprefsd writes its cache back over the gap the `rm` just made.
    @Test func thePreferencesAreDeletedBeforeTheirFileIsRemoved() throws {
        let script = helper()
        let delete = try #require(script.range(of: "defaults delete"))
        let file = try #require(script.range(of: "Preferences/dev.rubens.SnappySnap.plist"))
        #expect(delete.lowerBound < file.lowerBound)
    }

    /// One ByHost file per host identifier, so a glob; `find` keeps that glob away from a home folder
    /// whose name has a space in it.
    @Test func theByHostPreferencesGoThroughFindRatherThanAGlob() {
        #expect(helper(home: "/Users/a b").contains(
            "/usr/bin/find '/Users/a b/Library/Preferences/ByHost' -maxdepth 1 -name 'dev.rubens.SnappySnap.*.plist' -delete"))
    }

    @Test func aQuoteInTheHomeFolderCannotEndTheQuoting() {
        #expect(Uninstall.shellQuoted("/Users/o'brien") == "'/Users/o'\\''brien'")
    }
}
