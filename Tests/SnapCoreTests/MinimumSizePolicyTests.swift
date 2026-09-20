import Foundation
import Testing
@testable import SnapCore

@Suite struct MinimumSizePolicyTests {
    // MARK: - Clamping without a probe

    /// Nothing measured, nothing to honour: the bound is the whole answer.
    @Test func withNothingStoredTheFloorIsTheBound() {
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: nil) == MinimumSizePolicy.unprobedFloor)
    }

    /// A record reads 0 on an axis nobody has measured, so an all-zero record says exactly what no
    /// record says. The two must not be able to disagree.
    @Test func anAllZeroRecordSaysTheSameThingAsNoRecord() {
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: .zero) == MinimumSizePolicy.unprobedFloor)
    }

    /// **The switch forbids the measurement, not the knowledge.** A floor already learned — by an
    /// earlier probe, by the deck, or from a refusal — is still the truth about that window, so it
    /// still stops the divider.
    @Test func aKnownFloorLargerThanTheBoundStillWins() {
        let stored = CGSize(width: 640, height: 480)
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: stored) == stored)
    }

    /// Per axis independently, which is the entire reason an unmeasured axis reads 0 rather than
    /// making the whole record unusable.
    @Test func eachAxisTakesTheLargerOfTheTwoOnItsOwn() {
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: CGSize(width: 900, height: 0))
                == CGSize(width: 900, height: MinimumSizePolicy.unprobedFloor.height))
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: CGSize(width: 40, height: 700))
                == CGSize(width: MinimumSizePolicy.unprobedFloor.width, height: 700))
    }

    /// The bound is a floor under the floor. An application that says it will go to 10 × 10 is
    /// believed about itself and refused anyway: a window too small to see is one the user cannot get
    /// back, and no gesture in this app may produce one.
    @Test func aKnownFloorSmallerThanTheBoundIsNotHonoured() {
        #expect(MinimumSizePolicy.floorWithoutProbing(stored: CGSize(width: 10, height: 10))
                == MinimumSizePolicy.unprobedFloor)
    }

    // Terminal stands on whole character cells and rounds an ask to the nearest one: 381 → 390 on
    // its 18 pt rows, 520 → 524 on its 8 pt columns.
    @Test func aLandingWithinWhatAnApplicationRoundsByRevealsNoFloor() {
        let floor = MinimumSizePolicy.revealedFloor(landed: CGSize(width: 524, height: 390),
                                                    asked: CGSize(width: 520, height: 381))
        #expect(floor == .zero)
    }

    @Test func aLandingPastTheRoundingAllowanceRevealsTheFloorOnThatAxisOnly() {
        let floor = MinimumSizePolicy.revealedFloor(landed: CGSize(width: 480, height: 390),
                                                    asked: CGSize(width: 300, height: 381))
        #expect(floor == CGSize(width: 480, height: 0))
    }

    @Test func aLandingSmallerThanAskedRevealsNoFloor() {
        let floor = MinimumSizePolicy.revealedFloor(landed: CGSize(width: 280, height: 300),
                                                    asked: CGSize(width: 300, height: 381))
        #expect(floor == .zero)
    }

    // MARK: - Lowering

    /// A saved floor comes down to what a window of it was seen at, per axis, past the 1 pt slack
    /// every application's own rounding needs. Nil when neither axis moves.
    @Test func aFloorIsLoweredPerAxisPastThePointAndNeverRaised() {
        let floor = CGSize(width: 537, height: 316)
        #expect(MinimumSizePolicy.lowered(floor, seeing: CGSize(width: 500, height: 320)) == CGSize(width: 500, height: 316))
        #expect(MinimumSizePolicy.lowered(floor, seeing: CGSize(width: 540, height: 100)) == CGSize(width: 537, height: 100))
        #expect(MinimumSizePolicy.lowered(floor, seeing: CGSize(width: 536, height: 315)) == nil)
        #expect(MinimumSizePolicy.lowered(floor, seeing: CGSize(width: 800, height: 600)) == nil)
    }

    /// A non-positive axis is a window that was not read, not a window with no floor.
    @Test func anAxisThatWasNotReadLowersNothing() {
        let floor = CGSize(width: 537, height: 316)
        #expect(MinimumSizePolicy.lowered(floor, seeing: .zero) == nil)
        #expect(MinimumSizePolicy.lowered(floor, seeing: CGSize(width: -5, height: 100)) == CGSize(width: 537, height: 100))
    }

    // MARK: - A window's own floor

    @Test func aWindowFloorIsRaisedPerAxisAndAnAxisOfZeroSaysNothing() {
        let floor = WindowFloor().raised(by: CGSize(width: 600, height: 0))
        #expect(floor.width == 600)
        #expect(floor.height == nil)
        #expect(floor.size == CGSize(width: 600, height: 0))
        let more = floor.raised(by: CGSize(width: 550, height: 400))
        #expect(more.width == 600)
        #expect(more.height == 400)
        #expect(WindowFloor().isEmpty)
        #expect(!floor.isEmpty)
    }

    @Test func aWindowFloorIsLoweredPerAxisAndAnAxisNothingRaisedStaysUnknown() {
        let floor = WindowFloor(width: 600, height: nil)
        let lowered = floor.lowered(seeing: CGSize(width: 500, height: 200))
        #expect(lowered.width == 500)
        #expect(lowered.height == nil)
        #expect(floor.lowered(seeing: CGSize(width: 599.5, height: 200)) == floor)
        #expect(floor.lowered(seeing: .zero) == floor)
    }

    /// A window's floor is its application's row lifted, per axis, by its own floor. Nil when there
    /// is neither; 0 on an axis nothing knows, which `presumed` fills.
    @Test func aWindowsFloorIsTheRowRaisedByItsOwn() {
        let row = CGSize(width: 537, height: 316)
        #expect(MinimumSizePolicy.floor(row: row, window: nil) == row)
        #expect(MinimumSizePolicy.floor(row: row, window: WindowFloor(width: 600)) == CGSize(width: 600, height: 316))
        #expect(MinimumSizePolicy.floor(row: row, window: WindowFloor(width: 100, height: 400)) == CGSize(width: 537, height: 400))
        #expect(MinimumSizePolicy.floor(row: nil, window: WindowFloor(width: 600)) == CGSize(width: 600, height: 0))
        #expect(MinimumSizePolicy.floor(row: nil, window: nil) == nil)
        #expect(MinimumSizePolicy.floor(row: nil, window: WindowFloor()) == nil)
        #expect(MinimumSizePolicy.presumed(MinimumSizePolicy.floor(row: nil, window: WindowFloor(width: 600)))
                == CGSize(width: 600, height: 150))
    }
}
