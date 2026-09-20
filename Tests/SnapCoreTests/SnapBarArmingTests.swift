import Testing
@testable import SnapCore

@Suite struct SnapBarArmingTests {
    let primary: UInt32 = 1
    let secondary: UInt32 = 2

    @Test func enteringTheRegionStartsAClockAndDrawsNothing() {
        var arming = SnapBarArming()
        #expect(arming.step(armed: true, displayID: primary, barShown: false) == .startDwell)
        #expect(arming.pending == primary)
    }

    @Test func movingWithinTheRegionKeepsTheSameClock() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        #expect(arming.step(armed: true, displayID: primary, barShown: false) == .keepWaiting)
        #expect(arming.step(armed: true, displayID: primary, barShown: false) == .keepWaiting)
        #expect(arming.pending == primary)
    }

    @Test func leavingTheRegionDropsTheClock() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        #expect(arming.step(armed: false, displayID: primary, barShown: false) == .cancel)
        #expect(arming.pending == nil)
    }

    /// The point of the whole feature: time already waited is never carried over, so a pointer that
    /// dips out and back in waits the full dwell again rather than arriving early.
    @Test func reEnteringStartsAFreshClock() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        _ = arming.step(armed: false, displayID: primary, barShown: false)
        #expect(arming.step(armed: true, displayID: primary, barShown: false) == .startDwell)
    }

    /// A clock that ran out while the pointer was still in the region is what shows the bar.
    @Test func elapsedShowsTheBarForTheDisplayItWaitedOn() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        let shows = arming.elapsed(displayID: primary)
        #expect(shows)
        #expect(arming.pending == nil)
    }

    @Test func elapsedIsRefusedAfterThePointerLeft() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        _ = arming.step(armed: false, displayID: primary, barShown: false)
        let shows = arming.elapsed(displayID: primary)
        #expect(!shows)
    }

    @Test func elapsedIsRefusedForADisplayThatIsNotTheOneWaitedOn() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        let shows = arming.elapsed(displayID: secondary)
        #expect(!shows)
        // A refused clock still ends the wait: a wait is only ever answered once.
        #expect(arming.pending == nil)
    }

    @Test func elapsedIsRefusedTwiceOver() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        let first = arming.elapsed(displayID: primary)
        let second = arming.elapsed(displayID: primary)
        #expect(first)
        #expect(!second)
    }

    /// Crossing into another display's arming region abandons the first clock rather than counting
    /// the pointer's time on one display towards the bar on the other.
    @Test func crossingToAnotherDisplayStartsOver() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        #expect(arming.step(armed: true, displayID: secondary, barShown: false) == .startDwell)
        #expect(arming.pending == secondary)
        let showsOnPrimary = arming.elapsed(displayID: primary)
        #expect(!showsOnPrimary)
    }

    /// The dwell is for summoning a bar, not for moving one: a bar already up follows the pointer to
    /// another display on the event, as it always has.
    @Test func aBarAlreadyUpMovesWithNoWait() {
        var arming = SnapBarArming()
        #expect(arming.step(armed: true, displayID: secondary, barShown: true) == .showNow)
        #expect(arming.pending == nil)
    }

    @Test func aBarAlreadyUpEndsAClockThatWasRunning() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        #expect(arming.step(armed: true, displayID: secondary, barShown: true) == .showNow)
        #expect(arming.pending == nil)
    }

    @Test func outsideTheRegionIsCancelWhateverTheBarIsDoing() {
        var arming = SnapBarArming()
        #expect(arming.step(armed: false, displayID: primary, barShown: true) == .cancel)
        #expect(arming.step(armed: false, displayID: primary, barShown: false) == .cancel)
    }

    @Test func cancelDropsAClockInFlight() {
        var arming = SnapBarArming()
        _ = arming.step(armed: true, displayID: primary, barShown: false)
        arming.cancel()
        #expect(arming.pending == nil)
        let shows = arming.elapsed(displayID: primary)
        #expect(!shows)
        // And the next entry is a fresh wait, not a resumed one.
        #expect(arming.step(armed: true, displayID: primary, barShown: false) == .startDwell)
    }

    @Test func aFreshRuleIsWaitingForNothing() {
        #expect(SnapBarArming().pending == nil)
    }
}
