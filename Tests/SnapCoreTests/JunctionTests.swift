import CoreGraphics
import Testing
@testable import SnapCore

/// The arrangements below are all built at the shipped gap out of a 1008 × 808 area, so
/// one set of numbers serves every rotation: the crossing is always at (504, 404).
@Suite struct JunctionDetectorTests {
    /// `#expect` boxes CGFloat against Double, so scalars are compared with an epsilon throughout.
    func near(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool { abs(a - b) <= epsilon }
    func near(_ a: CGPoint, _ b: CGPoint, _ epsilon: Double = 1e-9) -> Bool {
        near(a.x, b.x, epsilon) && near(a.y, b.y, epsilon)
    }

    func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double, z: Int = 0) -> WindowInfo {
        WindowInfo(id: id, pid: Int32(id), frame: CGRect(x: x, y: y, width: w, height: h), zIndex: z)
    }

    /// The pair rule's own default, read from `Settings` rather than pinned: a helper that hardcodes
    /// a default breaks silently when the default moves, and the failure mode is a trap.
    func junctions(_ windows: [WindowInfo]) -> [Junction] {
        JunctionDetector.junctions(in: windows, maxGap: Settings().handleMaxGap)
    }

    /// The junction at one point, of the several an arrangement usually has. Every divider has a knob
    /// at **each end** as well as at any crossing along it, so an arrangement that fills a rectangle
    /// has knobs all round its rim; a test that means the middle one has to say so.
    ///
    /// `try #require`, never a subscript: **`#expect` does not abort**, so `[0]` after a failed
    /// expectation still traps, and a trapped target prints no summary line at all.
    func at(_ found: [Junction], _ point: CGPoint) throws -> Junction {
        let match = found.filter { near($0.point, point, 0.5) }
        #expect(match.count == 1, "expected one junction at \(point), got \(match.count) of \(found.count)")
        return try #require(match.first)
    }

    /// Where an arrangement's knobs are, as a set, so a test can state the whole picture rather than
    /// one junction of it.
    func points(_ found: [Junction]) -> [CGPoint] { found.map(\.point) }

    /// Whether any knob sits at `point`. These arrangements have knobs at their divider ends as well
    /// as at the crossing, so "the crossing was suppressed" is a statement about one point and never
    /// about the count.
    func hasJunction(_ found: [Junction], at point: CGPoint) -> Bool {
        found.contains { near($0.point, point, 0.5) }
    }

    /// The knob in the middle of an arrangement — (504, 404) throughout this suite, as the note above
    /// says. The knobs at the divider ends are asserted where they are the subject of the test.
    func middle(_ windows: [WindowInfo]) throws -> Junction {
        try at(junctions(windows), CGPoint(x: 504, y: 404))
    }

    /// One member's pair of roles, aborting rather than force-unwrapping if it is not a member.
    func roles(_ junction: Junction, _ id: UInt32) throws -> (Junction.Role, Junction.Role) {
        let member = try #require(junction.member(id), "window \(id) is not a member of this junction")
        return (member.x, member.y)
    }

    // Four windows in quadrants of a 1008 × 808 area, gap 8.
    let tl = CGRect(x: 0, y: 0, width: 500, height: 400)
    let tr = CGRect(x: 508, y: 0, width: 500, height: 400)
    let bl = CGRect(x: 0, y: 408, width: 500, height: 400)
    let br = CGRect(x: 508, y: 408, width: 500, height: 400)

    func cross() -> [WindowInfo] {
        [win(1, tl.minX, tl.minY, tl.width, tl.height), win(2, tr.minX, tr.minY, tr.width, tr.height),
         win(3, bl.minX, bl.minY, bl.width, bl.height), win(4, br.minX, br.minY, br.width, br.height)]
    }

    /// The four quadrants make a knob in the middle, and the four divider ends make one each — every
    /// one of those is two windows' corners meeting, which is the whole rule.
    @Test func fourWindowsInQuadrantsHaveACrossAndAKnobAtEachDividerEnd() throws {
        let found = junctions(cross())
        #expect(found.count == 5)
        #expect(points(found).map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
            == [CGPoint(x: 0, y: 404), CGPoint(x: 504, y: 0), CGPoint(x: 504, y: 404),
                CGPoint(x: 504, y: 808), CGPoint(x: 1008, y: 404)])
        // The rim knobs are two windows each, with two empty quadrants apiece.
        #expect(try at(found, CGPoint(x: 504, y: 0)).windowIDs == [1, 2])
        #expect(try at(found, CGPoint(x: 0, y: 404)).windowIDs == [1, 3])
    }

    @Test func fourWindowsInQuadrantsAreOneCross() throws {
        let j = try middle(cross())
        #expect(near(j.point, CGPoint(x: 504, y: 404)))
        #expect(j.windowIDs == [1, 2, 3, 4])
        #expect(j.spanningMember == nil, "no member of a cross spans a divider")
        // `try #require`, never a force-unwrap: a nil member would trap and take the target down
        // with no summary line of its own, which reads as green against the other target's.
        #expect(try roles(j, 1) == (.low, .low))
        #expect(try roles(j, 2) == (.high, .low))
        #expect(try roles(j, 3) == (.low, .high))
        #expect(try roles(j, 4) == (.high, .high))
        // Both dividers move all four; that is what "cross" means.
        #expect(j.members(movedOn: .x).count == 4)
        #expect(j.members(movedOn: .y).count == 4)
    }

    /// The four corners that meet at a cross are one cluster, not four candidates: one knob comes out.
    @Test func theFourCornersThatMeetThereProposeOneJunctionNotFour() throws {
        let centre = junctions(cross()).filter { near($0.point, CGPoint(x: 504, y: 404), 0.5) }
        #expect(centre.count == 1)
        #expect(centre.first?.members.count == 4)
    }

    /// A T in each of its four rotations. In every one, three windows meet, exactly one of them runs
    /// past a divider, and the other divider moves only the two on its side.
    @Test func teeWithTheSpannerAbove() throws {
        let j = try middle([win(1, 0, 0, 1008, 400), win(2, bl.minX, bl.minY, bl.width, bl.height),
                            win(3, br.minX, br.minY, br.width, br.height)])
        #expect(j.spanningMember != nil)
        #expect(near(j.point, CGPoint(x: 504, y: 404)))
        #expect(j.spanningMember?.window.id == 1)
        #expect(j.member(1)?.x == .spanning)
        #expect(j.member(1)?.y == .low)
        // The through-divider is the horizontal one: y moves all three, x only the two below it.
        #expect(j.members(movedOn: .y).count == 3)
        #expect(Set(j.members(movedOn: .x).map { $0.window.id }) == [2, 3])
    }

    @Test func teeWithTheSpannerBelow() throws {
        let j = try middle([win(1, tl.minX, tl.minY, tl.width, tl.height),
                            win(2, tr.minX, tr.minY, tr.width, tr.height),
                            win(3, 0, 408, 1008, 400)])
        #expect(j.spanningMember != nil)
        #expect(near(j.point, CGPoint(x: 504, y: 404)))
        #expect(j.member(3)?.x == .spanning)
        #expect(j.member(3)?.y == .high)
        #expect(Set(j.members(movedOn: .x).map { $0.window.id }) == [1, 2])
    }

    @Test func teeWithTheSpannerOnTheLeft() throws {
        let j = try middle([win(1, 0, 0, 500, 808), win(2, tr.minX, tr.minY, tr.width, tr.height),
                            win(3, br.minX, br.minY, br.width, br.height)])
        #expect(j.spanningMember != nil)
        #expect(near(j.point, CGPoint(x: 504, y: 404)))
        #expect(j.member(1)?.x == .low)
        #expect(j.member(1)?.y == .spanning)
        // Now it is the vertical divider that runs through.
        #expect(j.members(movedOn: .x).count == 3)
        #expect(Set(j.members(movedOn: .y).map { $0.window.id }) == [2, 3])
    }

    @Test func teeWithTheSpannerOnTheRight() throws {
        let j = try middle([win(1, tl.minX, tl.minY, tl.width, tl.height),
                            win(2, bl.minX, bl.minY, bl.width, bl.height),
                            win(3, 508, 0, 500, 808)])
        #expect(j.spanningMember != nil)
        #expect(near(j.point, CGPoint(x: 504, y: 404)))
        #expect(j.member(3)?.x == .high)
        #expect(j.member(3)?.y == .spanning)
        #expect(j.members(movedOn: .x).count == 3)
        #expect(Set(j.members(movedOn: .y).map { $0.window.id }) == [1, 2])
    }

    /// An **L** — three windows with the fourth quadrant genuinely empty — is a junction, in each of
    /// its four rotations. The empty quadrant has nobody in it to resize and that is the whole of what
    /// it costs: the three windows that are there take their sides and both dividers move them.
    @Test func anLWithAnEmptyQuadrantIsAJunctionOfThree() throws {
        let corners: [[WindowInfo]] = [
            [win(1, tl.minX, tl.minY, tl.width, tl.height), win(2, tr.minX, tr.minY, tr.width, tr.height),
             win(3, bl.minX, bl.minY, bl.width, bl.height)],
            [win(1, tl.minX, tl.minY, tl.width, tl.height), win(2, tr.minX, tr.minY, tr.width, tr.height),
             win(4, br.minX, br.minY, br.width, br.height)],
            [win(1, tl.minX, tl.minY, tl.width, tl.height), win(3, bl.minX, bl.minY, bl.width, bl.height),
             win(4, br.minX, br.minY, br.width, br.height)],
            [win(2, tr.minX, tr.minY, tr.width, tr.height), win(3, bl.minX, bl.minY, bl.width, bl.height),
             win(4, br.minX, br.minY, br.width, br.height)],
        ]
        for windows in corners {
            let j = try middle(windows)
            #expect(j.members.count == 3)
            #expect(j.spanningMember == nil, "an L has no through-divider; nothing spans")
            #expect(j.members(movedOn: .x).count == 3)
            #expect(j.members(movedOn: .y).count == 3)
        }
    }

    /// Two windows touching at **one corner each**, diagonally, with the other two quadrants empty.
    /// They are not a `HandlePair` — they overlap on neither axis — so nothing about the pill rule
    /// could ever have found this, and it is the shape that proves candidates come from corners.
    @Test func aDiagonalPairIsAJunctionOfTwo() throws {
        let j = try middle([win(1, tl.minX, tl.minY, tl.width, tl.height),
                            win(2, br.minX, br.minY, br.width, br.height)])
        #expect(j.windowIDs == [1, 2])
        #expect(try roles(j, 1) == (.low, .low))
        #expect(try roles(j, 2) == (.high, .high))
        // Both axes move both windows: each one has an edge on each divider.
        #expect(j.members(movedOn: .x).count == 2)
        #expect(j.members(movedOn: .y).count == 2)
        // The other diagonal, so it is the rule and not one arrangement.
        let other = try middle([win(1, tr.minX, tr.minY, tr.width, tr.height),
                                win(2, bl.minX, bl.minY, bl.width, bl.height)])
        #expect(try roles(other, 1) == (.high, .low))
        #expect(try roles(other, 2) == (.low, .high))
    }

    /// Two windows side by side are a pair *and* a junction at **each end** of the divider between
    /// them — the ordinary left-half / right-half split carries two knobs, one at the top of the
    /// screen and one at the bottom. Dragging either resizes both windows' heights; the pill in the
    /// middle of the divider still owns everything between.
    @Test func twoWindowsSideBySideHaveAKnobAtEachEndOfTheirDivider() throws {
        let sideBySide = junctions([win(1, 0, 0, 500, 808), win(2, 508, 0, 500, 808)])
        #expect(points(sideBySide).map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
            == [CGPoint(x: 504, y: 0), CGPoint(x: 504, y: 808)])
        // The same two windows at both ends — which is why the dedup key is the point as well as the
        // members. Keyed on the ids alone, one of these two knobs would silently vanish.
        #expect(sideBySide.allSatisfy { $0.windowIDs == [1, 2] })
        let top = try at(sideBySide, CGPoint(x: 504, y: 0))
        #expect(try roles(top, 1) == (.low, .high))
        #expect(try roles(top, 2) == (.high, .high))
        let bottom = try at(sideBySide, CGPoint(x: 504, y: 808))
        #expect(try roles(bottom, 1) == (.low, .low))
        #expect(try roles(bottom, 2) == (.high, .low))

        let stacked = junctions([win(1, 0, 0, 1008, 400), win(2, 0, 408, 1008, 400)])
        #expect(points(stacked).map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
            == [CGPoint(x: 0, y: 404), CGPoint(x: 1008, y: 404)])
    }

    /// The free end of a divider between two windows that do **not** fill the screen: the knob is
    /// where their two near corners line up, and dragging it takes both edges into the empty space.
    @Test func theFreeEndOfADividerIsAJunction() throws {
        let topHalfOnly = junctions([win(1, 0, 0, 500, 400), win(2, 508, 0, 500, 400)])
        let bottomEnd = try at(topHalfOnly, CGPoint(x: 504, y: 400))
        #expect(bottomEnd.windowIDs == [1, 2])
        #expect(try roles(bottomEnd, 1) == (.low, .low))
        #expect(try roles(bottomEnd, 2) == (.high, .low))
        // One-sided on y — nothing faces them below — and two-sided on x.
        #expect(bottomEnd.isTwoSided(on: .x))
        #expect(bottomEnd.isTwoSided(on: .y) == false)
    }

    /// A window on its own is not a crossing, however many of its corners a cluster picks up.
    @Test func aLoneWindowHasNoJunction() throws {
        #expect(junctions([win(1, 0, 0, 500, 400)]).isEmpty)
        // Nor do two windows nowhere near each other.
        #expect(junctions([win(1, 0, 0, 200, 200), win(2, 700, 600, 200, 200)]).isEmpty)
    }

    /// **Corners that point the same way are not a junction.** Two windows sharing a bottom-right
    /// corner claim the same single quadrant; the frontmost wins it, the other wins nothing and is
    /// dropped, and one member is not a crossing. This is what keeps two stacked-up windows of the
    /// same size from sprouting knobs at all four of their corners.
    @Test func twoCornersPointingTheSameWayAreNotAJunction() throws {
        #expect(junctions([win(1, 0, 0, 500, 400, z: 0), win(2, 100, 100, 400, 300, z: 1)]).isEmpty)
    }

    /// Three columns over three columns: two crossings, each its own knob, neither claiming the
    /// other's windows.
    @Test func aThreeByTwoGridHasTwoJunctions() throws {
        let found = junctions([
            win(1, 0, 0, 300, 400), win(2, 308, 0, 300, 400), win(3, 616, 0, 300, 400),
            win(4, 0, 408, 300, 400), win(5, 308, 408, 300, 400), win(6, 616, 408, 300, 400),
        ])
        let left = try at(found, CGPoint(x: 304, y: 404))
        let right = try at(found, CGPoint(x: 612, y: 404))
        #expect(left.windowIDs == [1, 2, 4, 5])
        #expect(right.windowIDs == [2, 3, 5, 6])
        #expect(left.members.count == 4)
        #expect(right.members.count == 4)
    }

    /// The knob inherits the occlusion rule rather than repeating it: a window in front of the
    /// crossing kills every pair that meets there, and a junction is made of nothing else.
    @Test func aWindowInFrontOfTheCrossingSuppressesIt() throws {
        var windows = cross()
        for i in windows.indices { windows[i].zIndex = i + 1 }
        #expect(hasJunction(junctions(windows), at: CGPoint(x: 504, y: 404)))
        windows.append(win(9, 440, 340, 140, 140, z: 0))
        let covered = junctions(windows)
        #expect(hasJunction(covered, at: CGPoint(x: 504, y: 404)) == false)
        // The knobs at the four divider ends are nowhere near the covering window and stay.
        #expect(covered.count == 4)
    }

    /// A misaligned arrangement still gives one junction, and its point is the middle of the gap the
    /// four windows actually leave — not whichever divider proposed it first.
    @Test func theCentreComesFromTheWindowsNotFromOnePair() throws {
        let j = try at(junctions([win(1, 0, 0, 500, 400), win(2, 508, 0, 500, 400),
                                  win(3, 0, 408, 499, 400), win(4, 507, 408, 501, 400)]),
                       CGPoint(x: 503.5, y: 404))
        // xLow is the furthest low edge (500) and xHigh the nearest high edge (507).
        #expect(near(j.point, CGPoint(x: 503.5, y: 404)))
    }

    /// **A defect this caught live, and the reason there are two tolerances.** Terminal quantizes its
    /// own height to whole character cells, so in a cross of Chrome, Terminal, Finder and TextEdit its
    /// bottom edge sat 14 pt above the windows below it while Chrome's sat 8 pt above them. The
    /// junction is found (the 437 divider proposes it and every edge is within 8 pt of *that*), the
    /// centre is re-derived as 440 — and revalidating at 440 with the same 8 pt refused the press,
    /// because Terminal's edge is 10 pt from the centre. The centre's tolerance is `maxGap`, which is
    /// the bound that actually follows from how a candidate is proposed.
    @Test func twoUnevenGapsAboveACrossingStillPressAtTheCentre() throws {
        let uneven = [win(1, 0, 40, 556, 396), win(2, 564, 40, 532, 390),
                      win(3, 0, 444, 556, 396), win(4, 564, 444, 536, 396)]
        let j = try at(junctions(uneven), CGPoint(x: 560, y: 440))
        #expect(j.spanningMember == nil)
        #expect(near(j.point, CGPoint(x: 560, y: 440)))
        // 430 is 10 pt from the centre — more than `edgeTolerance`, less than `centreTolerance`.
        #expect(near(try #require(j.member(2)).window.frame.maxY, 430))
        let fresh = JunctionDetector.revalidate(j, frames: [:], maxGap: Settings().handleMaxGap)
        #expect(fresh?.windowIDs == j.windowIDs, "the press must not refuse a junction just detected")
    }

    /// The tolerance is the knob's own band, not half the pair rule's `maxGap`. Half the gap
    /// is the right bound for a *pair* but the wrong one for a *crossing* — it would leave a T
    /// whose stacked windows disagreed by 9 pt with no knob at all. Half the gap survives as a
    /// floor for a `maxGap` wider than twice the band.
    @Test func toleranceIsTheKnobsOwnBand() throws {
        #expect(near(JunctionDetector.edgeTolerance(maxGap: 16), JunctionGeometry.bandSize))
        #expect(near(JunctionDetector.edgeTolerance(maxGap: 24), JunctionGeometry.bandSize))
        // A zero max gap gets the band too: nothing about a tight gap makes a crossing harder to see.
        #expect(near(JunctionDetector.edgeTolerance(maxGap: 0), JunctionGeometry.bandSize))
        // Wider than twice the band and the pair rule sets the bound again.
        #expect(near(JunctionDetector.edgeTolerance(maxGap: 80), 40))
        // The centre's tolerance moves with it, or the press refuses what detection accepted.
        #expect(near(JunctionDetector.centreTolerance(maxGap: 16), 2 * JunctionDetector.edgeTolerance(maxGap: 16)))
    }

    @Test func aWindowCoveringTheCrossingIsNotAMember() throws {
        // Spanning both dividers is covering the junction, not meeting it.
        #expect(JunctionDetector.role(min: 0, max: 1000, at: 504, tolerance: 8) == .spanning)
        #expect(JunctionDetector.role(min: 496, max: 900, at: 504, tolerance: 8) == .high)
        #expect(JunctionDetector.role(min: 0, max: 512, at: 504, tolerance: 8) == .low)
        #expect(JunctionDetector.role(min: 600, max: 900, at: 504, tolerance: 8) == nil)
    }

    /// The press path: the pairs a junction came from are up to one poll old, so the frames are
    /// re-read and the junction has to still be there.
    @Test func revalidationKeepsAJunctionThatHasNotMoved() throws {
        let j = try middle(cross())
        let same = JunctionDetector.revalidate(j, frames: [:], maxGap: Settings().handleMaxGap)
        #expect(same?.windowIDs == j.windowIDs)
        #expect(near(try #require(same).point, j.point))
        // One window slid 200 pt away between the poll and the press: no junction, no resize.
        let moved = JunctionDetector.revalidate(j, frames: [4: CGRect(x: 708, y: 408, width: 500, height: 400)],
                                                maxGap: Settings().handleMaxGap)
        #expect(moved == nil)
        // A window that merely settled by a point is still there.
        let settled = JunctionDetector.revalidate(j, frames: [4: CGRect(x: 509, y: 409, width: 499, height: 399)],
                                                  maxGap: Settings().handleMaxGap)
        #expect(settled?.windowIDs == j.windowIDs)
    }

    // MARK: - Z-aware junctions.

    @Test func junctionSurvivesAWindowBehindTheRightHalf() throws {
        // 2×2 grid at gap 8 in a 1512×949 area from y = 33; crossing ≈ (756, 507).
        let grid = [win(1, 0, 33, 752, 470), win(2, 760, 33, 752, 470),
                    win(3, 0, 511, 752, 471), win(4, 760, 511, 752, 471)]
        let behind = win(9, 760, 33, 752, 949, z: 5)          // spans the right half, behind everything
        let alone = try at(junctions(grid), CGPoint(x: 756, y: 507))
        let stacked = try at(junctions(grid + [behind]), CGPoint(x: 756, y: 507))
        #expect(stacked.spanningMember == nil)
        #expect(stacked.windowIDs == alone.windowIDs)
        #expect(near(stacked.point, alone.point, 1e-6))
    }

    @Test func quadrantTwinBehindIsNotAMember() throws {
        let grid = [win(1, 0, 33, 752, 470), win(2, 760, 33, 752, 470),
                    win(3, 0, 511, 752, 471), win(4, 760, 511, 752, 471)]
        let twin = win(7, 760, 33, 752, 470, z: 3)             // identical to window 2, behind it
        let j = try at(junctions(grid + [twin]), CGPoint(x: 756, y: 507))
        #expect(j.windowIDs == [1, 2, 3, 4])
    }

    @Test func junctionSetIsIndependentOfClickOrder() throws {
        let base = [win(1, 0, 33, 752, 470, z: 0), win(2, 760, 33, 752, 470, z: 1),
                    win(3, 0, 511, 752, 471, z: 2), win(4, 760, 511, 752, 471, z: 3)]
        let permuted = [win(1, 0, 33, 752, 470, z: 3), win(2, 760, 33, 752, 470, z: 0),
                        win(3, 0, 511, 752, 471, z: 1), win(4, 760, 511, 752, 471, z: 2)]
        let a = try at(junctions(base), CGPoint(x: 756, y: 507))
        let b = try at(junctions(permuted), CGPoint(x: 756, y: 507))
        #expect(a.windowIDs == b.windowIDs)
        #expect(near(a.point, b.point, 1e-6))
    }

    @Test func aWindowInFrontCoveringTheBandCancelsTheCrossing() {
        let grid = [win(1, 0, 33, 752, 470, z: 1), win(2, 760, 33, 752, 470, z: 2),
                    win(3, 0, 511, 752, 471, z: 3), win(4, 760, 511, 752, 471, z: 4)]
        let crossing = CGPoint(x: 756, y: 507)
        let cover = win(8, 700, 450, 120, 120, z: 0)           // in front, over the crossing
        #expect(hasJunction(junctions(grid + [cover]), at: crossing) == false)
        let elsewhere = win(8, 100, 100, 120, 120, z: 0)       // in front, nowhere near the band
        #expect(hasJunction(junctions(grid + [elsewhere]), at: crossing))
    }

    @Test func rejectedVerdictNamesItsMembers() throws {
        // Two windows stacked exactly on top of one another: at every corner both point the same way,
        // so the frontmost takes the only cell claimed and one member is left.
        let twins = [win(1, 0, 33, 752, 470, z: 0), win(2, 0, 33, 752, 470, z: 1)]
        let verdicts = JunctionDetector.evaluate(in: twins, maxGap: Settings().handleMaxGap)
        let rejected = try #require(verdicts.first { if case .rejected = $0 { true } else { false } })
        guard case .rejected(_, let reason) = rejected else { Issue.record("expected a rejection"); return }
        #expect(reason.description.contains("need 2, 3 or 4"))
        #expect(reason.description.contains("1") || reason.description.contains("2"))
    }

    // MARK: - A covering window must be visible, not merely more front than someone.

    /// An exact duplicate of member 2's frame at `z: 3` — behind member 2
    /// (`z: 0`) but ahead of member 4 (`z: 5`) — is totally invisible (member 2 sits in front of it at
    /// the identical place). It must not be able to cancel the crossing on the strength of merely being
    /// in front of member 4, who it never touches.
    @Test func aHiddenDuplicateBehindAFrontMemberDoesNotCancelTheCrossing() throws {
        let grid = [win(1, 0, 33, 752, 470, z: 1), win(2, 760, 33, 752, 470, z: 0),
                    win(3, 0, 511, 752, 471, z: 2), win(4, 760, 511, 752, 471, z: 5)]
        let hiddenDuplicate = win(9, 760, 33, 752, 470, z: 3)
        let j = try at(junctions(grid + [hiddenDuplicate]), CGPoint(x: 756, y: 507))
        #expect(j.windowIDs == [1, 2, 3, 4])
    }

    /// A window in front of only *one* member (here, member 1 — the most-behind of the four) still
    /// cancels the crossing when it is visible over the actual gap between the windows: the corner
    /// member 1 would otherwise show through is covered by nobody else, so no member hides it there.
    @Test func aWindowInFrontOfOnlyOneMemberAndVisibleInTheGapStillCancels() {
        let grid = [win(1, 0, 33, 752, 470, z: 10), win(2, 760, 33, 752, 470, z: 1),
                    win(3, 0, 511, 752, 471, z: 2), win(4, 760, 511, 752, 471, z: 3)]
        let cover = win(8, 700, 450, 120, 120, z: 5)           // ahead of 1 only; sits over the gap
        #expect(hasJunction(junctions(grid + [cover]), at: CGPoint(x: 756, y: 507)) == false)
    }

    /// Size buys a window nothing: a window that covers the entire band (and the whole display besides)
    /// but sits behind every member never cancels — the same visibility rule restated with a
    /// maximised frame, so the check cannot have swapped "behind everyone" for "small enough to be
    /// hidden".
    @Test func aMaximisedWindowBehindEverythingDoesNotCancel() throws {
        let grid = [win(1, 0, 33, 752, 470, z: 0), win(2, 760, 33, 752, 470, z: 1),
                    win(3, 0, 511, 752, 471, z: 2), win(4, 760, 511, 752, 471, z: 3)]
        let maximised = win(9, 0, 0, 3000, 3000, z: 100)
        let j = try at(junctions(grid + [maximised]), CGPoint(x: 756, y: 507))
        #expect(j.windowIDs == [1, 2, 3, 4])
    }
}

@Suite struct JunctionGeometryTests {
    func near(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool { abs(a - b) <= epsilon }
    func near(_ a: CGRect, _ b: CGRect, _ epsilon: Double = 1e-9) -> Bool {
        a.isApproximatelyEqual(to: b, tolerance: epsilon)
    }

    /// The knob is the pill's family: a multiple of the thickness measured off macOS, not a number of
    /// its own.
    @Test func theKnobIsAMultipleOfTheMeasuredPillThickness() throws {
        #expect(near(JunctionGeometry.knobDiameter, 3 * HandleBarGeometry.pillThickness))
        #expect(near(JunctionGeometry.knobDiameter, 12))
    }

    @Test func theBandIsGenerousAndCentredOnTheCrossing() throws {
        #expect(near(JunctionGeometry.bandSize, 24))
        #expect(JunctionGeometry.bandSize > JunctionGeometry.knobDiameter)
        #expect(near(JunctionGeometry.band(at: CGPoint(x: 504, y: 404)),
                     CGRect(x: 492, y: 392, width: 24, height: 24)))
        // Never narrower than the widest gap a handle is offered in.
        #expect(JunctionGeometry.bandSize >= Settings.Fixed.handleMaxGap)
    }

    /// The two bounds the T push lives between, and the reason it is not free to be any number.
    ///
    /// Far enough that the disc leaves the spanning window's face — that face is half a gap from the
    /// crossing and the disc reaches out half its diameter — and near enough that the whole disc is
    /// still inside the 24 pt band that catches the press, or part of the knob a person can see would
    /// not be a knob they can grab.
    @Test func theTeePushClearsTheFaceAndStaysInsideTheBand() throws {
        #expect(near(JunctionGeometry.teeOffset, 4.5))
        let nearEdge = JunctionGeometry.teeOffset - JunctionGeometry.knobDiameter / 2
        #expect(nearEdge > -Settings.Fixed.gap / 2, "the disc clears the spanning window's face")
        #expect(JunctionGeometry.teeOffset + JunctionGeometry.knobDiameter / 2
                <= JunctionGeometry.bandSize / 2, "the pushed disc is still wholly inside its band")
    }

    /// The pointer outruns the panel chasing it and every exit hands the
    /// cursor region back to the window underneath. A two-dimensional handle widens on **both** axes.
    @Test func draggingWidensThePanelOnBothAxes() throws {
        let rest = JunctionGeometry.panelRect(at: CGPoint(x: 504, y: 404))
        let dragging = JunctionGeometry.panelRect(at: CGPoint(x: 504, y: 404), dragging: true)
        #expect(near(rest, JunctionGeometry.band(at: CGPoint(x: 504, y: 404))))
        #expect(near(dragging, CGRect(x: 456, y: 356, width: 96, height: 96)))
        #expect(dragging.width > rest.width)
        #expect(dragging.height > rest.height)
        #expect(near(JunctionGeometry.dragBandSize, HandleBarGeometry.dragBandThickness))
    }

    // MARK: - knobCentre: centred on the crossing, pushed off it at a T

    func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowInfo {
        WindowInfo(id: id, pid: 1, frame: CGRect(x: x, y: y, width: w, height: h), zIndex: 0)
    }

    /// Spanning window on the left, gap 8, crossing (756, 507).
    func tee() throws -> Junction {
        let ws = [win(1, 0, 33, 752, 949), win(2, 760, 33, 752, 470), win(3, 760, 511, 752, 471)]
        let found = JunctionDetector.junctions(in: ws, maxGap: Settings().handleMaxGap)
        return try #require(found.first { $0.members.count == 3 })
    }

    @Test func crossKnobIsAtThePoint() throws {
        let ws = [win(1, 0, 33, 752, 470), win(2, 760, 33, 752, 470), win(3, 0, 511, 752, 471), win(4, 760, 511, 752, 471)]
        let found = JunctionDetector.junctions(in: ws, maxGap: Settings().handleMaxGap)
        let j = try #require(found.first { $0.members.count == 4 })
        #expect(JunctionGeometry.knobCentre(for: j) == j.point)
    }

    /// A left-spanning T is pushed a whole `teeOffset` to the right of the crossing — away from the
    /// spanning member, into the gap the two windows facing each other leave — and not at all on the
    /// axis the spanning member runs past.
    @Test func teeKnobIsPushedAwayFromTheSpanningMember() throws {
        let j = try tee()
        #expect(j.point == CGPoint(x: 756, y: 507))
        #expect(JunctionGeometry.knobCentre(for: j)
                == CGPoint(x: 756 + JunctionGeometry.teeOffset, y: 507))
    }

    /// The three mirrors of `tee()` — the spanning member on the right, above and below — built
    /// directly from `Junction.Member`s so the proposed point can be handed in deliberately a point
    /// off. `knobCentre` reads the members' facing edges on each axis, never the proposed point, and
    /// the spanning member's frame plays no part on the axis it spans.
    ///
    /// Each pushes on the axis the spanning member does **not** span, and away from the side it is on:
    /// the four together are what catches a sign or an axis swapped.
    @Test func teeKnobMirrorsForSpanningOnTheRight() {
        let j = Junction(point: CGPoint(x: 755, y: 506), members: [
            Junction.Member(window: win(1, 760, 33, 752, 949), x: .high, y: .spanning),
            Junction.Member(window: win(2, 0, 33, 752, 470), x: .low, y: .low),
            Junction.Member(window: win(3, 0, 511, 752, 471), x: .low, y: .high),
        ])
        #expect(JunctionGeometry.knobCentre(for: j)
                == CGPoint(x: 756 - JunctionGeometry.teeOffset, y: 507))
    }

    @Test func teeKnobMirrorsForSpanningAbove() {
        let j = Junction(point: CGPoint(x: 755, y: 506), members: [
            Junction.Member(window: win(1, 0, 33, 1512, 470), x: .spanning, y: .low),
            Junction.Member(window: win(2, 0, 511, 752, 471), x: .low, y: .high),
            Junction.Member(window: win(3, 760, 511, 752, 471), x: .high, y: .high),
        ])
        #expect(JunctionGeometry.knobCentre(for: j)
                == CGPoint(x: 756, y: 507 + JunctionGeometry.teeOffset))
    }

    @Test func teeKnobMirrorsForSpanningBelow() {
        let j = Junction(point: CGPoint(x: 755, y: 506), members: [
            Junction.Member(window: win(1, 0, 511, 1512, 471), x: .spanning, y: .high),
            Junction.Member(window: win(2, 0, 33, 752, 470), x: .low, y: .low),
            Junction.Member(window: win(3, 760, 33, 752, 470), x: .high, y: .low),
        ])
        #expect(JunctionGeometry.knobCentre(for: j)
                == CGPoint(x: 756, y: 507 - JunctionGeometry.teeOffset))
    }

    /// **Only a T is pushed.** An L of three leaves a quadrant empty and has no spanning member, so
    /// its knob is on the crossing exactly as a cross's is — the empty quadrant opens space too, and
    /// the rule deliberately says nothing about it.
    @Test func anLIsNotPushed() throws {
        let ws = [win(1, 0, 33, 752, 470), win(2, 760, 33, 752, 470), win(3, 0, 511, 752, 471)]
        let found = JunctionDetector.junctions(in: ws, maxGap: Settings().handleMaxGap)
        let j = try #require(found.first { $0.members.count == 3 })
        #expect(j.spanningMember == nil)
        #expect(JunctionGeometry.knobCentre(for: j) == j.point)
    }

    /// The push is a property of the junction's shape, not of the moment: the same offset at rest and
    /// against the frames a drag is drawing, so nothing jumps when the button goes down.
    @Test func theTeePushIsTheSameAtRestAndUnderADrag() throws {
        let j = try tee()
        let moved = j.members.reduce(into: [UInt32: CGRect]()) { frames, member in
            frames[member.window.id] = member.window.frame.offsetBy(dx: -60, dy: 25)
        }
        let rest = JunctionGeometry.knobCentre(for: j)
        let dragged = JunctionGeometry.knobCentre(for: j, frames: moved)
        #expect(rest == CGPoint(x: 756 + JunctionGeometry.teeOffset, y: 507))
        #expect(dragged == CGPoint(x: rest.x - 60, y: rest.y + 25))
    }

    /// On a junction the detector found, the knob sits `teeOffset` from the point along one axis — the
    /// detector derives its point from the same facing edges — and that offset is invariant under
    /// translation. This is what would catch a push that scaled with where on screen the crossing is.
    @Test func knobOffsetIsInvariantUnderTranslation() throws {
        let j = try tee()
        func offset(_ junction: Junction) -> CGSize {
            let c = JunctionGeometry.knobCentre(for: junction)
            return CGSize(width: c.x - junction.point.x, height: c.y - junction.point.y)
        }
        let before = offset(j)
        #expect(before == CGSize(width: JunctionGeometry.teeOffset, height: 0))
        let dx = 37.0, dy = -19.0
        let moved = Junction(point: CGPoint(x: j.point.x + dx, y: j.point.y + dy), members: j.members.map { member in
            var window = member.window
            window.frame = window.frame.offsetBy(dx: dx, dy: dy)
            return Junction.Member(window: window, x: member.x, y: member.y)
        })
        let after = offset(moved)
        #expect(after == before)
    }
}

@Suite struct JunctionDragMathTests {
    func near(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool { abs(a - b) <= epsilon }
    func near(_ a: CGRect, _ b: CGRect, _ epsilon: Double = 1e-9) -> Bool {
        a.isApproximatelyEqual(to: b, tolerance: epsilon)
    }

    func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowInfo {
        WindowInfo(id: id, pid: Int32(id), frame: CGRect(x: x, y: y, width: w, height: h), zIndex: 0)
    }

    /// The working area these arrangements fill. A cross and a T are two-sided on both axes, so the
    /// bound it carries never binds for them; it binds only on a one-sided axis, which the tests that
    /// mean it build explicitly.
    let screen = CGRect(x: 0, y: 0, width: 1008, height: 808)

    /// The 2×2 cross, built directly so the drag maths can be tested without the detector.
    func cross(gap: Double = 8) -> Junction {
        let half = gap / 2
        return Junction(point: CGPoint(x: 504, y: 404), members: [
            .init(window: win(1, 0, 0, 504 - half, 404 - half), x: .low, y: .low),
            .init(window: win(2, 504 + half, 0, 504 - half, 404 - half), x: .high, y: .low),
            .init(window: win(3, 0, 404 + half, 504 - half, 404 - half), x: .low, y: .high),
            .init(window: win(4, 504 + half, 404 + half, 504 - half, 404 - half), x: .high, y: .high),
        ])
    }

    /// The T with the spanner above: one window across the top, two below it.
    func tee() -> Junction {
        Junction(point: CGPoint(x: 504, y: 404), members: [
            .init(window: win(1, 0, 0, 1008, 400), x: .spanning, y: .low),
            .init(window: win(2, 0, 408, 500, 400), x: .low, y: .high),
            .init(window: win(3, 508, 408, 500, 400), x: .high, y: .high),
        ])
    }

    func frame(_ r: JunctionDragMath.Result, _ id: UInt32) throws -> CGRect { try #require(r.frame(id)) }

    @Test func bothDividersMoveAndEveryFarEdgeStaysPut() throws {
        let j = cross()
        let r = JunctionDragMath.frames(for: j, to: CGPoint(x: 700, y: 300), gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(near(r.point.x, 700))
        #expect(near(r.point.y, 300))
        #expect(near(try frame(r, 1), CGRect(x: 0, y: 0, width: 696, height: 296)))
        #expect(near(try frame(r, 2), CGRect(x: 704, y: 0, width: 304, height: 296)))
        #expect(near(try frame(r, 3), CGRect(x: 0, y: 304, width: 696, height: 504)))
        #expect(near(try frame(r, 4), CGRect(x: 704, y: 304, width: 304, height: 504)))
        // The outer edges of the whole arrangement are untouched, which is the invariant this
        // rule keeps.
        #expect(near(try frame(r, 1).minX, 0))
        #expect(near(try frame(r, 2).maxX, 1008))
        #expect(near(try frame(r, 3).maxY, 808))
        #expect(near(try frame(r, 4).maxY, 808))
        // …and the gap between them is the setting, on both axes.
        #expect(near(try frame(r, 2).minX - frame(r, 1).maxX, 8))
        #expect(near(try frame(r, 3).minY - frame(r, 1).maxY, 8))
    }

    /// **4 size writes and 3 position writes,
    /// not 8.** The one window whose corner is the junction's top-left keeps its origin.
    @Test func aCrossIsFourSizeWritesAndThreePositionWrites() throws {
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 700, y: 300), gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(r.changes.count == 4)
        #expect(r.changes.filter { $0.changesSize }.count == 4)
        #expect(r.changes.filter { $0.movesOrigin }.count == 3)
        #expect(r.writes == 7)
        #expect(try #require(r.changes.first { $0.id == 1 }).movesOrigin == false)
        for id: UInt32 in [2, 3, 4] {
            #expect(try #require(r.changes.first { $0.id == id }).movesOrigin)
        }
    }

    /// A T costs less again: the window the divider runs through keeps its origin *and* one dimension.
    @Test func aTeeIsThreeSizeWritesAndTwoPositionWrites() throws {
        let r = JunctionDragMath.frames(for: tee(), to: CGPoint(x: 700, y: 300), gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(r.changes.count == 3)
        #expect(r.writes == 5)
        let spanner = try #require(r.changes.first { $0.id == 1 })
        #expect(spanner.movesOrigin == false)
        #expect(near(try frame(r, 1), CGRect(x: 0, y: 0, width: 1008, height: 296)))
        // x does not touch the window it runs through, but it does move the two below.
        #expect(near(try frame(r, 2), CGRect(x: 0, y: 304, width: 696, height: 504)))
        #expect(near(try frame(r, 3), CGRect(x: 704, y: 304, width: 304, height: 504)))
    }

    /// The window that has to give way is written first, so nothing ever grows through a window that
    /// has not yet shrunk.
    @Test func shrinkingWindowsAreWrittenFirst() throws {
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 300, y: 300), gap: 8, visibleFrame: screen, minSizes: [:])
        let shrinking = r.changes.prefix { $0.shrinks }
        #expect(shrinking.count == r.changes.filter { $0.shrinks }.count)
        #expect(shrinking.count > 0)
    }

    /// Either axis may clamp independently on a minimum size — a drag that is blocked
    /// horizontally must still move vertically.
    @Test func anAxisThatCannotMoveDoesNotStopTheOther() throws {
        let j = cross()
        // No x can satisfy both: 900 + 900 + a gap will not fit in 1008.
        let minimums: [UInt32: CGSize] = [1: CGSize(width: 900, height: 1), 2: CGSize(width: 900, height: 1)]
        let r = JunctionDragMath.frames(for: j, to: CGPoint(x: 200, y: 300), gap: 8, visibleFrame: screen, minSizes: minimums)
        #expect(near(r.point.x, 504), "x had nowhere to go and must stay where it was")
        #expect(near(r.point.y, 300), "y was never blocked")
        #expect(near(try frame(r, 1), CGRect(x: 0, y: 0, width: 500, height: 296)))
        #expect(near(try frame(r, 4), CGRect(x: 508, y: 304, width: 500, height: 504)))
        // Nothing was written across the blocked axis, so no window's width changed.
        #expect(r.changes.allSatisfy { $0.frame.width == j.member($0.id)?.window.frame.width })
    }

    /// The clamp on an axis is the tightest of every member's minimum on that axis.
    @Test func theTightestMinimumOnTheAxisWins() throws {
        let j = cross()
        let r = JunctionDragMath.frames(for: j, to: CGPoint(x: 100, y: 404),
                                        gap: 8, visibleFrame: screen,
                                        minSizes: [1: CGSize(width: 300, height: 1),
                                                   3: CGSize(width: 420, height: 1)])
        // 0 + 420 + 4 is tighter than 0 + 300 + 4.
        #expect(near(r.point.x, 424))
        #expect(near(try frame(r, 3).width, 420))
        #expect(near(try frame(r, 1).width, 420))
    }

    /// A minimum *height* clamps y and leaves x alone — per window and per axis.
    @Test func aMinimumOnOneAxisDoesNotClampTheOther() throws {
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 200, y: 100),
                                        gap: 8, visibleFrame: screen, minSizes: [1: CGSize(width: 1, height: 250)])
        #expect(near(r.point.x, 200))
        #expect(near(r.point.y, 254))
    }

    /// Gap normalization, on both axes at once: a crossing left at 4 pt becomes the setting.
    @Test func theGapIsNormalizedOnBothAxes() throws {
        let j = cross(gap: 4)
        let r = JunctionDragMath.frames(for: j, to: CGPoint(x: 504, y: 404), gap: 8,
                                        visibleFrame: screen, minSizes: [:])
        #expect(near(try frame(r, 2).minX - frame(r, 1).maxX, 8))
        #expect(near(try frame(r, 3).minY - frame(r, 1).maxY, 8))
        #expect(near(try frame(r, 1).minX, 0))
        #expect(near(try frame(r, 4).maxX, 1008), "the far edge does not move when the gap is normalized")
    }

    /// A pass that asks for the frames the windows already have writes nothing at all — the state the
    /// user pushing against two exhausted minimums produces, every frame, for as long as they push.
    @Test func aJunctionThatHasNotMovedProducesNoWrites() throws {
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 504, y: 404), gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(r.changes.isEmpty)
        #expect(r.writes == 0)
        #expect(r.frames.count == 4)
    }

    /// The minimum is learned by exactly the same rule as elsewhere — the same function, not a
    /// copy.
    @Test func theLearnedMinimumRuleIsTheOneTheHandleBarUses() throws {
        let grown = HandleDragMath.learnedMinimum(CGSize(width: 1, height: 1),
                                                  landed: CGSize(width: 420, height: 300),
                                                  requested: CGSize(width: 200, height: 300))
        #expect(grown == CGSize(width: 420, height: 1))
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 100, y: 404), gap: 8,
                                        visibleFrame: screen, minSizes: [1: grown])
        #expect(near(r.point.x, 424))
    }

    // MARK: - refit

    /// Every member at the frame the crossing asked for, which is what the re-fit starts from when no
    /// application moved itself.
    func asked(_ junction: Junction) -> [UInt32: CGRect] {
        Dictionary(uniqueKeysWithValues: junction.members.map { ($0.window.id, $0.window.frame) })
    }

    /// The top-left window of a cross would not shrink: it kept 100 pt more width than it was asked
    /// for, so its right edge is 100 pt inside the crossing. The two windows on the **other** side of
    /// that divider are pushed clear of the edge it actually took; the one on its own side is not
    /// touched, and nothing moves on the axis nobody refused.
    @Test func aRefusalPushesTheMembersOnTheOtherSideOfThatDivider() throws {
        let j = cross()
        let refusal = JunctionDragMath.Refusal(id: 1, axis: .x, role: .low, edge: 600, overshoot: 100)
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: [refusal], gap: 8, minSizes: [:])
        #expect(Set(fitted.keys) == [2, 4], "only the high-x members share that divider")
        // Near edge one full gap clear of the edge window 1 took; far edge exactly where it was.
        #expect(near(try #require(fitted[2]), CGRect(x: 608, y: 0, width: 400, height: 400)))
        #expect(near(try #require(fitted[4]), CGRect(x: 608, y: 408, width: 400, height: 400)))
    }

    /// A `.high` member refuses too, and the direction is the opposite: anchoring places it at
    /// the size it will take against its own outer edge, so the extra extent comes back across the
    /// divider and the `.low` members have to give way.
    @Test func aHighMemberRefusingPullsTheLowOnesBack() throws {
        let j = cross()
        let refusal = JunctionDragMath.Refusal(id: 2, axis: .x, role: .high, edge: 408, overshoot: 100)
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: [refusal], gap: 8, minSizes: [:])
        #expect(Set(fitted.keys) == [1, 3])
        #expect(near(try #require(fitted[1]), CGRect(x: 0, y: 0, width: 400, height: 400)))
        #expect(near(try #require(fitted[3]), CGRect(x: 0, y: 408, width: 400, height: 400)))
    }

    /// Each axis is decided on its own, from its own worst refusal — a cross whose top-left refused
    /// horizontally and whose bottom-right refused vertically moves both dividers.
    @Test func eachAxisIsRefittedFromItsOwnRefusal() throws {
        let j = cross()
        let refusals = [
            JunctionDragMath.Refusal(id: 1, axis: .x, role: .low, edge: 600, overshoot: 100),
            JunctionDragMath.Refusal(id: 4, axis: .y, role: .high, edge: 308, overshoot: 100),
        ]
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: refusals, gap: 8, minSizes: [:])
        // 1 is on the refusing side of x, but on the other side of y, so it gives way vertically only.
        #expect(near(try #require(fitted[1]), CGRect(x: 0, y: 0, width: 500, height: 300)))
        // 2 gives way on both.
        #expect(near(try #require(fitted[2]), CGRect(x: 608, y: 0, width: 400, height: 300)))
        #expect(near(try #require(fitted[4]), CGRect(x: 608, y: 408, width: 400, height: 400)))
    }

    /// Two windows refusing the same divider cannot both be cleared. The deeper refusal is the one the
    /// re-fit is made against.
    @Test func theDeeperOfTwoRefusalsOnOneAxisWins() throws {
        let j = cross()
        let refusals = [
            JunctionDragMath.Refusal(id: 1, axis: .x, role: .low, edge: 560, overshoot: 60),
            JunctionDragMath.Refusal(id: 3, axis: .x, role: .low, edge: 600, overshoot: 100),
        ]
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: refusals, gap: 8, minSizes: [:])
        #expect(near(try #require(fitted[2]).minX, 608))
    }

    /// The minimum clamps the **size** only, never the near edge: a member squeezed past its floor
    /// keeps the position that clears the overlap and overruns its own far edge, because an overlap is
    /// what the user sees and a far edge a few points past where it was is not.
    @Test func aMinimumClampsTheSizeAndNotTheNearEdge() throws {
        let j = cross()
        let refusal = JunctionDragMath.Refusal(id: 1, axis: .x, role: .low, edge: 900, overshoot: 400)
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: [refusal], gap: 8,
                                            minSizes: [2: CGSize(width: 300, height: 1)])
        let two = try #require(fitted[2])
        #expect(near(two.minX, 908), "the near edge still clears the edge window 1 took")
        #expect(near(two.width, 300), "…and the width stops at the floor rather than going to 100")
    }

    /// A spanning member is not resized on the axis it spans, so it can neither refuse one nor be
    /// moved by one. The T's through-window stays exactly where it is.
    @Test func aSpanningMemberIsNeverRefittedOnTheAxisItSpans() throws {
        let j = tee()
        let refusal = JunctionDragMath.Refusal(id: 2, axis: .x, role: .low, edge: 600, overshoot: 100)
        let fitted = JunctionDragMath.refit(j, current: asked(j), refusals: [refusal], gap: 8, minSizes: [:])
        #expect(Set(fitted.keys) == [3])
        #expect(near(try #require(fitted[3]), CGRect(x: 608, y: 408, width: 400, height: 400)))
    }

    /// Nothing to correct is the ordinary case, and it must produce no second animation at all.
    @Test func noRefusalMeansNoReFit() {
        let j = cross()
        #expect(JunctionDragMath.refit(j, current: asked(j), refusals: [], gap: 8, minSizes: [:]).isEmpty)
    }

    // MARK: - One-sided axes

    /// Two windows stacked one above the other, and the knob at the **right-hand end** of the divider
    /// between them. Both windows end at the vertical axis, so x is one-sided: the crossing is their
    /// shared right edge and there is no facing window across it.
    func stackedRightEnd(gap: Double = 8) -> Junction {
        let half = gap / 2
        // The windows stop a whole gap inside the 1008 pt working area, as a snapped window does.
        let right = 1008 - gap
        return Junction(point: CGPoint(x: right, y: 404), members: [
            .init(window: win(1, 0, 0, right, 404 - half), x: .low, y: .low),
            .init(window: win(2, 0, 404 + half, right, 404 - half), x: .low, y: .high),
        ])
    }

    @Test func anAxisIsTwoSidedOnlyWithMembersFacingAcrossIt() {
        let j = stackedRightEnd()
        #expect(j.isTwoSided(on: .y), "one member above the divider, one below")
        #expect(j.isTwoSided(on: .x) == false, "both members end at the vertical axis")
    }

    /// **The gap is spent per axis.** A two-sided axis leaves half a gap either side of the crossing;
    /// a one-sided axis leaves nothing, because there is no facing window for a gap to be between.
    @Test func theHalfGapIsSpentOnlyOnATwoSidedAxis() {
        let j = stackedRightEnd()
        #expect(near(j.halfGap(8, on: .y), 4))
        #expect(near(j.halfGap(8, on: .x), 0))
        // A cross spends it on both.
        #expect(near(cross().halfGap(8, on: .x), 4))
        #expect(near(cross().halfGap(8, on: .y), 4))
        // And with the gap switched off nobody spends anything.
        #expect(near(cross().halfGap(0, on: .x), 0))
    }

    /// **Press and release without moving, and nothing may move.** On a one-sided axis this is the
    /// whole reason the half-gap is zero there: reserving half a gap against a window that does not
    /// exist would pull every member 4 pt off the edge the knob is drawn at, on the bare press.
    @Test func aOneSidedJunctionThatHasNotMovedProducesNoWrites() throws {
        let j = stackedRightEnd()
        let r = JunctionDragMath.frames(for: j, to: j.point, gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(r.changes.isEmpty, "a bare press must write nothing at all")
        #expect(r.writes == 0)
        #expect(near(try frame(r, 1), CGRect(x: 0, y: 0, width: 1000, height: 400)))
        #expect(near(try frame(r, 2), CGRect(x: 0, y: 408, width: 1000, height: 400)))
    }

    /// Dragging the one-sided axis inwards resizes **both** members — they share that edge — and
    /// their far edges stay put, exactly as on a two-sided axis.
    @Test func aOneSidedAxisResizesEveryMemberOnIt() throws {
        let r = JunctionDragMath.frames(for: stackedRightEnd(), to: CGPoint(x: 800, y: 404),
                                        gap: 8, visibleFrame: screen, minSizes: [:])
        #expect(near(r.point.x, 800))
        #expect(near(try frame(r, 1), CGRect(x: 0, y: 0, width: 800, height: 400)))
        #expect(near(try frame(r, 2), CGRect(x: 0, y: 408, width: 800, height: 400)))
        #expect(near(try frame(r, 1).minX, 0), "the far edge never moves")
    }

    /// **A one-sided axis stops at the working area, inset by a whole gap** — the distance a snapped
    /// window keeps from the screen edge. Without it the members' shared edge grows outwards with
    /// nothing to stop it, which is a preview over the menu bar or behind the Dock.
    @Test func aOneSidedAxisStopsAWholeGapInsideTheWorkingArea() throws {
        // The Dock and the menu bar taken out of a 1008 × 808 display.
        let visible = CGRect(x: 0, y: 33, width: 1008, height: 700)
        let r = JunctionDragMath.frames(for: stackedRightEnd(), to: CGPoint(x: 5000, y: 404),
                                        gap: 8, visibleFrame: visible, minSizes: [:])
        #expect(near(r.point.x, 1000), "1008 − 8, and not a point further")
        #expect(near(try frame(r, 1).maxX, 1000))

        // The `.high` direction, on the other axis: two windows side by side, both beginning at the
        // horizontal axis, dragged up over the menu bar.
        let sideBySideTopEnd = Junction(point: CGPoint(x: 504, y: 33), members: [
            .init(window: win(1, 0, 33, 500, 700), x: .low, y: .high),
            .init(window: win(2, 508, 33, 500, 700), x: .high, y: .high),
        ])
        let up = JunctionDragMath.frames(for: sideBySideTopEnd, to: CGPoint(x: 504, y: -500),
                                         gap: 8, visibleFrame: visible, minSizes: [:])
        #expect(near(up.point.y, 41), "33 + 8")
        #expect(near(try frame(up, 1).minY, 41))
        #expect(near(try frame(up, 2).minY, 41))
    }

    /// With the gap switched off the windows stop flush against the working area instead.
    @Test func withNoGapAOneSidedAxisStopsFlushAgainstTheWorkingArea() throws {
        let visible = CGRect(x: 0, y: 33, width: 1008, height: 700)
        let r = JunctionDragMath.frames(for: stackedRightEnd(gap: 0), to: CGPoint(x: 5000, y: 404),
                                        gap: 0, visibleFrame: visible, minSizes: [:])
        #expect(near(r.point.x, 1008))
    }

    /// **The working-area bound is a one-sided rule.** A two-sided axis only moves the divider between
    /// two windows whose far edges are already fixed, so it can never leave the screen — and must not
    /// be clamped as though it could.
    @Test func aTwoSidedAxisIsNotBoundedByTheWorkingArea() throws {
        // A working area far narrower than the arrangement: a bound applied here would visibly move
        // the divider, and it must not.
        let tiny = CGRect(x: 400, y: 400, width: 100, height: 100)
        let r = JunctionDragMath.frames(for: cross(), to: CGPoint(x: 700, y: 300),
                                        gap: 8, visibleFrame: tiny, minSizes: [:])
        #expect(near(r.point.x, 700))
        #expect(near(r.point.y, 300))
    }

    /// The working-area bound and the minimum-size bound are the same bound, so the axis that cannot
    /// satisfy both stops dead and the other still moves.
    @Test func theWorkingAreaBoundComposesWithTheMinimumSizeBound() throws {
        let visible = CGRect(x: 0, y: 33, width: 1008, height: 700)
        // x can reach 1000 at most and needs 1200 to satisfy the minimum: nothing satisfies both.
        let r = JunctionDragMath.frames(for: stackedRightEnd(), to: CGPoint(x: 900, y: 300),
                                        gap: 8, visibleFrame: visible,
                                        minSizes: [1: CGSize(width: 1200, height: 1)])
        #expect(near(r.point.x, 1000), "x had nowhere to go and stays where it was")
        #expect(near(r.point.y, 300), "y was never blocked")
    }

    /// A one-sided axis is the members' shared edge, so the knob is drawn **on** that edge rather than
    /// at the midpoint of a gap that is not there — and it is the same coordinate the drag puts the
    /// edge at, which is what makes the disc follow the pointer instead of staying where it was
    /// pressed.
    @Test func theKnobOnAOneSidedAxisIsTheMembersSharedEdge() throws {
        let j = stackedRightEnd()
        #expect(JunctionGeometry.knobCentre(for: j) == CGPoint(x: 1000, y: 404))
        let r = JunctionDragMath.frames(for: j, to: CGPoint(x: 800, y: 500),
                                        gap: 8, visibleFrame: screen, minSizes: [:])
        let moved = JunctionGeometry.knobCentre(for: j, frames: r.frames)
        #expect(moved == CGPoint(x: 800, y: 500), "the disc is where the drag put the edges")
    }
}
