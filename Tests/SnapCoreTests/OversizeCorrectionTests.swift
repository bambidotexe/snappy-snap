import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct OversizeCorrectionTests {
    /// The dev Mac's working area: 1512 × 982, a 34 pt menu bar, no Dock.
    private let area = CGRect(x: 0, y: 34, width: 1512, height: 948)
    private let gap = 8.0

    @Test func aZoomedWindowIsBroughtInsideTheGapOnBothAxes() throws {
        let wanted = try #require(OversizeCorrection.correction(for: area, in: area, gap: gap))
        #expect(wanted == CGRect(x: 8, y: 42, width: 1496, height: 932))
    }

    @Test func onlyTheOffendingAxisIsTouched() throws {
        let frame = CGRect(x: 0, y: 300, width: 1512, height: 400)
        let wanted = try #require(OversizeCorrection.correction(for: frame, in: area, gap: gap))
        #expect(wanted == CGRect(x: 8, y: 300, width: 1496, height: 400))
    }

    @Test func aWindowAtTheGapIsNotOversized() {
        let frame = CGRect(x: 8, y: 42, width: 1496, height: 932)
        #expect(OversizeCorrection.correction(for: frame, in: area, gap: gap) == nil)
    }

    /// Terminal's measured grid: 18 pt rows and 8 pt columns, rounded to the nearest cell, ties up.
    @Test func aTerminalRoundedUpIsAskedForASizeThatRoundsDown() throws {
        let asked = CGRect(x: 8, y: 42, width: 1496, height: 932)
        let landed = CGRect(x: 8, y: 42, width: 1500, height: 939)
        let retry = try #require(OversizeCorrection.gridRetry(asked: asked, landed: landed))
        #expect(retry == CGRect(x: 8, y: 42, width: 1492, height: 925))
    }

    @Test func anAxisThatLandedInsideKeepsWhatItWasAsked() throws {
        let asked = CGRect(x: 8, y: 42, width: 1496, height: 932)
        let landed = CGRect(x: 8, y: 42, width: 1492, height: 939)
        let retry = try #require(OversizeCorrection.gridRetry(asked: asked, landed: landed))
        #expect(retry == CGRect(x: 8, y: 42, width: 1496, height: 925))
    }

    @Test func anOvershootPastTheRoundingAllowanceIsARefusalNotARetry() {
        let asked = CGRect(x: 8, y: 42, width: 1496, height: 932)
        let landed = CGRect(x: 8, y: 42, width: 1496, height: 932 + HandleDragMath.roundingAllowance + 1)
        #expect(OversizeCorrection.gridRetry(asked: asked, landed: landed) == nil)
    }

    @Test func aLandingOnTheAskIsNeverRetried() {
        let asked = CGRect(x: 8, y: 42, width: 1496, height: 932)
        let landed = CGRect(x: 8, y: 42, width: 1496.5, height: 931)
        #expect(OversizeCorrection.gridRetry(asked: asked, landed: landed) == nil)
    }

    @Test func aRefusedWindowMovedElsewhereIsStillTheSameRefusal() {
        let refused = CGRect(x: 8, y: 42, width: 1496, height: 939)
        let moved = CGRect(x: 200, y: 310, width: 1496, height: 939)
        #expect(OversizeCorrection.sameSize(refused, moved))
        let resized = CGRect(x: 8, y: 42, width: 1496, height: 957)
        #expect(!OversizeCorrection.sameSize(refused, resized))
    }
}
