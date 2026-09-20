import Testing
import Foundation
@testable import SnapCore

/// When the app asks GitHub without being asked to.
@Suite struct UpdateScheduleTests {
    private let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let week: TimeInterval = 7 * 24 * 3600

    @Test func aFreshScheduleIsDueSoTheLaunchCheckRuns() {
        #expect(UpdateSchedule().isDue(now: launch))
    }

    @Test func anAnswerHoldsTheNextCheckForAWeek() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        #expect(!schedule.isDue(now: launch + week - 1))
        #expect(schedule.isDue(now: launch + week))
    }

    @Test func aFailureIsTriedAgainAnHourLater() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch)
        #expect(!schedule.isDue(now: launch + hour - 1))
        #expect(schedule.isDue(now: launch + hour))
    }

    @Test func aFailureAfterAWeekWaitsItsHourToo() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        schedule.failed(at: launch + week)
        #expect(!schedule.isDue(now: launch + week + 60))
        #expect(schedule.isDue(now: launch + week + hour))
    }

    @Test func anAnswerClearsTheFailureBeforeIt() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch)
        schedule.answered(at: launch + 60)
        #expect(!schedule.isDue(now: launch + hour))
        #expect(schedule.isDue(now: launch + 60 + week))
    }

    @Test func aClockSetBackMakesTheCheckDueRatherThanLate() {
        var schedule = UpdateSchedule()
        schedule.answered(at: launch)
        #expect(schedule.isDue(now: launch - 60))
    }

    @Test func aFailureDatedInTheFutureDoesNotHoldTheCheck() {
        var schedule = UpdateSchedule()
        schedule.failed(at: launch + 10 * hour)
        #expect(schedule.isDue(now: launch))
    }

    @Test func theTickIsShortEnoughToMeetTheRetry() {
        #expect(Settings.Fixed.updateTick < Settings.Fixed.updateRetryDelay)
        #expect(Settings.Fixed.updateInterval == week)
    }
}

/// The Updates group of the Settings window.
@Suite struct UpdatePanelTests {
    private let release = LatestRelease(version: ReleaseVersion(1, 2, 0),
                                        dmgURL: URL(string: "https://example.invalid/SnappySnap-1.2.0.dmg")!)

    private func panelWithRelease() -> UpdatePanel {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checked(.available(release))
        return panel
    }

    @Test func itStartsWithNothingToReport() {
        let panel = UpdatePanel()
        #expect(panel.state == .idle)
        #expect(!panel.isBusy)
        #expect(!panel.offersUpdate)
    }

    @Test func theFirstPressChecksAndASecondOneStartsNothing() {
        var panel = UpdatePanel()
        let first = panel.press()
        #expect(first == .check)
        #expect(panel.state == .checking)
        #expect(panel.isBusy)
        let second = panel.press()
        #expect(second == nil)
    }

    @Test func upToDateChecksAgainOnTheNextPress() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checked(.upToDate)
        #expect(panel.state == .upToDate)
        #expect(!panel.offersUpdate)
        let next = panel.press()
        #expect(next == .check)
    }

    @Test func aNewerReleaseTurnsTheButtonIntoUpdate() {
        let panel = panelWithRelease()
        #expect(panel.state == .available(release.version))
        #expect(panel.offersUpdate)
    }

    @Test func noReleaseAndAFailedCheckBothCheckAgain() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.checked(.noRelease)
        #expect(panel.state == .noRelease)
        let afterNoRelease = panel.press()
        #expect(afterNoRelease == .check)
        panel.checkFailed("offline")
        #expect(panel.state == .checkFailed("offline"))
        let afterFailure = panel.press()
        #expect(afterFailure == .check)
    }

    @Test func aPressWithAReleaseOpensTheUpdateAndKeepsTheRow() {
        var panel = panelWithRelease()
        let press = panel.press()
        #expect(press == .update(release))
        #expect(panel.state == .available(release.version))
        // Every press is the same request: the window is shown again.
        let again = panel.press()
        #expect(again == .update(release))
    }

    @Test func anAutomaticNewerReleaseShowsLikeTheAnswerToAPress() {
        var panel = UpdatePanel()
        panel.autoChecked(.available(release))
        #expect(panel.state == .available(release.version))
        let press = panel.press()
        #expect(press == .update(release))
    }

    @Test func anAutomaticUpToDateIsShownAndAnAutomaticNoReleaseIsNot() {
        var panel = panelWithRelease()
        panel.autoChecked(.noRelease)
        #expect(panel.state == .available(release.version))
        panel.autoChecked(.upToDate)
        #expect(panel.state == .upToDate)
        #expect(!panel.offersUpdate)
    }

    @Test func anAutomaticAnswerNeverInterruptsAPress() {
        var panel = UpdatePanel()
        _ = panel.press()
        panel.autoChecked(.upToDate)
        #expect(panel.state == .checking)
    }

    @Test func aFailedInstallKeepsItsReasonWhileTheReleaseFoundAgainBecomesTheRetry() {
        var panel = UpdatePanel()
        panel.installFailed("did not start")
        #expect(panel.state == .installFailed("did not start"))
        let afterFailedInstall = panel.press()
        #expect(afterFailedInstall == .check)
        panel.checkFailed("offline")
        panel.installFailed("did not start")
        panel.autoChecked(.available(release))
        #expect(panel.state == .installFailed("did not start"))
        let retry = panel.press()
        #expect(retry == .update(release))
    }
}

/// The update window, from the press of Update to the quit.
@Suite struct UpdateSessionTests {
    private let sized = LatestRelease(version: ReleaseVersion(1, 2, 0),
                                      dmgURL: URL(string: "https://example.invalid/S.dmg")!, dmgSize: 1000)
    private let unsized = LatestRelease(version: ReleaseVersion(1, 2, 0),
                                        dmgURL: URL(string: "https://example.invalid/S.dmg")!)

    private func readySession() -> UpdateSession {
        var session = UpdateSession(release: sized)
        session.downloaded()
        session.prepared()
        return session
    }

    @Test func itStartsDownloadingWithGitHubsSizeAsTheTotal() {
        let session = UpdateSession(release: sized)
        #expect(session.phase == .downloading(received: 0, expected: 1000))
        #expect(session.fraction == 0)
        #expect(!session.canInstall)
        #expect(session.canCancel)
    }

    @Test func theBarFollowsTheBytesAndNeverOverflows() {
        var session = UpdateSession(release: sized)
        session.received(250, of: 1000)
        #expect(session.fraction == 0.25)
        session.received(1500, of: 1000)
        #expect(session.fraction == 1)
    }

    @Test func aResponseWithoutALengthFallsBackOnGitHubsSize() {
        var session = UpdateSession(release: sized)
        session.received(500, of: -1)
        #expect(session.phase == .downloading(received: 500, expected: 1000))
        #expect(session.fraction == 0.5)
    }

    @Test func noTotalAtAllIsAnIndeterminateBar() {
        var session = UpdateSession(release: unsized)
        session.received(500, of: -1)
        #expect(session.fraction == nil)
    }

    @Test func theButtonEnablesOnlyOnceTheUpdateIsPrepared() {
        var session = UpdateSession(release: sized)
        session.downloaded()
        #expect(session.phase == .preparing)
        #expect(session.fraction == nil)
        #expect(!session.canInstall)
        session.prepared()
        #expect(session.phase == .ready)
        #expect(session.fraction == 1)
        #expect(session.canInstall)
        session.received(10, of: 1000)
        #expect(session.phase == .ready, "progress after the download is ignored")
    }

    @Test func anAppThatCannotReplaceItselfOffersTheDiskImage() {
        var session = UpdateSession(release: sized)
        session.downloaded()
        session.cannotReplace()
        #expect(session.phase == .manual)
        #expect(!session.canInstall)
        #expect(session.fraction == 1)
    }

    @Test func installStartsOnceAndOnlyWhenReady() {
        var session = readySession()
        let started = session.install()
        #expect(started)
        #expect(session.phase == .installing)
        #expect(!session.canCancel)
        let startedTwice = session.install()
        #expect(!startedTwice, "a second click starts no second install")

        var early = UpdateSession(release: sized)
        let startedEarly = early.install()
        #expect(!startedEarly)
        #expect(early.phase == .downloading(received: 0, expected: 1000))
    }

    @Test func aFailureKeepsItsReasonAndCanBeRetried() {
        var session = UpdateSession(release: sized)
        session.received(400, of: 1000)
        session.failed("offline")
        #expect(session.phase == .failed("offline"))
        #expect(!session.canInstall)
        let retried = session.retry()
        #expect(retried)
        #expect(session.phase == .downloading(received: 0, expected: 1000))

        var ready = readySession()
        let retriedForNothing = ready.retry()
        #expect(!retriedForNothing, "nothing failed, nothing to retry")
        #expect(ready.phase == .ready)
    }

    @Test func anInstallThatDidNotQuitTheAppCanBeTriedAgainWithoutFetchingAgain() {
        var session = readySession()
        #expect(!session.stalled)
        _ = session.install()
        session.installStalled()
        #expect(session.phase == .ready)
        #expect(session.stalled)
        let startedAgain = session.install()
        #expect(startedAgain)
        #expect(!session.stalled, "the next try starts clean")
    }
}

/// What the copy taken out of a disk image has to say about itself.
@Suite struct StagedUpdateCheckTests {
    private func rejection(identifier: String? = "dev.rubens.SnappySnap", version: String? = "1.2.0",
                           minimumSystem: String? = "26.0", running: String = "1.1.0") -> StagedUpdateCheck.Rejection? {
        StagedUpdateCheck.rejection(
            staged: .init(bundleIdentifier: identifier, version: version, minimumSystemVersion: minimumSystem),
            runningIdentifier: "dev.rubens.SnappySnap", runningVersion: running,
            systemVersion: ReleaseVersion(27, 0, 0))
    }

    @Test func aNewerCopyOfTheSameAppIsAccepted() {
        #expect(rejection() == nil)
    }

    @Test func anotherAppIsRefused() {
        #expect(rejection(identifier: "com.example.other") == .wrongApp)
        #expect(rejection(identifier: nil) == .wrongApp)
    }

    @Test func theSameOrAnOlderVersionIsRefusedSoAnInstallCannotLoopOrGoBack() {
        #expect(rejection(version: "1.1.0") == .notNewer("1.1.0"))
        #expect(rejection(version: "1.0.9") == .notNewer("1.0.9"))
        #expect(rejection(version: nil) == .notNewer(nil))
        #expect(rejection(version: "banana") == .notNewer("banana"))
    }

    @Test func aRunningVersionThatDoesNotParseIsNeverReplaced() {
        #expect(rejection(running: "") == .notNewer("1.2.0"))
    }

    @Test func aCopyThatNeedsANewerMacOSIsRefused() {
        #expect(rejection(minimumSystem: "28.0") == .needsNewerSystem("28.0"))
        #expect(rejection(minimumSystem: "27.0") == nil)
        #expect(rejection(minimumSystem: nil) == nil, "no stated minimum is no obstacle")
    }
}

/// The one line the install helper leaves for the next launch.
@Suite struct UpdateResultTests {
    @Test func resultLinesRoundTrip() {
        for value in [UpdateResult.installed(version: "1.2.0"), .failed(version: "1.2.0", reason: .replace),
                      .failed(version: "1.2.0", reason: .launch), .failed(version: "1.2.0", reason: .stranded)] {
            #expect(UpdateResult(line: value.line + "\n") == value)
        }
        #expect(UpdateResult(line: "") == nil)
        #expect(UpdateResult(line: "installed") == nil)
        #expect(UpdateResult(line: "failed 1.2.0 weather") == nil)
    }

    @Test func anOutcomeIsOnlyNewsForTenMinutes() {
        #expect(UpdateResult.isNews(age: 3))
        #expect(UpdateResult.isNews(age: Settings.Fixed.updateResultShelfLife))
        #expect(!UpdateResult.isNews(age: Settings.Fixed.updateResultShelfLife + 1), "a line left behind days ago opens no window")
        #expect(!UpdateResult.isNews(age: -5), "a clock set back proves nothing")
    }

    @Test func thePlanHandsTheHelperItsArgumentsInTheOrderItReadsThem() {
        let plan = UpdateInstallPlan(pid: 42, destination: URL(filePath: "/Applications/SnappySnap.app"),
                                     staged: URL(filePath: "/u/staged/SnappySnap.app"),
                                     backup: URL(filePath: "/u/previous/SnappySnap.app"),
                                     resultFile: URL(filePath: "/u/result"), logFile: URL(filePath: "/u/install.log"),
                                     executableName: "SnappySnap", version: "1.2.0")
        #expect(plan.arguments == ["42", "/Applications/SnappySnap.app", "/u/staged/SnappySnap.app",
                                   "/u/previous/SnappySnap.app", "/u/result", "/u/install.log", "SnappySnap",
                                   "1.2.0", "-", "30", "15", "2"])
    }
}
