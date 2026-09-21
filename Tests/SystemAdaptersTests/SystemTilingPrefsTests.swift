import Testing
import Foundation
@testable import SystemAdapters

@Suite struct SystemTilingPrefsTests {
    @Test func conflictsWhenEitherDragTilingIsOn() {
        #expect(SystemTilingState(edgeTiling: true, topTiling: false, margins: true).conflicts)
        #expect(SystemTilingState(edgeTiling: false, topTiling: true, margins: true).conflicts)
        #expect(!SystemTilingState(edgeTiling: false, topTiling: false, margins: false).conflicts)
    }

    /// Margins and the gap agree when both leave space or neither does; the drag tiling switches have
    /// no say in it.
    @Test func marginsAgreeWithTheGapWhenBothAreOnOrBothAreOff() {
        let withMargins = SystemTilingState(edgeTiling: false, topTiling: false, margins: true)
        let without = SystemTilingState(edgeTiling: true, topTiling: true, margins: false)
        #expect(withMargins.marginsAgree(withGap: true))
        #expect(!withMargins.marginsAgree(withGap: false))
        #expect(without.marginsAgree(withGap: false))
        #expect(!without.marginsAgree(withGap: true))
    }

    /// macOS's ⌥ tiling answers a key, not an edge: it is not what `conflicts` reports, whose two switches
    /// fight every drag. Whether it fights the app depends on a setting of the app's own
    /// (`HealthRules.optionTiling`).
    @Test func optionTilingIsNotAnEdgeConflict() {
        #expect(!SystemTilingState(edgeTiling: false, topTiling: false, margins: true, optionTiling: true).conflicts)
    }

    @Test func readMatchesTheDefaultsCommand() throws {
        #expect(SystemTilingPrefs.read().margins == (try Self.defaultsFlag("EnableTiledWindowMargins")))
        #expect(SystemTilingPrefs.read().optionTiling == (try Self.defaultsFlag("EnableTilingOptionAccelerator")))
    }

    /// What `defaults read` says of one of the domain's switches: a missing key or "1" both mean on.
    private static func defaultsFlag(_ key: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.WindowManager", key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output != "0"
    }
}
