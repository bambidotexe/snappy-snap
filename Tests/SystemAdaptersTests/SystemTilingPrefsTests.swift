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

    @Test func readMatchesTheDefaultsCommand() throws {
        // Cross-check against `defaults read` so the CFPreferences domain and key names are right.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.WindowManager", "EnableTiledWindowMargins"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = output == "0" ? false : true   // missing key or "1" both mean on
        #expect(SystemTilingPrefs.read().margins == expected)
    }
}
