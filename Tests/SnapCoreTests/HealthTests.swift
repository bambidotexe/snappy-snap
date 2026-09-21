import Testing
import CoreGraphics
import Foundation
@testable import SnapCore

/// The Health page's rules: which colour each state takes, which rows show when, what the overview sums
/// up, which files are this app's crash reports, and what the copied report says.
///
/// The words are compared with `HealthWords`, never with English literals: they are localized, and this
/// Mac may read them in French. The English sentences themselves are pinned in `LocalizationTests`.
@Suite struct HealthTests {
    private func row(_ id: String, in groups: [HealthGroup]) -> HealthRow? {
        groups.flatMap(\.rows).first { $0.id == id }
    }

    private func group(_ id: String, in groups: [HealthGroup]) -> HealthGroup? {
        groups.first { $0.id == id }
    }

    private func running(listening: Bool = true, fn: Bool = true, slow: Int = 0, byMacOS: Int = 0,
                         spaces: Bool = true) -> EngineState {
        .running(EngineFacts(listening: listening, hearsFnDrags: fn, pausedForSlowness: slow,
                             pausedByMacOS: byMacOS, watchingSpaces: spaces))
    }

    /// A Mac as it should be: one display with a camera housing, every hidden feature there.
    private var healthy: HealthFacts {
        var f = HealthFacts()
        f.macOSVersion = "27.0"
        f.hiddenFeatures = [HiddenFeatureFact(id: "windowMatching", title: "Exact window matching",
                                              available: true, detail: "_AXUIElementGetWindow: found")]
        f.displays = [DisplayFact(id: 1, name: "Built-in Retina Display", isBuiltIn: true,
                                  size: CGSize(width: 1512, height: 982), housing: CGSize(width: 185, height: 32))]
        f.runningSeconds = 3_720
        f.memoryBytes = 48 * 1_048_576
        f.bundlePath = "/Applications/SnappySnap.app"
        f.now = Date(timeIntervalSince1970: 1_790_000_000)
        return f
    }

    // MARK: The colour of a grant

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
        let groups = HealthReport.groups(for: f)
        let accessibility = row("accessibility", in: groups)
        #expect(accessibility?.level == .failure)
        #expect(accessibility?.word == HealthWords.denied)
        #expect(group("permissions", in: groups)?.warnings == [HealthWords.accessibilityFix])
        // One cause, one red row: the detection waiting for the permission has no row of its own yet.
        #expect(row("drag detection", in: groups) == nil)
        #expect(row("fn drags", in: groups) == nil)
        #expect(HealthSummary(groups: groups).blocking == 1)
        #expect(HealthReport.summaryWord(HealthSummary(groups: groups)) == HealthWords.notWorking(problems: 1))
    }

    @Test func notificationsMissingIsOrangeAndTheFixFollowsWhetherItWasEverAsked() {
        var f = healthy
        f.notifications = .notAsked
        var groups = HealthReport.groups(for: f)
        #expect(row("notifications", in: groups)?.level == .warning)
        #expect(group("permissions", in: groups)?.warnings == [HealthWords.notificationsNotAskedFix])
        f.notifications = .denied
        groups = HealthReport.groups(for: f)
        #expect(row("notifications", in: groups)?.word == HealthWords.denied)
        #expect(group("permissions", in: groups)?.warnings == [HealthWords.notificationsDeniedFix])
        #expect(HealthSummary(groups: groups).level == .warning)
    }

    // MARK: macOS tiling

    @Test func macOSTilingThatFightsTheAppIsOrangeNeverRed() {
        #expect(HealthRules.edgeTiling(conflicts: true) == .warning)
        #expect(HealthRules.edgeTiling(conflicts: false) == .good)
        var f = healthy
        f.edgeTilingOn = true
        let groups = HealthReport.groups(for: f)
        #expect(row("edge tiling", in: groups)?.word == HealthWords.enabled)
        #expect(group("tiling", in: groups)?.warnings == [HealthWords.edgeTilingFix])
        #expect(HealthSummary(groups: groups).blocking == 0)
    }

    /// Green whenever the margins and the gap agree, whichever way round; the fix names the direction.
    @Test func marginsAreGreenWhenTheyAgreeWithTheGap() {
        #expect(HealthRules.margins(on: true, gapOn: true) == .good)
        #expect(HealthRules.margins(on: false, gapOn: false) == .good)
        #expect(HealthRules.margins(on: false, gapOn: true) == .warning)
        #expect(HealthRules.margins(on: true, gapOn: false) == .warning)
        var f = healthy
        f.marginsOn = false
        #expect(group("tiling", in: HealthReport.groups(for: f))?.warnings == [HealthWords.marginsFix(gapOn: true)])
        f.gapOn = false
        f.marginsOn = true
        #expect(group("tiling", in: HealthReport.groups(for: f))?.warnings == [HealthWords.marginsFix(gapOn: false)])
        #expect(HealthWords.marginsFix(gapOn: true) != HealthWords.marginsFix(gapOn: false))
    }

    @Test func macOSOptionTilingFightsOnlyTheHalvesHeldUnderOption() {
        #expect(HealthRules.optionTiling(on: true, optionHalvesOn: true) == .warning)
        #expect(HealthRules.optionTiling(on: true, optionHalvesOn: false) == .good)
        #expect(HealthRules.optionTiling(on: false, optionHalvesOn: true) == .good)
        var f = healthy
        f.optionTilingOn = true
        f.optionHalvesOn = true
        #expect(group("tiling", in: HealthReport.groups(for: f))?.warnings == [HealthWords.optionTilingFix])
    }

    // MARK: The drag detection

    @Test func theDragDetectionIsRedWhenItIsDownAndAbsentWhileItWaits() {
        #expect(HealthRules.dragDetection(.waiting) == nil)
        #expect(HealthRules.dragDetection(.failed) == .failure)
        #expect(HealthRules.dragDetection(running()) == .good)
        #expect(HealthRules.dragDetection(running(listening: false)) == .failure)

        var f = healthy
        f.engine = .failed
        let groups = HealthReport.groups(for: f)
        #expect(row("drag detection", in: groups)?.word == HealthWords.failed)
        #expect(group("snapping", in: groups)?.warnings == [HealthWords.dragDetectionFix])
        // The rest of the detection only reports while it runs.
        #expect(row("fn drags", in: groups) == nil)
        #expect(row("spaces", in: groups) == nil)
        #expect(HealthSummary(groups: groups).level == .failure)
    }

    @Test func whatTheRunningDetectionReportsIsOrangeAtWorst() {
        var f = healthy
        f.engine = running(fn: false, spaces: false)
        let groups = HealthReport.groups(for: f)
        #expect(row("drag detection", in: groups)?.level == .good)
        #expect(row("fn drags", in: groups)?.level == .warning)
        #expect(row("spaces", in: groups)?.level == .warning)
        #expect(HealthSummary(groups: groups).blocking == 0)
        #expect(HealthSummary(groups: groups).toLookAt == 2)
    }

    /// A pause for answering too slowly is the app's own fault; one macOS makes for its own reasons is only
    /// worth knowing, and none is green.
    @Test func pausesAreOrangeOnlyWhenTheAppWasTooSlow() {
        #expect(HealthRules.pauses(slow: 0, byMacOS: 0) == .good)
        #expect(HealthRules.pauses(slow: 0, byMacOS: 3) == .info)
        #expect(HealthRules.pauses(slow: 1, byMacOS: 3) == .warning)
        var f = healthy
        #expect(row("pauses", in: HealthReport.groups(for: f))?.word == HealthWords.never)
        f.engine = running(slow: 1, byMacOS: 2)
        let pauses = row("pauses", in: HealthReport.groups(for: f))
        #expect(pauses?.word == "3")
        #expect(pauses?.detail == HealthWords.pausesDetail(slow: 1, byMacOS: 2))
    }

    // MARK: What the snapping has done

    @Test func theLastSnapIsAReadingAndSaysWhenItWas() {
        var f = healthy
        #expect(row("last snap", in: HealthReport.groups(for: f))?.word == HealthWords.noneYet)
        #expect(row("last snap", in: HealthReport.groups(for: f))?.detail == nil)
        let snap = f.now.addingTimeInterval(-125)
        f.lastSnap = snap
        let last = row("last snap", in: HealthReport.groups(for: f))
        #expect(last?.level == .info)
        #expect(last?.word == HealthWords.ago(seconds: 125))
        #expect(last?.detail == HealthReport.stamp(snap))
    }

    @Test func agoReadsInTheOneUnitThatReadsBest() {
        #expect(HealthWords.ago(seconds: 59) == L("\(59) s ago"))
        #expect(HealthWords.ago(seconds: 60) == L("\(1) min ago"))
        #expect(HealthWords.ago(seconds: 3_599) == L("\(59) min ago"))
        #expect(HealthWords.ago(seconds: 3_600) == L("\(1) h ago"))
        #expect(HealthWords.ago(seconds: 2 * 86_400 + 5) == L("\(2) d ago"))
        #expect(HealthWords.ago(seconds: -4) == L("\(0) s ago"))
    }

    @Test func windowsSnapAssistCouldNotPutBackAreOrange() {
        #expect(HealthRules.stranded(0) == .good)
        #expect(HealthRules.stranded(2) == .warning)
        #expect(HealthRules.stranded(0, recordReadable: false) == .warning)
        var f = healthy
        f.strandedWindows = 2
        let groups = HealthReport.groups(for: f)
        #expect(row("stranded", in: groups)?.word == "2")
        #expect(group("snapping", in: groups)?.warnings == [HealthWords.strandedFix])
    }

    /// A record of parked windows that could not be read at launch: nothing will put them back, and the
    /// fix says where to look.
    @Test func aParkedRecordThatCouldNotBeReadIsOrange() {
        var f = healthy
        f.parkedRecordReadable = false
        let groups = HealthReport.groups(for: f)
        #expect(row("stranded", in: groups)?.word == HealthWords.invalid)
        #expect(group("snapping", in: groups)?.warnings == [HealthWords.parkedRecordFix])
    }

    @Test func countsOfWhatIsOnScreenAreReadings() {
        var f = healthy
        f.snappedWindows = 3
        f.handlePlaces = 2
        var groups = HealthReport.groups(for: f)
        #expect(row("snapped windows", in: groups)?.level == .info)
        #expect(row("snapped windows", in: groups)?.word == "3")
        #expect(row("handle places", in: groups)?.word == "2")
        f.handlesOn = false
        groups = HealthReport.groups(for: f)
        #expect(row("handle places", in: groups)?.level == .info)
        #expect(row("handle places", in: groups)?.word == HealthWords.disabled)
    }

    @Test func aSavedListOfSizesThatCouldNotBeReadIsOrange() {
        var f = healthy
        f.windowSizes = WindowSizesFact(readable: true, builtIn: 40, measured: 3, edited: 1)
        var sizes = row("window sizes", in: HealthReport.groups(for: f))
        #expect(sizes?.level == .info)
        #expect(sizes?.word == HealthWords.apps(44))
        #expect(sizes?.detail == HealthWords.windowSizesDetail(builtIn: 40, measured: 3, edited: 1))
        f.windowSizes.readable = false
        sizes = row("window sizes", in: HealthReport.groups(for: f))
        #expect(sizes?.level == .warning)
        #expect(sizes?.word == HealthWords.invalid)
    }

    // MARK: Custom areas

    @Test func customAreasSwitchedOffAreBlueAndBrokenTextIsOrange() {
        #expect(HealthRules.customAreas(enabled: false, valid: false) == .info)
        #expect(HealthRules.customAreas(enabled: true, valid: true) == .good)
        #expect(HealthRules.customAreas(enabled: true, valid: false) == .warning)
        var f = healthy
        f.customAreas = .valid(areas: 3)
        #expect(row("custom areas", in: HealthReport.groups(for: f))?.detail == HealthWords.areas(3))
        f.customAreas = .invalid("line 2 column 3")
        var groups = HealthReport.groups(for: f)
        #expect(row("custom areas", in: groups)?.word == HealthWords.invalid)
        #expect(row("custom areas", in: groups)?.detail == "line 2 column 3")
        #expect(group("custom areas", in: groups)?.warnings == [HealthWords.customAreasFix])
        f.customAreasOn = false
        groups = HealthReport.groups(for: f)
        #expect(row("custom areas", in: groups)?.word == HealthWords.disabled)
        #expect(group("custom areas", in: groups)?.warnings == [])
    }

    // MARK: Compatibility

    /// The switch is the user's; each line reports the Mac, whatever the switch says.
    @Test func hiddenFeaturesReportTheMacAndTheSwitchIsTheUsers() {
        #expect(HealthRules.hiddenFeatures(on: false) == .info)
        #expect(HealthRules.hiddenFeature(available: false) == .warning)
        var f = healthy
        f.hiddenFeaturesOn = false
        f.hiddenFeatures.append(HiddenFeatureFact(id: "snapBarBlur", title: "Blur behind the snap bar",
                                                  available: false, detail: "OBJC_CLASS_$_CAFilter: not found"))
        let groups = HealthReport.groups(for: f)
        #expect(row("hidden features", in: groups)?.word == HealthWords.disabled)
        #expect(row("hidden feature windowMatching", in: groups)?.word == HealthWords.available)
        let blur = row("hidden feature snapBarBlur", in: groups)
        #expect(blur?.word == HealthWords.missing)
        #expect(blur?.detail == "OBJC_CLASS_$_CAFilter: not found")
        #expect(HealthSummary(groups: groups).toLookAt == 1)
    }

    @Test func eachDisplaySaysWhichBarItGets() {
        var f = healthy
        f.displays.append(DisplayFact(id: 2, name: "LG", isBuiltIn: false,
                                      size: CGSize(width: 2560, height: 1440), housing: nil))
        var groups = HealthReport.groups(for: f)
        #expect(row("display 1", in: groups)?.word == HealthWords.surface(.notchShape))
        #expect(row("display 2", in: groups)?.word == HealthWords.surface(.island))
        #expect(row("display 2", in: groups)?.label == HealthWords.snapBarOn(display: "LG"))
        #expect(row("display 2", in: groups)?.detail == "2560 × 1440 pt")
        f.snapBarAppearance = .notchOrBar
        groups = HealthReport.groups(for: f)
        #expect(row("display 2", in: groups)?.word == HealthWords.surface(.floatingBar))
        f.snapBarOn = false
        #expect(row("display 1", in: HealthReport.groups(for: f))?.word == HealthWords.disabled)
    }

    // MARK: The App group

    @Test func aLoginItemSwitchedOffHereIsOnlyWorthKnowing() {
        #expect(HealthRules.loginItem(.enabled) == .good)
        #expect(HealthRules.loginItem(.disabled) == .info)
        #expect(HealthRules.loginItem(.needsApproval) == .warning)
        var f = healthy
        f.loginItem = .needsApproval
        #expect(group("app", in: HealthReport.groups(for: f))?.warnings == [HealthWords.loginItemNeedsApprovalFix])
    }

    @Test func anyCrashIsWorthALookAndIsDated() {
        #expect(HealthRules.crashes(0) == .good)
        #expect(HealthRules.crashes(1) == .warning)
        var f = healthy
        #expect(row("crashes", in: HealthReport.groups(for: f))?.word == HealthWords.none)
        let crash = Date(timeIntervalSince1970: 1_789_990_000)
        f.recentCrashes = [crash]
        let crashes = row("crashes", in: HealthReport.groups(for: f))
        #expect(crashes?.level == .warning)
        #expect(crashes?.word == "1")
        #expect(crashes?.detail == HealthWords.lastCrash(HealthReport.stamp(crash)))
    }

    @Test func anAppThatIsNotInstalledIsWorthALook() {
        #expect(HealthRules.location(.applications) == .good)
        #expect(HealthRules.location(.elsewhere(folder: "Tools")) == .info)
        #expect(HealthRules.location(.diskImage) == .warning)
        #expect(HealthRules.location(.temporaryCopy) == .warning)
    }

    @Test func whereTheBundleIs() {
        #expect(HealthRules.location(bundlePath: "/Applications/SnappySnap.app", home: "/Users/a",
                                     readOnlyVolume: false) == .applications)
        #expect(HealthRules.location(bundlePath: "/Users/a/Applications/SnappySnap.app", home: "/Users/a",
                                     readOnlyVolume: false) == .applications)
        #expect(HealthRules.location(bundlePath: "/Volumes/SnappySnap/SnappySnap.app", home: "/Users/a",
                                     readOnlyVolume: true) == .diskImage)
        #expect(HealthRules.location(bundlePath: "/private/var/folders/x/AppTranslocation/1/d/SnappySnap.app",
                                     home: "/Users/a", readOnlyVolume: true) == .temporaryCopy)
        #expect(HealthRules.location(bundlePath: "/Users/a/Tools/SnappySnap.app", home: "/Users/a",
                                     readOnlyVolume: false) == .elsewhere(folder: "Tools"))
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

    @Test func durationsReadInTheTwoLargestUnits() {
        #expect(HealthWords.duration(seconds: 30) == L("Less than a minute"))
        #expect(HealthWords.duration(seconds: 125) == L("\(2) min"))
        #expect(HealthWords.duration(seconds: 3_720) == L("\(1) h \(2) min"))
        #expect(HealthWords.duration(seconds: 2 * 86_400 + 3 * 3_600 + 59) == L("\(2) d \(3) h"))
    }

    // MARK: The overview

    @Test func aHealthyMacReadsGreenAndBlue() {
        let groups = HealthReport.groups(for: healthy)
        let summary = HealthSummary(groups: groups)
        #expect(summary.level == .good)
        #expect(HealthReport.summaryWord(summary) == HealthWords.everythingWorks)
        #expect(groups.flatMap(\.rows).allSatisfy { $0.level == .good || $0.level == .info })
        #expect(row("memory", in: groups)?.word == HealthWords.megabytes(48))
        #expect(row("running for", in: groups)?.word == HealthWords.duration(seconds: 3_720))
    }

    @Test func redWinsOverOrangeInTheOverview() {
        let rows = [HealthRow(id: "a", label: "A", level: .warning, word: "x"),
                    HealthRow(id: "b", label: "B", level: .failure, word: "x"),
                    HealthRow(id: "c", label: "C", level: .info, word: "x")]
        let summary = HealthSummary(groups: [HealthGroup(id: "g", title: "G", rows: rows)])
        #expect(summary.blocking == 1)
        #expect(summary.toLookAt == 1)
        #expect(summary.level == .failure)
        #expect(HealthReport.summaryWord(summary) == HealthWords.notWorking(problems: 1))
    }

    @Test func orangeAloneCountsWhatToLookAt() {
        let rows = [HealthRow(id: "a", label: "A", level: .warning, word: "x"),
                    HealthRow(id: "b", label: "B", level: .warning, word: "x")]
        let summary = HealthSummary(groups: [HealthGroup(id: "g", title: "G", rows: rows)])
        #expect(summary.level == .warning)
        #expect(HealthReport.summaryWord(summary) == HealthWords.toLookAt(2))
    }

    @Test func aFixIsShownOnlyWhileItsRowIsOrangeOrRedAndOnce() {
        let fine = HealthRow(id: "a", label: "A", level: .good, word: "x", fix: "Do this.")
        let wrong = HealthRow(id: "b", label: "B", level: .warning, word: "x", fix: "Do that.")
        let twice = HealthRow(id: "c", label: "C", level: .failure, word: "x", fix: "Do that.")
        #expect(HealthGroup(id: "g", title: "G", rows: [fine, wrong, twice]).warnings == ["Do that."])
        #expect(HealthGroup(id: "g", title: "G", rows: [fine]).warnings == [])
    }

    /// The page's shape: what the app needs from macOS first, then its own subjects, then compatibility and
    /// the app itself. Every row has an id of its own, which is what SwiftUI draws it by.
    @Test func theGroupsComeInPageOrderAndEveryRowIsDistinct() {
        let groups = HealthReport.groups(for: healthy)
        #expect(groups.map(\.id) == ["permissions", "tiling", "snapping", "handles", "custom areas",
                                     "compatibility", "app"])
        let ids = groups.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: The report

    @Test func theReportCarriesEveryRowWithItsLevel() {
        var f = healthy
        f.location = .diskImage
        let groups = HealthReport.groups(for: f)
        let text = HealthReport.text(appName: "SnappySnap", version: "1.0.2", system: "macOS 27.0.0",
                                     groups: groups)
        #expect(text.hasPrefix("SnappySnap 1.0.2, macOS 27.0.0\n\(HealthWords.toLookAt(1))\n"))
        #expect(text.contains("[OK]   \(HealthWords.accessibilityLabel): \(HealthWords.granted)"))
        #expect(text.contains("[INFO] \(HealthWords.memoryLabel): \(HealthWords.megabytes(48))"))
        #expect(text.contains("[WARN] \(HealthWords.locationLabel): \(HealthWords.locationWord(.diskImage)) (/Applications/SnappySnap.app)"))
        // A tooltip of several lines is one line of the report.
        #expect(!text.contains("found\n_"))
    }
}
