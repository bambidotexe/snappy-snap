import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct LayoutArrangementTests {
    typealias F = ArrangementFixture

    func member(_ id: UInt32, min: (Double, Double) = (200, 150), maxW: Double? = nil) -> LayoutArrangement.Member {
        LayoutArrangement.Member(windowID: id, limits: SizeLimits(minimum: CGSize(width: min.0, height: min.1), maximumWidth: maxW))
    }

    func arrangement(_ layout: Layout, _ members: [Int: LayoutArrangement.Member]) -> LayoutArrangement {
        LayoutArrangement(layout: layout, area: F.area, gap: F.gap, members: members)
    }

    func near(_ actual: CGRect?, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        actual?.isApproximatelyEqual(to: CGRect(x: x, y: y, width: width, height: height), tolerance: 0.01) == true
    }

    @Test func aBarDropTakesItsNominalCell() {
        let solved = arrangement(LayoutCatalog.twoThirdsOneThird, [0: member(1)]).solve()
        #expect(near(solved.members[0], 8, 8, 986.67, 884))
        #expect(near(solved.open[1], 1002.67, 8, 489.33, 884))
        #expect(solved.withdrawn.isEmpty)
    }

    @Test func membersAreWindowsAndTheOtherCellsAreOpen() {
        let boxes = arrangement(LayoutCatalog.grid2x2, [2: member(7)]).arrangement
        #expect(boxes.aligned)
        #expect(Set(boxes.boxes.map(\.id)) == [.cell(0), .cell(1), .window(7), .cell(3)])
        #expect(boxes.boxes.first { $0.id == .cell(0) }?.limits == SizeLimits(minimum: CGSize(width: 200, height: 150)))
    }

    @Test func theOpenCellIsWhatTheDropLeft() {
        let solved = arrangement(LayoutCatalog.halves, [0: member(1, min: (900, 300))]).solve()
        #expect(near(solved.members[0], 8, 8, 900, 884))
        #expect(near(solved.open[1], 916, 8, 576, 884))
    }

    @Test func aWindowThatWillNotGrowLeavesMoreToTheOpenCell() {
        let solved = arrangement(LayoutCatalog.halves, [0: member(1, maxW: 500)]).solve()
        #expect(near(solved.members[0], 8, 8, 500, 884))
        #expect(near(solved.open[1], 516, 8, 976, 884))
    }

    @Test func aCellPushedOffTheDisplayIsWithdrawn() {
        let solved = arrangement(LayoutCatalog.halves, [0: member(1, min: (1400, 300))]).solve()
        #expect(near(solved.members[0], 8, 8, 1400, 884))
        #expect(solved.open.isEmpty)
        #expect(solved.withdrawn == [1])
    }

    @Test func aLaterMemberReFitsAnEarlierOne() {
        let solved = arrangement(LayoutCatalog.halves, [0: member(1, min: (500, 300)), 1: member(2, min: (900, 300))]).solve()
        #expect(near(solved.members[0], 8, 8, 576, 884))
        #expect(near(solved.members[1], 592, 8, 900, 884))
        #expect(solved.open.isEmpty)
    }

    /// A solution reached elsewhere — by the correction pass, from the same boxes — reads the same way.
    @Test func aSolutionFromElsewhereIsReadTheSameWay() {
        let halves = arrangement(LayoutCatalog.halves, [0: member(1, min: (900, 300))])
        #expect(halves.solved(from: halves.arrangement.solve()) == halves.solve())
        let crowded = arrangement(LayoutCatalog.halves, [0: member(1, min: (1400, 300))])
        #expect(crowded.solved(from: crowded.arrangement.solve()).withdrawn == [1])
    }

    @Test func everyShippedLayoutSolvesToItsCellsWhenNothingBinds() {
        for layout in LayoutCatalog.snapBar {
            let solved = arrangement(layout, [0: member(1)]).solve()
            for index in layout.cells.indices {
                let frame = index == 0 ? solved.members[0] : solved.open[index]
                #expect(frame?.isApproximatelyEqual(to: F.cell(layout, index), tolerance: 0.001) == true,
                        "\(layout.id)[\(index)]")
            }
        }
    }
}

@Suite struct ArrangementFactsTests {
    let limits = SizeLimits(minimum: CGSize(width: 200, height: 150))
    let asked = CGRect(x: 8, y: 8, width: 738, height: 884)
    let before = CGRect(x: 300, y: 200, width: 900, height: 600)

    @Test func aLandingLargerThanAskedIsTheMinimum() {
        let revealed = ArrangementFacts.revealed(limits, asked: asked, landed: CGRect(x: 8, y: 8, width: 900, height: 884), before: before)
        #expect(revealed == SizeLimits(minimum: CGSize(width: 900, height: 150)))
    }

    @Test func aLandingSmallerThanAskedIsTheMaximum() {
        let revealed = ArrangementFacts.revealed(limits, asked: asked, landed: CGRect(x: 8, y: 8, width: 738, height: 600), before: before)
        #expect(revealed == SizeLimits(minimum: CGSize(width: 200, height: 150), maximumHeight: 600))
    }

    @Test func bothAxesAreReadOnTheirOwn() {
        let revealed = ArrangementFacts.revealed(limits, asked: asked, landed: CGRect(x: 8, y: 8, width: 500, height: 950), before: before)
        #expect(revealed == SizeLimits(minimum: CGSize(width: 200, height: 950), maximumWidth: 500))
    }

    @Test func anApplicationRoundingItsOwnFrameRevealsNothing() {
        #expect(ArrangementFacts.revealed(limits, asked: asked, landed: CGRect(x: 8, y: 8, width: 749, height: 873), before: before) == nil)
    }

    @Test func aFrameThatDidNotChangeIsNotEvidence() {
        #expect(ArrangementFacts.revealed(limits, asked: asked, landed: before, before: before) == nil)
    }

    @Test func aMinimumOverAnEarlierMaximumReplacesIt() {
        let capped = SizeLimits(minimum: CGSize(width: 200, height: 150), maximumWidth: 500)
        let revealed = ArrangementFacts.revealed(capped, asked: CGRect(x: 8, y: 8, width: 400, height: 884),
                                                 landed: CGRect(x: 8, y: 8, width: 640, height: 884), before: before)
        #expect(revealed == SizeLimits(minimum: CGSize(width: 640, height: 150)))
    }

    @Test func aMaximumUnderAPresumedMinimumLowersIt() {
        let presumed = SizeLimits(minimum: CGSize(width: 200, height: 150))
        let revealed = ArrangementFacts.revealed(presumed, asked: CGRect(x: 8, y: 8, width: 400, height: 884),
                                                 landed: CGRect(x: 8, y: 8, width: 120, height: 884), before: before)
        #expect(revealed == SizeLimits(minimum: CGSize(width: 120, height: 150), maximumWidth: 120))
    }

    @Test func whatIsAlreadyKnownIsNotRevealedAgain() {
        let known = SizeLimits(minimum: CGSize(width: 900, height: 150))
        #expect(ArrangementFacts.revealed(known, asked: CGRect(x: 8, y: 8, width: 738, height: 884),
                                          landed: CGRect(x: 8, y: 8, width: 900, height: 884), before: before) == nil)
    }
}

@Suite struct ArrangementWriteTests {
    let current = CGRect(x: 8, y: 8, width: 738, height: 884)

    @Test func aFirstWriteIsExactToThePoint() {
        #expect(!ArrangementFacts.isWorthWriting(current, over: current, correcting: false))
        #expect(!ArrangementFacts.isWorthWriting(current.offsetBy(dx: 0.5, dy: 0), over: current, correcting: false))
        #expect(ArrangementFacts.isWorthWriting(current.offsetBy(dx: 2, dy: 0), over: current, correcting: false))
        #expect(ArrangementFacts.isWorthWriting(CGRect(x: 8, y: 8, width: 742, height: 884), over: current, correcting: false))
    }

    /// The frame a correction is compared with is one the application chose for itself: a terminal on
    /// its character grid lands a few points off every time, and asking again would never end.
    @Test func aCorrectionAllowsASizeTheRoundingAllowance() {
        #expect(!ArrangementFacts.isWorthWriting(CGRect(x: 8, y: 8, width: 749, height: 873), over: current, correcting: true))
        #expect(ArrangementFacts.isWorthWriting(CGRect(x: 8, y: 8, width: 751, height: 884), over: current, correcting: true))
    }

    @Test func aCorrectionStillMovesAWindowThatStandsInTheWrongPlace() {
        #expect(ArrangementFacts.isWorthWriting(current.offsetBy(dx: 0, dy: 3), over: current, correcting: true))
    }
}
