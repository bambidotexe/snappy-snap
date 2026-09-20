import Testing
import Foundation
@testable import SnapCore

/// The update check's decision, which is the whole of it that can be tested without a network: what
/// a version string means, what a GitHub reply means, and when a release counts as newer than the
/// running app. Making the request is `SystemAdapters.UpdateChecker`'s and is not exercised here.
@Suite struct UpdateCheckTests {
    private func release(_ version: String) -> LatestRelease {
        LatestRelease(version: ReleaseVersion(string: version)!,
                      dmgURL: URL(string: "https://example.invalid/SnappySnap-\(version).dmg")!)
    }

    /// A reply shaped like GitHub's, with only the two fields the app reads.
    private func json(tag: String? = "v1.2.0",
                      assets: [String] = ["SnappySnap-1.2.0.dmg"]) -> Data {
        let assetList = assets.map {
            #"{"name": "\#($0)", "browser_download_url": "https://example.invalid/\#($0)"}"#
        }.joined(separator: ",")
        let tagField = tag.map { #""tag_name": "\#($0)","# } ?? ""
        return Data(#"{\#(tagField) "assets": [\#(assetList)]}"#.utf8)
    }

    // MARK: - A version

    @Test func aVersionParsesWithOrWithoutItsTagsV() throws {
        #expect(ReleaseVersion(string: "1.2.0") == ReleaseVersion(1, 2, 0))
        #expect(ReleaseVersion(string: "v1.2.0") == ReleaseVersion(1, 2, 0))
        // As parsed: the "v" is gone and nothing is padded on.
        #expect(try #require(ReleaseVersion(string: "v1.2")).displayString == "1.2")
    }

    @Test func whatIsNotAVersionIsRefused() {
        #expect(ReleaseVersion(string: "") == nil)
        #expect(ReleaseVersion(string: "v") == nil)
        #expect(ReleaseVersion(string: "nightly") == nil)
        #expect(ReleaseVersion(string: "1.2.beta") == nil)
        #expect(ReleaseVersion(string: "1..2") == nil)
        #expect(ReleaseVersion(string: "-1.0.0") == nil)
    }

    /// The reason the comparison is not `String` ordering: as text, "1.0.9" sorts after "1.0.10",
    /// and the app would tell a user on 1.0.9 that they were up to date.
    @Test func componentsCompareAsNumbersAndAMissingOneIsZero() throws {
        #expect(try #require(ReleaseVersion(string: "1.0.10"))
                > #require(ReleaseVersion(string: "1.0.9")))
        #expect(try #require(ReleaseVersion(string: "1.7")) == #require(ReleaseVersion(string: "1.7.0")))
        #expect(try #require(ReleaseVersion(string: "1.7.1")) > #require(ReleaseVersion(string: "1.7")))
        #expect(try #require(ReleaseVersion(string: "2.0")) > #require(ReleaseVersion(string: "1.99.99")))
    }

    // MARK: - A release

    @Test func parseTakesTheDmgAssetAndIgnoresEveryOther() throws {
        let parsed = try #require(LatestRelease.parse(
            json(assets: ["SnappySnap-1.2.0.zip", "SnappySnap-1.2.0.dmg"])))
        #expect(parsed.version == ReleaseVersion(1, 2, 0))
        #expect(parsed.dmgURL.lastPathComponent == "SnappySnap-1.2.0.dmg")
    }

    @Test func parseRefusesWhatARealReleaseWouldNotLookLike() {
        #expect(LatestRelease.parse(Data("not json".utf8)) == nil)
        #expect(LatestRelease.parse(json(assets: [])) == nil, "no asset at all")
        #expect(LatestRelease.parse(json(assets: ["SnappySnap-1.2.0.zip"])) == nil, "no DMG")
        #expect(LatestRelease.parse(json(tag: nil)) == nil, "no tag")
        #expect(LatestRelease.parse(json(tag: "nightly")) == nil, "a tag that is not a version")
    }

    // MARK: - The decision

    @Test func onlyAStrictlyNewerReleaseIsOffered() {
        #expect(UpdateCheck.decide(current: "1.0.0", latest: release("1.2.0"))
                == .available(release("1.2.0")))
        #expect(UpdateCheck.decide(current: "1.2.0", latest: release("1.2.0")) == .upToDate)
        #expect(UpdateCheck.decide(current: "1.2.0", latest: release("1.1.9")) == .upToDate)
        // "1.2" and "1.2.0" are the same version, so neither is an update to the other.
        #expect(UpdateCheck.decide(current: "1.2", latest: release("1.2.0")) == .upToDate)
    }

    /// A binary run outside its bundle has no `CFBundleShortVersionString` to read, and every
    /// release is newer than nothing. It is read as up to date instead, so a development build
    /// never offers to replace itself with a download.
    @Test func aCurrentVersionThatDoesNotParseIsUpToDate() {
        #expect(UpdateCheck.decide(current: "", latest: release("1.2.0")) == .upToDate)
        #expect(UpdateCheck.decide(current: "dev", latest: release("1.2.0")) == .upToDate)
    }

    // MARK: - A reply

    @Test func aReplyIsReadByItsStatusFirst() throws {
        // 404 is both "no release yet" and "a repository this caller cannot see". Neither is a
        // failure the user can act on, and GitHub does not tell them apart.
        #expect(UpdateCheck.interpret(status: 404, body: Data(), current: "1.0.0")
                == .success(.noRelease))
        #expect(UpdateCheck.interpret(status: 200, body: json(), current: "1.0.0")
                == .success(.available(release("1.2.0"))))
        #expect(UpdateCheck.interpret(status: 200, body: json(), current: "1.2.0")
                == .success(.upToDate))
        #expect(UpdateCheck.interpret(status: 500, body: Data(), current: "1.0.0")
                == .failure(.httpStatus(500)))
        #expect(UpdateCheck.interpret(status: 403, body: json(), current: "1.0.0")
                == .failure(.httpStatus(403)), "a rate limit is a failure, not an answer")
        #expect(UpdateCheck.interpret(status: 200, body: Data("not json".utf8), current: "1.0.0")
                == .failure(.malformedResponse))
    }

    // MARK: - What it asks, and for how long

    @Test func theCheckAsksGitHubForThisRepositorysLatestRelease() {
        #expect(UpdateCheck.latestReleaseAPI.absoluteString
                == "https://api.github.com/repos/bambidotexe/snappy-snap/releases/latest")
        #expect(Settings.Fixed.updateCheckTimeout == 15)
    }

    // MARK: - What GitHub says about the file

    @Test func aReleaseCarriesTheLengthAndTheDigestGitHubStatesForItsDiskImage() throws {
        let body = Data(#"""
            {"tag_name": "v1.2.0", "assets": [{"name": "SnappySnap-1.2.0.dmg",
              "browser_download_url": "https://example.invalid/SnappySnap-1.2.0.dmg", "size": 2777987,
              "digest": "sha256:287255244B42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db"}]}
            """#.utf8)
        let release = try #require(LatestRelease.parse(body))
        #expect(release.dmgSize == 2_777_987)
        // Lowercased: it is compared with a digest this app computes.
        #expect(release.dmgSHA256 == "287255244b42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db")
    }

    @Test func aReleaseGitHubSaysNothingMoreAboutIsStillARelease() throws {
        let release = try #require(LatestRelease.parse(json()))
        #expect(release.dmgSize == nil)
        #expect(release.dmgSHA256 == nil)
    }

    @Test func aDigestThatIsNotSHA256IsNotHeldAgainstTheFile() throws {
        let body = Data(#"""
            {"tag_name": "v1.2.0", "assets": [{"name": "S.dmg", "browser_download_url": "https://example.invalid/S.dmg",
              "digest": "md5:0123456789abcdef0123456789abcdef"}]}
            """#.utf8)
        #expect(try #require(LatestRelease.parse(body)).dmgSHA256 == nil)
    }
}
