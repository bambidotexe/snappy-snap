import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct CoveringSurfaceTests {
    private let dock = 20

    @Test func everyLayerBelowTheDockCovers() {
        for layer in [0, 3, 8, 19] { #expect(CoveringSurface.covers(layer: layer, dockLayer: dock)) }
    }

    @Test func theDockTheMenuBarAndOverlaysAboveThemDoNot() {
        for layer in [20, 24, 25, 101, 1000, -2_147_483_603] {
            #expect(!CoveringSurface.covers(layer: layer, dockLayer: dock))
        }
    }

    // The measured case: a 719 × 539 widget at layer 3 over the gap between two halves.
    @Test func aFloatingWidgetOverThePillIsItsOccluder() {
        let a = WindowInfo(id: 1, pid: 10, frame: CGRect(x: 8, y: 42, width: 744, height: 873), zIndex: 0)
        let b = WindowInfo(id: 2, pid: 11, frame: CGRect(x: 760, y: 42, width: 744, height: 873), zIndex: 1)
        let widget = WindowInfo(id: 3, pid: 12, frame: CGRect(x: 400, y: 275, width: 719, height: 539),
                                zIndex: CoveringSurface.zIndex(participantsInFront: 0))
        let pair = try! #require(AdjacencyDetector.pairs(in: [a, b], maxGap: 16, minOverlap: 60).first)
        let pill = HandleBarGeometry.panelRect(for: pair, divider: pair.divider)
        #expect(AdjacencyDetector.occluder(of: pair, pillRect: pill, in: [a, b]) == nil)
        #expect(AdjacencyDetector.occluder(of: pair, pillRect: pill, in: [a, b, widget])?.id == 3)
    }

    @Test func aCovererIsInFrontOfExactlyTheParticipantsListedAfterIt() {
        let z = CoveringSurface.zIndex(participantsInFront: 1)
        #expect(!(z < 0))
        #expect(z < 1)
    }

    @Test func aFloatingWidgetOverACrossingRejectsItsKnob() {
        let windows = [
            WindowInfo(id: 1, pid: 10, frame: CGRect(x: 8, y: 42, width: 744, height: 432), zIndex: 0),
            WindowInfo(id: 2, pid: 11, frame: CGRect(x: 760, y: 42, width: 744, height: 432), zIndex: 1),
            WindowInfo(id: 3, pid: 12, frame: CGRect(x: 8, y: 482, width: 744, height: 433), zIndex: 2),
            WindowInfo(id: 4, pid: 13, frame: CGRect(x: 760, y: 482, width: 744, height: 433), zIndex: 3),
        ]
        let widget = WindowInfo(id: 9, pid: 14, frame: CGRect(x: 500, y: 300, width: 500, height: 400),
                                zIndex: CoveringSurface.zIndex(participantsInFront: 0))
        let centre = { (j: Junction) in abs(j.point.x - 756) < 2 && abs(j.point.y - 478) < 2 }
        #expect(JunctionDetector.junctions(in: windows, maxGap: 16).contains(where: centre))
        let covered = JunctionDetector.junctions(from: JunctionDetector.evaluate(in: windows, coverers: [widget], maxGap: 16))
        #expect(!covered.contains(where: centre))
    }
}
