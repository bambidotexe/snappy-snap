import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct OcclusionTests {
    let window = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func nothingInFrontIsWhollyVisible() {
        #expect(Occlusion.visibleFraction(of: window, under: []) == 1)
    }

    @Test func aWindowCoveringAllOfItLeavesNothing() {
        #expect(Occlusion.visibleFraction(of: window, under: [CGRect(x: -10, y: -10, width: 200, height: 200)]) == 0)
    }

    @Test func halfCoveredIsHalfVisible() {
        #expect(Occlusion.visibleFraction(of: window, under: [CGRect(x: 0, y: 0, width: 50, height: 100)]) == 0.5)
    }

    @Test func twoCoversThatOverlapAreCountedOnce() {
        let covers = [CGRect(x: 0, y: 0, width: 60, height: 100), CGRect(x: 40, y: 0, width: 60, height: 100)]
        #expect(Occlusion.visibleFraction(of: window, under: covers) == 0)
        let partial = [CGRect(x: 0, y: 0, width: 60, height: 50), CGRect(x: 40, y: 0, width: 60, height: 50)]
        #expect(Occlusion.visibleFraction(of: window, under: partial) == 0.5)
    }

    @Test func aWindowStandingElsewhereHidesNothing() {
        #expect(Occlusion.visibleFraction(of: window, under: [CGRect(x: 300, y: 300, width: 100, height: 100)]) == 1)
    }

    @Test func aWindowWithNoAreaIsNotVisible() {
        #expect(Occlusion.visibleFraction(of: .zero, under: []) == 0)
    }
}

@Suite struct NeighbourEvidenceTests {
    let area = ArrangementFixture.area
    let gap = ArrangementFixture.gap
    let leftHalf = CGRect(x: 8, y: 8, width: 738, height: 884)

    func window(_ id: UInt32, _ frame: CGRect, z: Int = 0) -> SnapOccupant {
        SnapOccupant(windowID: id, pid: 1, frame: frame, minimum: nil, zIndex: z)
    }

    // MARK: How many sides of the working area a window stands against

    @Test func aHalfStandsAgainstThreeSidesAndAQuarterAgainstTwo() {
        #expect(NeighbourEvidence.alignedSides(of: leftHalf, in: area, gap: gap) == 3)
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 754, y: 454, width: 738, height: 438), in: area, gap: gap) == 2)
    }

    @Test func aMiddleColumnStandsAgainstTopAndBottom() {
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 508, y: 8, width: 484, height: 884), in: area, gap: gap) == 2)
    }

    @Test func aWindowUnderTheMenuBarStandsAgainstOneAndAFloatingOneAgainstNone() {
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 500, y: 8, width: 600, height: 592), in: area, gap: gap) == 1)
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 300, y: 200, width: 600, height: 400), in: area, gap: gap) == 0)
    }

    @Test func aWindowFlushWithTheAreaCountsLikeOneAGapAway() {
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 0, y: 0, width: 750, height: 900), in: area, gap: gap) == 3)
    }

    @Test func thirteenPointsFromAnEdgeIsNotAgainstIt() {
        // gap + 4 is the reach: 12 pt counts, 13 does not.
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 12, y: 200, width: 600, height: 400), in: area, gap: gap) == 1)
        #expect(NeighbourEvidence.alignedSides(of: CGRect(x: 13, y: 200, width: 600, height: 400), in: area, gap: gap) == 0)
    }

    // MARK: Whether a window counts

    @Test func aTiledVisibleWindowCounts() {
        #expect(NeighbourEvidence.rejection(of: window(1, leftHalf), among: [], area: area, gap: gap) == nil)
    }

    @Test func aWindowTouchingOneSideDoesNotCount() {
        let underMenuBar = window(1, CGRect(x: 500, y: 8, width: 600, height: 592))
        #expect(NeighbourEvidence.rejection(of: underMenuBar, among: [], area: area, gap: gap) == .touches(sides: 1))
    }

    @Test func aWindowHiddenBehindAnotherDoesNotCount() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884), z: 5)
        let cover = window(2, CGRect(x: 4, y: 4, width: 1300, height: 892), z: 1)
        #expect(NeighbourEvidence.rejection(of: third, among: [cover], area: area, gap: gap) == .hidden(visible: 0))
    }

    @Test func aWindowInFrontOfAnotherIsNotHiddenByIt() {
        let third = window(1, CGRect(x: 8, y: 8, width: 489, height: 884), z: 0)
        let behind = window(2, CGRect(x: 4, y: 4, width: 1300, height: 892), z: 3)
        #expect(NeighbourEvidence.rejection(of: third, among: [behind], area: area, gap: gap) == nil)
    }

    @Test func halfVisibleStillCounts() {
        let half = window(1, leftHalf, z: 2)
        let cover = window(2, CGRect(x: 8, y: 8, width: 369, height: 884), z: 0)
        #expect(NeighbourEvidence.rejection(of: half, among: [cover], area: area, gap: gap) == nil)
    }

    @Test func aWindowLeavingTheWorkingAreaDoesNotCount() {
        let outside = window(1, CGRect(x: 8, y: 8, width: 738, height: 895))
        #expect(NeighbourEvidence.rejection(of: outside, among: [], area: area, gap: gap) == .outsideTheArea)
    }

    @Test func theListIsSplitIntoThoseThatCountAndWhyTheOthersDoNot() {
        let tiled = window(1, leftHalf, z: 1)
        let floater = window(2, CGRect(x: 800, y: 200, width: 400, height: 300), z: 0)
        let result = NeighbourEvidence.neighbours(among: [tiled, floater], area: area, gap: gap)
        #expect(result.accepted == [tiled])
        #expect(result.rejected.map(\.window) == [floater])
        #expect(result.rejected.map(\.reason) == [.touches(sides: 0)])
    }
}
