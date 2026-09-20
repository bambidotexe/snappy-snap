import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct AdjacencyDetectorTests {
    func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double, z: Int = 0) -> WindowInfo {
        WindowInfo(id: id, pid: Int32(id), frame: CGRect(x: x, y: y, width: w, height: h), zIndex: z)
    }

    /// 12 is pinned on purpose here and nowhere else: these tests walk the boundary of `maxGap`, so
    /// the number has to be theirs rather than whatever the shipped default happens to be. Every test
    /// that then indexes the result uses `only(_:)`, which aborts.
    func pairs(_ windows: [WindowInfo], maxGap: Double = 12, minOverlap: Double = 60) -> [HandlePair] {
        AdjacencyDetector.pairs(in: windows, maxGap: maxGap, minOverlap: minOverlap)
    }

    /// The one pair these windows should form. `try #require`, not `[0]`: a subscript into an empty
    /// result traps and takes the whole target down with no issue line and no summary for it, which
    /// reads as a pass if only the other target's summary is checked.
    func only(_ found: [HandlePair], _ comment: Comment? = nil) throws -> HandlePair {
        #expect(found.count == 1, comment ?? "expected exactly one pair")
        return try #require(found.first)
    }

    @Test func sideBySideWithGap8() throws {
        let a = win(1, 0, 0, 500, 800, z: 0)
        let b = win(2, 508, 0, 500, 800, z: 1)
        let p = try only(pairs([a, b]))
        #expect(p.a == a)
        #expect(p.b == b)
        #expect(p.orientation == .horizontal)
        #expect(p.gap == 8)
        #expect(p.overlapStart == 0)
        #expect(p.overlapEnd == 800)
        #expect(p.overlapLength == 800)
        #expect(p.divider == 504)
        #expect(p.gapRect == CGRect(x: 500, y: 0, width: 8, height: 800))
        #expect(p.hoverBand(minThickness: 10) == CGRect(x: 499, y: 0, width: 10, height: 800))
        #expect(p.hoverBand(minThickness: 4) == CGRect(x: 500, y: 0, width: 8, height: 800))
    }

    @Test func inputOrderDoesNotMatter() throws {
        let a = win(1, 0, 0, 500, 800), b = win(2, 508, 0, 500, 800)
        #expect(pairs([b, a]) == pairs([a, b]))
    }

    @Test func differentHeightsUseTheOverlapOnly() throws {
        let p = try only(pairs([win(1, 0, 0, 500, 800), win(2, 508, 200, 500, 300)]))
        #expect(p.overlapStart == 200)
        #expect(p.overlapEnd == 500)
        #expect(p.gapRect == CGRect(x: 500, y: 200, width: 8, height: 300))
    }

    @Test func gapBounds() throws {
        let a = win(1, 0, 0, 500, 800)
        #expect(pairs([a, win(2, 512, 0, 500, 800)]).count == 1)
        #expect(pairs([a, win(2, 513, 0, 500, 800)]).isEmpty)
        #expect(pairs([a, win(2, 499, 0, 500, 800)]).count == 1)
        #expect(pairs([a, win(2, 498, 0, 500, 800)]).isEmpty)
        #expect(try only(pairs([a, win(2, 500, 0, 500, 800)])).gap == 0)
        #expect(pairs([a, win(2, 506, 0, 500, 800)], maxGap: 4).isEmpty)
    }

    @Test func overlapBelowMinimumIsNoPair() throws {
        #expect(pairs([win(1, 0, 0, 500, 800), win(2, 508, 750, 500, 300)]).isEmpty)
        #expect(pairs([win(1, 0, 0, 500, 800), win(2, 508, 740, 500, 300)]).count == 1)
    }

    @Test func stackedWindowsFormAVerticalPair() throws {
        let p = try only(pairs([win(1, 0, 0, 500, 400), win(2, 0, 408, 500, 400)]))
        #expect(p.orientation == .vertical)
        #expect(p.gap == 8)
        #expect(p.divider == 404)
        #expect(p.gapRect == CGRect(x: 0, y: 400, width: 500, height: 8))
        #expect(p.hoverBand(minThickness: 10) == CGRect(x: 0, y: 399, width: 500, height: 10))
    }

    /// `pairs(in:…)` does not filter on occlusion at all — a window sitting over the gap, even
    /// dead centre, does not remove the pair. Whether it hides the *drawn* pill is
    /// `occluder(of:pillRect:in:)`'s question (`occlusionIsJudgedAtThePillNotAlongTheDivider`
    /// below), asked by the controller at the one rect that is actually shown.
    @Test func windowInFrontOverTheGapNoLongerHidesThePair() throws {
        let a = win(1, 0, 0, 500, 800, z: 1), b = win(2, 508, 0, 500, 800, z: 2)
        let front = win(3, 450, 100, 200, 200, z: 0)
        #expect(try only(pairs([front, a, b])).a.id == 1)
        let back = win(3, 450, 100, 200, 200, z: 3)
        #expect(pairs([a, b, back]).count == 1)
        let frontElsewhere = win(3, 900, 100, 200, 200, z: 0)
        #expect(pairs([frontElsewhere, a, b]).count == 1)
    }

    // MARK: - Frontmost-per-side pairs, and occlusion at the pill.

    @Test func stackedIdenticalFramesYieldOnePairWithTheFrontmost() throws {
        let left = win(1, 0, 33, 752, 949)
        let stack = [win(2, 760, 33, 752, 949, z: 0), win(3, 760, 33, 752, 949, z: 1), win(4, 760, 33, 752, 949, z: 2)]
        let pairs = AdjacencyDetector.pairs(in: [left] + stack, maxGap: 16, minOverlap: 60)
        #expect(pairs.count == 1)
        #expect(try #require(pairs.first).b.id == 2)
    }

    /// The gap between `top` and `bottom` is wide enough that they do not themselves form a
    /// third, entirely legitimate vertical pair — which would not be a dominance bug, just an
    /// unrelated pair the fixture must avoid to isolate the property under test: two side windows
    /// that do not intersect each other are different neighbours of `tall`, not competitors, and
    /// both stand.
    @Test func twoDisjointNeighboursOnOneSideStillMakeTwoPairs() {
        let tall = win(1, 760, 33, 752, 949)
        let top = win(2, 0, 33, 752, 300), bottom = win(3, 0, 400, 752, 582)
        #expect(AdjacencyDetector.pairs(in: [tall, top, bottom], maxGap: 16, minOverlap: 60).count == 2)
    }

    @Test func occlusionIsJudgedAtThePillNotAlongTheDivider() throws {
        let a = win(1, 0, 33, 752, 949, z: 1), b = win(2, 760, 33, 752, 949, z: 2)
        let front = win(3, 700, 33, 120, 100, z: 0)            // covers the top of the divider only
        let pairs = AdjacencyDetector.pairs(in: [a, b, front], maxGap: 16, minOverlap: 60)
        let pair = try #require(pairs.first { $0.a.id == 1 && $0.b.id == 2 })
        let topPill = CGRect(x: 754, y: 50, width: 4, height: 48)
        let lowPill = CGRect(x: 754, y: 800, width: 4, height: 48)
        #expect(AdjacencyDetector.occluder(of: pair, pillRect: topPill, in: [a, b, front])?.id == 3)
        #expect(AdjacencyDetector.occluder(of: pair, pillRect: lowPill, in: [a, b, front]) == nil)
    }

    @Test func aWindowInFrontOfOneMemberOccludesToo() throws {
        let a = win(1, 0, 33, 752, 949, z: 0), b = win(2, 760, 33, 752, 949, z: 2)
        let front = win(3, 700, 400, 120, 100, z: 1)           // behind a, in front of b, over the divider
        let pair = try #require(AdjacencyDetector.pairs(in: [a, b, front], maxGap: 16, minOverlap: 60)
            .first { $0.a.id == 1 && $0.b.id == 2 })
        let pill = CGRect(x: 754, y: 420, width: 4, height: 48)
        #expect(AdjacencyDetector.occluder(of: pair, pillRect: pill, in: [a, b, front])?.id == 3)
    }

    @Test func threeInARowGiveTwoPairsSortedByID() throws {
        let found = pairs([win(3, 616, 0, 300, 800), win(1, 0, 0, 300, 800), win(2, 308, 0, 300, 800)])
        #expect(found.map { [$0.a.id, $0.b.id] } == [[1, 2], [2, 3]])
    }

    @Test func farApartWindowsGiveNothing() throws {
        #expect(pairs([win(1, 0, 0, 500, 800), win(2, 600, 0, 500, 800)]).isEmpty)
    }
}
