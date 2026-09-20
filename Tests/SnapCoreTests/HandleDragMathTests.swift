import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct HandleDragMathTests {
    /// `try #require`, not a subscript: a pair the detector declined would otherwise trap and take
    /// the whole target down with no issue line and no summary for it.
    func pair(_ a: CGRect, _ b: CGRect) throws -> HandlePair {
        try #require(AdjacencyDetector.pairs(in: [WindowInfo(id: 1, pid: 1, frame: a, zIndex: 0),
                                                  WindowInfo(id: 2, pid: 2, frame: b, zIndex: 1)],
                                             maxGap: Settings().handleMaxGap, minOverlap: 60).first)
    }

    @Test func dividerFollowsCursorAndNormalizesGap() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 503, y: 0, width: 500, height: 800)) // gap 3
        let r = HandleDragMath.frames(for: p, divider: 600, gap: 8, minSizes: .init())
        #expect(r.divider == 600)
        #expect(r.a == CGRect(x: 0, y: 0, width: 596, height: 800))
        #expect(r.b == CGRect(x: 604, y: 0, width: 399, height: 800))
        #expect(r.b.minX - r.a.maxX == 8)
    }

    @Test func clampsAtLeftWindowMinimum() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        let r = HandleDragMath.frames(for: p, divider: 50, gap: 8, minSizes: .init(a: CGSize(width: 300, height: 100)))
        #expect(r.a.width == 300)
        #expect(r.divider == 304)
        #expect(r.b.minX == 308)
        #expect(r.b.maxX == 1008)
    }

    @Test func clampsAtRightWindowMinimum() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 508, y: 0, width: 500, height: 800))
        let r = HandleDragMath.frames(for: p, divider: 950, gap: 8, minSizes: .init(b: CGSize(width: 200, height: 100)))
        #expect(r.divider == 804)
        #expect(r.a.width == 800)
        #expect(r.b == CGRect(x: 808, y: 0, width: 200, height: 800))
    }

    @Test func verticalPairMovesHeights() throws {
        let p = try pair(CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 0, y: 406, width: 500, height: 400)) // gap 6
        let r = HandleDragMath.frames(for: p, divider: 500, gap: 8, minSizes: .init())
        #expect(r.a == CGRect(x: 0, y: 0, width: 500, height: 496))
        #expect(r.b == CGRect(x: 0, y: 504, width: 500, height: 302))
    }

    @Test func impossibleMinimumsLeaveFramesUntouched() throws {
        let a = CGRect(x: 0, y: 0, width: 500, height: 800), b = CGRect(x: 508, y: 0, width: 500, height: 800)
        let p = try pair(a, b)
        let r = HandleDragMath.frames(for: p, divider: 400, gap: 8, minSizes: .init(a: CGSize(width: 600, height: 1), b: CGSize(width: 600, height: 1)))
        #expect(r.a == a)
        #expect(r.b == b)
        #expect(r.divider == p.divider)
    }
}

@Suite struct HandleDragMathMinimumTests {
    func near(_ a: CGSize, _ b: CGSize, _ epsilon: Double = 1e-9) -> Bool {
        abs(a.width - b.width) <= epsilon && abs(a.height - b.height) <= epsilon
    }

    @Test func aWindowThatCameBackBiggerThanAskedHasProvedItsMinimum() throws {
        let learned = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                    landed: CGSize(width: 480, height: 300),
                                                    requested: CGSize(width: 200, height: 300))
        #expect(near(learned, CGSize(width: 480, height: 1)))
    }

    @Test func aWindowThatTookTheSizeItWasGivenTeachesNothing() throws {
        let learned = HandleDragMath.learnedMinimum(CGSize(width: 480, height: 1),
                                                    landed: CGSize(width: 200, height: 300),
                                                    requested: CGSize(width: 200, height: 300))
        #expect(near(learned, CGSize(width: 480, height: 1)))
    }

    @Test func roundingIsNotARefusal() throws {
        let learned = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                    landed: CGSize(width: 200.5, height: 300.5),
                                                    requested: CGSize(width: 200, height: 300))
        #expect(near(learned, CGSize(width: 1, height: 1)))
        let refused = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                    landed: CGSize(width: 213, height: 300),
                                                    requested: CGSize(width: 200, height: 300))
        #expect(near(refused, CGSize(width: 213, height: 1)))
    }

    /// Terminal snaps its window to whole character cells — measured at 8 pt wide by 18 pt
    /// tall, **rounding to the nearest cell** (ask 381 of a 372/390 pair and get 390, ask 380
    /// and get 372, so the switch is the exact midpoint and the worst overshoot is half a cell).
    @Test func aWindowThatSnapsToACharacterGridTeachesNoMinimum() throws {
        #expect(HandleDragMath.roundingAllowance >= 9, "half of Terminal's measured 18 pt row")
        let width = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                  landed: CGSize(width: 516, height: 390),
                                                  requested: CGSize(width: 514, height: 385))
        #expect(near(width, CGSize(width: 1, height: 1)))
        // The worst case the measured grid can produce: ask the midpoint, get the whole half cell.
        let worst = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                  landed: CGSize(width: 520, height: 390),
                                                  requested: CGSize(width: 516, height: 381))
        #expect(near(worst, CGSize(width: 1, height: 1)))
        // And a floor 35 pt above the request is still a floor: Chrome's real minimum height is 375
        // and it answers 375 whatever smaller number it is given.
        let floor = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                  landed: CGSize(width: 564, height: 375),
                                                  requested: CGSize(width: 564, height: 340))
        #expect(near(floor, CGSize(width: 1, height: 375)))
    }

    /// **The band itself, at both edges.** The rule is `landed > requested + tolerance`, so the
    /// allowance itself is still not a refusal and one hundredth of a point past it is.
    @Test func theAllowanceBandIsPinnedAtBothEdges() throws {
        let allowance = HandleDragMath.roundingAllowance
        func learn(_ over: Double) -> CGSize {
            HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                          landed: CGSize(width: 200 + over, height: 300),
                                          requested: CGSize(width: 200, height: 300))
        }
        #expect(near(learn(0), CGSize(width: 1, height: 1)))
        #expect(near(learn(0.6), CGSize(width: 1, height: 1)), "0.6 was a refusal before this task")
        #expect(near(learn(allowance - 0.01), CGSize(width: 1, height: 1)))
        #expect(near(learn(allowance), CGSize(width: 1, height: 1)), "the allowance is inclusive")
        #expect(near(learn(allowance + 0.01), CGSize(width: 200 + allowance + 0.01, height: 1)),
                "one hundredth of a point past the allowance is a refusal")
        #expect(near(learn(allowance + 100), CGSize(width: 200 + allowance + 100, height: 1)))
    }

    @Test func aMinimumOnlyEverGrowsWithinOneDrag() throws {
        let learned = HandleDragMath.learnedMinimum(CGSize(width: 480, height: 1),
                                                    landed: CGSize(width: 300, height: 1),
                                                    requested: CGSize(width: 200, height: 1))
        #expect(near(learned, CGSize(width: 480, height: 1)))
    }

    @Test func aLearnedMinimumIsWhatStopsTheDivider() throws {
        let a = CGRect(x: 0, y: 0, width: 500, height: 800), b = CGRect(x: 508, y: 0, width: 500, height: 800)
        let p = try #require(AdjacencyDetector.pairs(in: [WindowInfo(id: 1, pid: 1, frame: a, zIndex: 0),
                                                          WindowInfo(id: 2, pid: 2, frame: b, zIndex: 1)],
                                                     maxGap: Settings().handleMaxGap, minOverlap: 60).first)
        // Asked for 200 wide, came back 480: the next pass may not push the divider past 484.
        var mins = HandleDragMath.MinSizes()
        mins.b = HandleDragMath.learnedMinimum(mins.b, landed: CGSize(width: 480, height: 800),
                                               requested: CGSize(width: 200, height: 800))
        let clamped = HandleDragMath.frames(for: p, divider: 900, gap: 8, minSizes: mins)
        #expect(abs(clamped.divider - 524) <= 1e-9)
        #expect(abs(clamped.b.width - 480) <= 1e-9)
    }

    /// The pointer leaving and coming back inside the limit: the divider follows it again from exactly
    /// where it stopped, because every pass is a function of the pointer alone.
    @Test func theClampedDividerPicksThePointerBackUpWithNoJump() throws {
        let a = CGRect(x: 0, y: 0, width: 500, height: 800), b = CGRect(x: 508, y: 0, width: 500, height: 800)
        let p = try #require(AdjacencyDetector.pairs(in: [WindowInfo(id: 1, pid: 1, frame: a, zIndex: 0),
                                                          WindowInfo(id: 2, pid: 2, frame: b, zIndex: 1)],
                                                     maxGap: Settings().handleMaxGap, minOverlap: 60).first)
        let mins = HandleDragMath.MinSizes(a: CGSize(width: 300, height: 100))
        let stopped = HandleDragMath.frames(for: p, divider: 100, gap: 8, minSizes: mins)
        let further = HandleDragMath.frames(for: p, divider: -400, gap: 8, minSizes: mins)
        #expect(stopped == further)
        let back = HandleDragMath.frames(for: p, divider: 700, gap: 8, minSizes: mins)
        #expect(back.divider == 700)
        #expect(back.a.width == 696)
    }

    @Test func refitClearsAnOverlapLeftByARightWindowThatWouldNotShrink() throws {
        // `b` was asked to start at 508 but landed at 400 wide with its right edge pinned — so it
        // reaches back to 608, 100 pt inside `a`. `a` keeps its left edge and stops one gap short.
        let neighbour = CGRect(x: 0, y: 0, width: 500, height: 800)
        let landed = CGRect(x: 608, y: 0, width: 400, height: 800)
        let fitted = HandleDragMath.refit(neighbour, after: landed, orientation: .horizontal,
                                          neighbourIsB: false, gap: 8, minimum: CGSize(width: 100, height: 100))
        #expect(fitted == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(landed.minX - fitted.maxX == 8)
    }

    @Test func refitPushesTheLowerWindowClearOfAnUpperOneThatRefused() throws {
        let neighbour = CGRect(x: 0, y: 408, width: 900, height: 400)
        let landed = CGRect(x: 0, y: 0, width: 900, height: 500)
        let fitted = HandleDragMath.refit(neighbour, after: landed, orientation: .vertical,
                                          neighbourIsB: true, gap: 8, minimum: CGSize(width: 100, height: 100))
        #expect(fitted == CGRect(x: 0, y: 508, width: 900, height: 300))
        #expect(fitted.minY - landed.maxY == 8)
    }

    /// The overlap is cleared even when clearing it costs the neighbour its own far edge: an overlap is
    /// what the user sees, a far edge a few points past where it was is not.
    @Test func refitKeepsTheNearEdgeAndGivesUpTheFarOneAtTheMinimum() throws {
        let neighbour = CGRect(x: 0, y: 0, width: 500, height: 800)
        let landed = CGRect(x: 200, y: 0, width: 800, height: 800)
        let fitted = HandleDragMath.refit(neighbour, after: landed, orientation: .horizontal,
                                          neighbourIsB: false, gap: 8, minimum: CGSize(width: 300, height: 100))
        #expect(fitted == CGRect(x: 0, y: 0, width: 300, height: 800))
    }
}

