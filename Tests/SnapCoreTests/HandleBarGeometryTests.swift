import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct HandleBarGeometryTests {
    /// `#expect` boxes CGFloat against Double and can report identical bit patterns as unequal, so
    /// every scalar comparison in this suite goes through here.
    func near(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool { abs(a - b) <= epsilon }

    func near(_ a: CGRect, _ b: CGRect, _ epsilon: Double = 1e-9) -> Bool {
        a.isApproximatelyEqual(to: b, tolerance: epsilon)
    }

    func near(_ a: CGSize, _ b: CGSize, _ epsilon: Double = 1e-9) -> Bool {
        abs(a.width - b.width) <= epsilon && abs(a.height - b.height) <= epsilon
    }

    /// Follows the shipped default rather than pinning a number: a hardcoded value could drift
    /// from `handleMaxGap`, so a pair outside it returns an empty array. A subscript into that
    /// array traps and crashes the target, which `swift test` reports as a target-level failure
    /// with no issue line and no summary line for that target, so it reads as green if you only
    /// look at the other target's line.
    ///
    /// `try #require`, not `#expect`: **`#expect` does not abort.** It records the failure and carries
    /// straight on into the subscript, which traps and crashes the target exactly the same way.
    func pair(_ a: CGRect, _ b: CGRect, maxGap: Double = Settings().handleMaxGap) throws -> HandlePair {
        let found = AdjacencyDetector.pairs(in: [WindowInfo(id: 1, pid: 1, frame: a, zIndex: 0),
                                                 WindowInfo(id: 2, pid: 2, frame: b, zIndex: 1)],
                                            maxGap: maxGap, minOverlap: 60)
        #expect(found.count == 1, "expected exactly one pair for \(a) and \(b) at maxGap \(maxGap)")
        return try #require(found.first)
    }

    /// macOS's own handle measures 4 × 48 pt (8 × 96 px in a 2× capture, scaled against the window
    /// gap in the same screenshot). These pin that measurement.
    @Test func thePillMatchesTheOneMacOSDraws() throws {
        #expect(near(HandleBarGeometry.pillThickness, 4))
        #expect(near(HandleBarGeometry.maxPillLength, 48))
        #expect(near(HandleBarGeometry.pillSize(orientation: .horizontal, overlap: 800),
                     CGSize(width: 4, height: 48)))
        #expect(near(HandleBarGeometry.pillSize(orientation: .vertical, overlap: 800),
                     CGSize(width: 48, height: 4)))
    }

    @Test func pillLengthFollowsTheOverlapUntilItReachesTheCap() throws {
        #expect(near(HandleBarGeometry.pillLength(overlap: 60), 44))
        #expect(near(HandleBarGeometry.pillLength(overlap: 64), 48))
        #expect(near(HandleBarGeometry.pillLength(overlap: 800), 48))
    }

    @Test func pillLengthNeverGoesBelowTheFloor() throws {
        #expect(near(HandleBarGeometry.pillLength(overlap: 40), 24))
        #expect(near(HandleBarGeometry.pillLength(overlap: 41), 25))
    }

    @Test func pillIsNeverLongerThanTheOverlapItSitsIn() throws {
        // 20 is the smallest overlap the app allows, and the 24 pt floor would put a
        // pill with its ends cut off in a panel that is exactly the overlap.
        #expect(near(HandleBarGeometry.pillLength(overlap: 20), 20))
        #expect(near(HandleBarGeometry.pillLength(overlap: 24), 24))
        #expect(near(HandleBarGeometry.pillLength(overlap: 30), 24))
        for overlap in stride(from: 4.0, through: 200.0, by: 1.0) {
            #expect(HandleBarGeometry.pillLength(overlap: overlap) <= overlap)
        }
    }

    @Test func pillIsThinAcrossTheDividerAndLongAlongIt() throws {
        let horizontal = HandleBarGeometry.pillSize(orientation: .horizontal, overlap: 800)
        #expect(horizontal.height > horizontal.width)
        let vertical = HandleBarGeometry.pillSize(orientation: .vertical, overlap: 800)
        #expect(vertical.width > vertical.height)
    }

    /// The drawn pill shrank to macOS's size; the region that catches the press did not, and must not.
    @Test func theHitBandIsNotTheDrawnPill() throws {
        #expect(near(HandleBarGeometry.bandThickness, 10))
        #expect(HandleBarGeometry.bandThickness > HandleBarGeometry.pillThickness)
        #expect(near(HandleBarGeometry.dragBandThickness, 96))
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        // The band is the gap widened to 10 even though only 4 pt of pill is drawn in it.
        #expect(near(HandleBarGeometry.band(for: p).width, 10))
    }

    @Test func bandIsTheGapWidenedToTenPointsOverTheOverlap() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        #expect(near(HandleBarGeometry.band(for: p), CGRect(x: 499, y: 0, width: 10, height: 800)))
    }

    @Test func aWideGapKeepsItsOwnThickness() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 512, y: 0, width: 500, height: 800))
        #expect(near(HandleBarGeometry.band(for: p), CGRect(x: 500, y: 0, width: 12, height: 800)))
    }

    /// Raising `handleMaxGap` to 16 admits wider pairs. The band then follows the gap — which is
    /// right, the whole gap is the handle's — but the *drawn* pill must not grow with it, and neither
    /// must the floor. Three widths, three numbers.
    @Test func aWiderPairGapWidensTheBandAndNothingElse() throws {
        let narrow = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        let wide = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 516, y: 0, width: 500, height: 800))
        #expect(near(HandleBarGeometry.band(for: narrow).width, 10))   // 8 pt gap, floored at the band
        #expect(near(HandleBarGeometry.band(for: wide).width, 16))     // 16 pt gap, its own width
        // The pill is drawn from the overlap alone. Nothing about the gap reaches it — which is the
        // whole claim of this test.
        #expect(near(HandleBarGeometry.pillSize(orientation: .horizontal, overlap: narrow.overlapLength),
                     HandleBarGeometry.pillSize(orientation: .horizontal, overlap: wide.overlapLength)))
        #expect(near(HandleBarGeometry.pillSize(orientation: .horizontal, overlap: wide.overlapLength),
                     CGSize(width: 4, height: 48)))
        // …and the panel still is the band exactly, at either gap.
        #expect(near(HandleBarGeometry.panelRect(for: wide, divider: wide.divider), HandleBarGeometry.band(for: wide)))
    }

    @Test func bandRecentresOnTheDividerWithoutChangingItsLength() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 200, width: 500, height: 300))
        let moved = HandleBarGeometry.band(for: p, divider: 700)
        #expect(near(moved, CGRect(x: 695, y: 200, width: 10, height: 300)))
    }

    @Test func aStackedPairsBandMovesOnY() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 0, y: 408, width: 500, height: 400))
        #expect(near(HandleBarGeometry.band(for: p), CGRect(x: 0, y: 399, width: 500, height: 10)))
        #expect(near(HandleBarGeometry.band(for: p, divider: 600), CGRect(x: 0, y: 595, width: 500, height: 10)))
    }

    /// The panel takes mouse events, so any point it covers that the press test declines is a dead
    /// point over a window that can no longer be clicked there. One rect, or that gap exists.
    @Test func theRestingPanelIsExactlyTheBandItIsPressedIn() throws {
        let horizontal = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        #expect(near(HandleBarGeometry.panelRect(for: horizontal, divider: horizontal.divider),
                     HandleBarGeometry.band(for: horizontal)))
        #expect(near(HandleBarGeometry.panelRect(for: horizontal, divider: 700),
                     HandleBarGeometry.band(for: horizontal, divider: 700)))
        let vertical = try pair(CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 0, y: 408, width: 500, height: 400))
        #expect(near(HandleBarGeometry.panelRect(for: vertical, divider: vertical.divider),
                     HandleBarGeometry.band(for: vertical)))
    }

    @Test func theDraggedPanelIsWideAcrossTheDividerAndUnchangedAlongIt() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        let resting = HandleBarGeometry.panelRect(for: p, divider: 700)
        let dragging = HandleBarGeometry.panelRect(for: p, divider: 700, dragging: true)
        #expect(near(resting, CGRect(x: 695, y: 0, width: 10, height: 800)))
        #expect(near(dragging, CGRect(x: 700 - 48, y: 0, width: 96, height: 800)))
        // The pointer moves along the divider's own axis, so that axis must not change with it.
        #expect(near(dragging.minY, resting.minY))
        #expect(near(dragging.height, resting.height))
    }

    @Test func aDraggedStackedPanelIsTallInsteadOfWide() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 0, y: 408, width: 500, height: 400))
        let dragging = HandleBarGeometry.panelRect(for: p, divider: 600, dragging: true)
        #expect(near(dragging, CGRect(x: 0, y: 600 - 48, width: 500, height: 96)))
    }

    @Test func aPairSplitAcrossTwoDisplaysIsNotOffered() throws {
        let left = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                               visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
        let right = DisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 775))
        let displays = [left, right]
        let sameScreen = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 400, height: 800))
        #expect(HandleBarGeometry.isWithinOneDisplay(sameScreen, displays: displays))
        let acrossTheSeam = try pair(CGRect(x: 500, y: 0, width: 500, height: 800),
                                 CGRect(x: 1000, y: 0, width: 500, height: 800))
        #expect(!HandleBarGeometry.isWithinOneDisplay(acrossTheSeam, displays: displays))
    }

    @Test func aPairOnNoKnownDisplayIsNotOffered() throws {
        let only = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                               visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
        let offScreen = try pair(CGRect(x: 4000, y: 0, width: 500, height: 800),
                             CGRect(x: 4508, y: 0, width: 500, height: 800))
        #expect(!HandleBarGeometry.isWithinOneDisplay(offScreen, displays: [only]))
        #expect(!HandleBarGeometry.isWithinOneDisplay(offScreen, displays: []))
    }
}
