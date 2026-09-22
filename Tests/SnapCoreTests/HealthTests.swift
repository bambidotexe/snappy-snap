import Testing
import Foundation
@testable import SnapCore

/// The Health page's rules: which colour each check takes, which lines are always there and which only
/// while they are wrong, what the two readings say, how long the tables may grow, and which files are
/// this app's crash reports.
///
/// The words are compared with `HealthWords`, never with English literals: they are localized, and this
/// Mac may read them in French. The English sentences themselves are pinned in `LocalizationTests`.
@Suite struct HealthTests {
    private func row(_ id: String, in rows: [HealthRow]) -> HealthRow? {
        rows.first { $0.id == id }
    }

    private func running(listening: Bool = true, fn: Bool = true, slow: Int = 0, byMacOS: Int = 0,
                         spaces: Bool = true) -> EngineState {
        .running(EngineFacts(listening: listening, hearsFnDrags: fn, pausedForSlowness: slow,
                             pausedByMacOS: byMacOS, watchingSpaces: spaces))
    }

    private var healthy: HealthFacts {
        var f = HealthFacts()
        f.now = Date(timeIntervalSince1970: 1_790_000_000)
        return f
    }

    // MARK: The table as it should be

    /// Working, the table holds the three lines that are always there, all green, and nothing to fix.
    @Test func aHealthyMacShowsOnlyTheLinesThatAreAlwaysThere() {
        let checks = HealthReport.checks(for: healthy)
        #expect(checks.map(\.id) == ["accessibility", "notifications", "drag detection"])
        #expect(checks.allSatisfy { $0.level == .good })
        #expect(checks.warnings.isEmpty)
    }

    /// A preference is never a line, whichever way it is set: ⌥ tiling with the halves held under ⌥ Option
    /// off is harmless, and a pause macOS makes for its own reasons is nobody's fault.
    @Test func whatDoesNotStopTheAppIsNoLine() {
        var f = healthy
        f.optionTilingOn = true
        f.optionHalvesOn = false
        f.engine = running(byMacOS: 4)
        #expect(HealthReport.checks(for: f).map(\.id) == ["accessibility", "notifications", "drag detection"])
    }

    // MARK: The permissions

    @Test func aMissingGrantIsRedOnlyWhenTheWelcomeWindowMarksItRequired() {
        #expect(HealthRules.grant(held: true, required: true) == .good)
        #expect(HealthRules.grant(held: true, required: false) == .good)
        #expect(HealthRules.grant(held: false, required: true) == .failure)
        #expect(HealthRules.grant(held: false, required: false) == .warning)
    }

    @Test func accessibilityDeniedStopsTheAppAndSaysWhereToTurnItOn() {
        var f = healthy
        f.accessibilityGranted = false
        f.engine = .waiting
        let checks = HealthReport.checks(for: f)
        let accessibility = row("accessibility", in: checks)
        #expect(accessibility?.level == .failure)
        #expect(accessibility?.word == HealthWords.denied)
        #expect(checks.warnings == [HealthWords.accessibilityFix])
        // One cause, one red line: the detection waiting for the permission has no line of its own yet.
        #expect(row("drag detection", in: checks) == nil)
    }

    @Test func notificationsMissingIsOrangeAndTheFixFollowsWhetherItWasEverAsked() {
        var f = healthy
        f.notifications = .notAsked
        var checks = HealthReport.checks(for: f)
        #expect(row("notifications", in: checks)?.level == .warning)
        #expect(checks.warnings == [HealthWords.notificationsNotAskedFix])
        f.notifications = .denied
        checks = HealthReport.checks(for: f)
        #expect(row("notifications", in: checks)?.word == HealthWords.denied)
        #expect(checks.warnings == [HealthWords.notificationsDeniedFix])
    }

    // MARK: The drag detection

    @Test func theDragDetectionIsRedWhenItIsDownAndAbsentWhileItWaits() {
        #expect(HealthRules.dragDetection(.waiting) == nil)
        #expect(HealthRules.dragDetection(.failed) == .failure)
        #expect(HealthRules.dragDetection(running()) == .good)
        #expect(HealthRules.dragDetection(running(listening: false)) == .failure)

        var f = healthy
        f.engine = .failed
        let checks = HealthReport.checks(for: f)
        #expect(row("drag detection", in: checks)?.word == HealthWords.failed)
        #expect(checks.warnings == [HealthWords.dragDetectionFix])
    }

    /// The parts of the running detection are lines only while they are wrong, and orange at worst:
    /// windows still snap.
    @Test func thePartsOfTheDetectionAreLinesOnlyWhileTheyAreWrong() {
        var f = healthy
        f.engine = running(fn: false, spaces: false)
        let checks = HealthReport.checks(for: f)
        #expect(row("drag detection", in: checks)?.level == .good)
        #expect(row("fn drags", in: checks)?.level == .warning)
        #expect(row("fn drags", in: checks)?.word == HealthWords.failed)
        #expect(row("spaces", in: checks)?.level == .warning)
        #expect(checks.warnings == [HealthWords.fnDragsFix, HealthWords.spacesFix])
        #expect(!checks.contains { $0.level == .failure })
    }

    /// A pause for answering too slowly is the app's own fault; one macOS makes for its own reasons is
    /// nobody's, and no line.
    @Test func pausesAreALineOnlyWhenTheAppWasTooSlow() {
        #expect(HealthRules.pauses(slow: 0, byMacOS: 0) == .good)
        #expect(HealthRules.pauses(slow: 0, byMacOS: 3) == .good)
        #expect(HealthRules.pauses(slow: 1, byMacOS: 3) == .warning)
        var f = healthy
        f.engine = running(slow: 1, byMacOS: 2)
        let pauses = row("pauses", in: HealthReport.checks(for: f))
        #expect(pauses?.level == .warning)
        #expect(pauses?.word == "3")
        #expect(pauses?.detail == HealthWords.pausesDetail(slow: 1, byMacOS: 2))
    }

    // MARK: macOS tiling

    @Test func theTilingRulesTheSystemPageSharesAreOrangeNeverRed() {
        #expect(HealthRules.edgeTiling(conflicts: true) == .warning)
        #expect(HealthRules.edgeTiling(conflicts: false) == .good)
        #expect(HealthRules.optionTiling(on: true, optionHalvesOn: true) == .warning)
        #expect(HealthRules.optionTiling(on: true, optionHalvesOn: false) == .good)
        #expect(HealthRules.optionTiling(on: false, optionHalvesOn: true) == .good)
        #expect(HealthRules.margins(on: true, gapOn: true) == .good)
        #expect(HealthRules.margins(on: false, gapOn: false) == .good)
        #expect(HealthRules.margins(on: false, gapOn: true) == .warning)
        #expect(HealthWords.marginsFix(gapOn: true) != HealthWords.marginsFix(gapOn: false))
    }

    /// One line for macOS's tiling, only while it fights a drag, with the sentence for each switch that does.
    @Test func macOSTilingIsOneLineOnlyWhileItFightsTheApp() {
        var f = healthy
        f.edgeTilingOn = true
        var tiling = row("macos tiling", in: HealthReport.checks(for: f))
        #expect(tiling?.level == .warning)
        #expect(tiling?.word == HealthWords.enabled)
        #expect(tiling?.fix == HealthWords.edgeTilingFix)

        f.edgeTilingOn = false
        f.optionTilingOn = true
        f.optionHalvesOn = true
        #expect(row("macos tiling", in: HealthReport.checks(for: f))?.fix == HealthWords.optionTilingFix)

        f.edgeTilingOn = true
        let checks = HealthReport.checks(for: f)
        tiling = row("macos tiling", in: checks)
        #expect(checks.filter { $0.id == "macos tiling" }.count == 1)
        #expect(tiling?.fix == HealthWords.edgeTilingFix + " " + HealthWords.optionTilingFix)
    }

    // MARK: Snap Assist

    @Test func windowsSnapAssistCouldNotPutBackAreALineOnlyWhileThereAreSome() {
        #expect(HealthRules.stranded(0) == .good)
        #expect(HealthRules.stranded(2) == .warning)
        #expect(HealthRules.stranded(0, recordReadable: false) == .warning)
        var f = healthy
        #expect(row("stranded", in: HealthReport.checks(for: f)) == nil)
        f.strandedWindows = 2
        let checks = HealthReport.checks(for: f)
        #expect(row("stranded", in: checks)?.word == "2")
        #expect(checks.warnings == [HealthWords.strandedFix])
    }

    /// A record of parked windows that could not be read at launch: nothing will put them back, and the
    /// fix says where to look.
    @Test func aParkedRecordThatCouldNotBeReadIsOrange() {
        var f = healthy
        f.parkedRecordReadable = false
        let checks = HealthReport.checks(for: f)
        #expect(row("stranded", in: checks)?.word == HealthWords.invalid)
        #expect(checks.warnings == [HealthWords.parkedRecordFix])
    }

    // MARK: Crashes

    @Test func aCrashIsALineOnlyWhileThereIsOneAndIsDated() {
        var f = healthy
        #expect(row("crashes", in: HealthReport.checks(for: f)) == nil)
        let crash = Date(timeIntervalSince1970: 1_789_990_000)
        f.recentCrashes = [crash, crash.addingTimeInterval(-600)]
        let crashes = row("crashes", in: HealthReport.checks(for: f))
        #expect(crashes?.level == .warning)
        #expect(crashes?.word == "2")
        #expect(crashes?.detail == HealthWords.lastCrash(HealthReport.stamp(crash)))
        #expect(crashes?.fix == HealthWords.crashesFix)
    }

    @Test func onlyThisProcesssCrashReportsAreCounted() {
        #expect(HealthRules.isCrashReport(fileName: "SnappySnap-2026-09-21-101010.ips", process: "SnappySnap"))
        #expect(HealthRules.isCrashReport(fileName: "SnappySnap-2026-09-21-101010.crash", process: "SnappySnap"))
        #expect(HealthRules.isCrashReport(fileName: "SnappySnap-2026-09-21-101010-1.ips", process: "SnappySnap"))
        #expect(!HealthRules.isCrashReport(fileName: "ExcUserFault_SnappySnap-2026-09-21-101010.ips",
                                           process: "SnappySnap"))
        #expect(!HealthRules.isCrashReport(fileName: "SnappySnapHelper-2026-09-21-101010.ips", process: "SnappySnap"))
        #expect(!HealthRules.isCrashReport(fileName: "SnappySnap-notes.ips", process: "SnappySnap"))
        #expect(!HealthRules.isCrashReport(fileName: "SnappySnap-2026-09-21-101010.diag", process: "SnappySnap"))
    }

    // MARK: The readings

    @Test func theReadingsAreTheLastSnapAndTheWindowsStillWhereOneLeftThem() {
        var f = healthy
        var readings = HealthReport.readings(for: f)
        #expect(readings.map(\.id) == ["last snap", "snapped windows"])
        #expect(readings[0].value == HealthWords.noneYet)
        #expect(readings[0].detail == nil)
        #expect(readings[1].value == "0")

        let snap = f.now.addingTimeInterval(-125)
        f.lastSnap = snap
        f.snappedWindows = 3
        readings = HealthReport.readings(for: f)
        #expect(readings[0].value == HealthWords.ago(seconds: 125))
        #expect(readings[0].detail == HealthReport.stamp(snap))
        #expect(readings[1].value == "3")
    }

    @Test func agoReadsInTheOneUnitThatReadsBest() {
        #expect(HealthWords.ago(seconds: 59) == L("\(59) s ago"))
        #expect(HealthWords.ago(seconds: 60) == L("\(1) min ago"))
        #expect(HealthWords.ago(seconds: 3_599) == L("\(59) min ago"))
        #expect(HealthWords.ago(seconds: 3_600) == L("\(1) h ago"))
        #expect(HealthWords.ago(seconds: 2 * 86_400 + 5) == L("\(2) d ago"))
        #expect(HealthWords.ago(seconds: -4) == L("\(0) s ago"))
    }

    // MARK: The page as a whole

    @Test func aFixIsShownOnlyWhileItsRowIsOrangeOrRedAndOnce() {
        let fine = HealthRow(id: "a", label: "A", level: .good, word: "x", fix: "Do this.")
        let wrong = HealthRow(id: "b", label: "B", level: .warning, word: "x", fix: "Do that.")
        let twice = HealthRow(id: "c", label: "C", level: .failure, word: "x", fix: "Do that.")
        #expect([fine, wrong, twice].warnings == ["Do that."])
        #expect([fine].warnings.isEmpty)
    }

    /// Everything that can go wrong gone wrong at once still reads at a glance: every line distinct, and
    /// both tables within their ceiling.
    @Test func theTablesStayShortInTheWorstCase() {
        var f = healthy
        f.notifications = .denied
        f.engine = running(listening: false, fn: false, slow: 3, byMacOS: 1, spaces: false)
        f.edgeTilingOn = true
        f.optionTilingOn = true
        f.optionHalvesOn = true
        f.strandedWindows = 2
        f.parkedRecordReadable = false
        f.recentCrashes = [f.now, f.now]
        f.lastSnap = f.now
        let checks = HealthReport.checks(for: f)
        #expect(checks.count == 9)
        #expect(checks.count <= HealthLimits.checks)
        #expect(Set(checks.map(\.id)).count == checks.count)
        #expect(HealthReport.readings(for: f).count <= HealthLimits.readings)
    }
}
