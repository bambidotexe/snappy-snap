import Foundation

/// A dotted version — "1.7.0", or "v1.7.0" as a git tag writes it — compared numerically per
/// component rather than as text, so "1.0.10" is newer than "1.0.9". A missing trailing component
/// counts as 0, which makes "1.7" and "1.7.0" the same version.
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    public init(_ major: Int, _ minor: Int, _ patch: Int) { components = [major, minor, patch] }

    /// nil for an empty string, or one with a component that is not a non-negative number.
    public init?(string: String) {
        var s = Substring(string)
        if s.first == "v" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        components = parsed
    }

    /// The version as it was parsed: no leading "v", and not padded to three components.
    public var displayString: String { components.map(String.init).joined(separator: ".") }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }
}

/// GitHub's `/releases/latest` reply, reduced to what the app needs from it. It is also the contract a
/// release has to meet to be offered at all: a tag that parses as a version, and an asset whose name
/// ends in `.dmg`. A release that meets neither is not an update the app can hand to the user, so it
/// is read as no release rather than as a broken one.
///
/// The asset's length and SHA-256 are GitHub's own statement about the file it serves. The length
/// sizes the progress bar when the download's response carries none, and a finished download is held
/// against both before anything opens it.
public struct LatestRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let dmgURL: URL
    public let dmgSize: Int64?
    /// 64 lowercase hex digits, or nil when GitHub states no SHA-256 for the asset.
    public let dmgSHA256: String?

    public init(version: ReleaseVersion, dmgURL: URL, dmgSize: Int64? = nil, dmgSHA256: String? = nil) {
        self.version = version
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.dmgSHA256 = dmgSHA256
    }

    private struct DTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
            let digest: String?
        }
        let tag_name: String?
        let assets: [Asset]?
    }

    /// nil on malformed JSON, on a missing or unparsable `tag_name`, and on a release with no asset
    /// ending in `.dmg`. The first such asset wins; a release carrying several is not a case the
    /// build script can produce.
    public static func parse(_ data: Data) -> LatestRelease? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let tag = dto.tag_name, let version = ReleaseVersion(string: tag),
              let dmg = dto.assets?.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: dmg.browser_download_url)
        else { return nil }
        return LatestRelease(version: version, dmgURL: url,
                             dmgSize: dmg.size.flatMap { $0 > 0 ? $0 : nil },
                             dmgSHA256: sha256(in: dmg.digest))
    }

    /// GitHub writes an asset's digest as `sha256:<hex>`.
    private static func sha256(in digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(LatestRelease)
    /// GitHub has nothing to compare against — see `UpdateCheck.interpret(status:body:current:)`.
    case noRelease
}

public enum UpdateFailure: LocalizedError, Equatable, Sendable {
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return L("GitHub answered with status \(code).")
        case .malformedResponse: return L("The release information could not be read.")
        }
    }
}

/// The update check's whole decision: what to ask GitHub, and what an answer means. Making the
/// request is `SystemAdapters.UpdateChecker`'s job; nothing here touches the network, so every rule
/// below is testable without one.
public enum UpdateCheck {
    /// Anonymous and unauthenticated, so it only ever sees a public repository's releases.
    public static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/bambidotexe/snappy-snap/releases/latest")!

    /// `available` only for a release **strictly** newer than what is running. An equal or older
    /// release is up to date, and so is a `current` that does not parse: a binary run outside its
    /// bundle has no version, and offering that an update would be offering it to everything.
    public static func decide(current: String, latest: LatestRelease) -> UpdateDecision {
        guard let currentVersion = ReleaseVersion(string: current),
              latest.version > currentVersion else { return .upToDate }
        return .available(latest)
    }

    /// What one reply from `latestReleaseAPI` means, read by its status first. 404 is GitHub's
    /// answer for a repository that has published no release — and for one it will not show an
    /// anonymous caller at all, which it deliberately does not tell apart; both are reported as
    /// having nothing to offer rather than as a failure.
    public static func interpret(status: Int, body: Data,
                                 current: String) -> Result<UpdateDecision, UpdateFailure> {
        if status == 404 { return .success(.noRelease) }
        guard (200...299).contains(status) else { return .failure(.httpStatus(status)) }
        guard let latest = LatestRelease.parse(body) else { return .failure(.malformedResponse) }
        return .success(decide(current: current, latest: latest))
    }
}
