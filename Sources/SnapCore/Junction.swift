import CoreGraphics

/// Where the corners of two, three or four windows meet: two dividers, and what each window does at
/// each of them.
///
/// Every member sits on the low side of a divider, on its high side, or runs straight past it, and
/// that one idea covers every shape. Four members taking a side each is the full cross; one member
/// running past a divider makes the T that divider runs through; and a quadrant no window claims is
/// simply empty, which is what an L of three, a diagonal pair, or the free end of a divider between
/// two windows is. Nothing about any of them is special-cased — the drag, the minimums and the write
/// plan all read the roles.
///
/// An empty quadrant makes an axis **one-sided**: every member on the same side of it, nothing facing
/// them across it. That is the one structural difference from a full cross, and `isTwoSided(on:)` is
/// where it is asked.
public struct Junction: Hashable, Sendable {
    /// The two things a junction can be dragged on. `x` is the vertical divider, `y` the horizontal
    /// one, in CG space (origin top-left, y down).
    public enum Axis: Hashable, Sendable, CaseIterable { case x, y }

    /// Where one window sits relative to one divider.
    public enum Role: Hashable, Sendable {
        /// The window **ends** at the divider: its far edge is its own minimum on this axis and the
        /// divider is its maximum. Left of a vertical divider, above a horizontal one.
        case low
        /// The window **begins** at the divider: the divider is its minimum and its far edge its
        /// maximum. Right of a vertical divider, below a horizontal one.
        case high
        /// The window runs straight past the divider, so this axis does not resize it at all. The one
        /// thing that makes a T a T; at most one member of a junction may span.
        case spanning
    }

    public struct Member: Hashable, Sendable {
        public var window: WindowInfo
        /// Role at the vertical divider.
        public var x: Role
        /// Role at the horizontal divider.
        public var y: Role

        public init(window: WindowInfo, x: Role, y: Role) {
            self.window = window
            self.x = x
            self.y = y
        }

        public func role(on axis: Axis) -> Role { axis == .x ? x : y }
        /// Whether dragging the junction on `axis` changes this window.
        public func moves(on axis: Axis) -> Bool { role(on: axis) != .spanning }
    }

    /// The crossing point: `x` is the vertical divider, `y` the horizontal one. Derived from the
    /// members' own edges rather than from the candidate that proposed it, so two candidates that
    /// disagree by half a point give one answer.
    public var point: CGPoint
    /// Two, three or four windows, sorted by window id.
    public var members: [Member]

    public init(point: CGPoint, members: [Member]) {
        self.point = point
        self.members = members
    }

    /// The member a through-divider runs past — the one thing that makes a junction a T — and nil when
    /// both dividers stop at the crossing.
    ///
    /// Read off the roles, never off the member count: a spanning member keeps the one quadrant it
    /// wins when something in front of it takes the other, so a T can have four members, and a
    /// junction of two can have none.
    public var spanningMember: Member? { members.first { $0.x == .spanning || $0.y == .spanning } }

    /// The windows this axis resizes. The asymmetry is in what each axis resizes, not in what the
    /// user may do — the handle always travels in both.
    public func members(movedOn axis: Axis) -> [Member] { members.filter { $0.moves(on: axis) } }

    /// Whether this axis has members on **both** sides of it. The one question that decides whether
    /// there is a gap on this axis at all: a gap is the space two windows leave *between* them, and it
    /// takes one on each side to leave one.
    ///
    /// With empty quadrants allowed an axis can be one-sided. Two windows stacked one above the other
    /// make a junction at each end of the horizontal divider between them, and at either end both of
    /// them *end* at the vertical axis (or both *begin* at it): the x axis has two `.low` members and
    /// no `.high` one. The same is true of the y axis at either end of a left-half / right-half split.
    public func isTwoSided(on axis: Axis) -> Bool {
        let roles = members.map { $0.role(on: axis) }
        return roles.contains(.low) && roles.contains(.high)
    }

    /// How far the junction point sits from the members' own edges on `axis`, for a window gap of
    /// `gap`. The one place the answer is decided, so the knob, the drag and the re-fit cannot
    /// disagree about it.
    ///
    /// **Half a gap on a two-sided axis, and nothing at all on a one-sided one.** Two windows facing
    /// each other across a divider leave the gap between them and the crossing is the middle of it;
    /// where every member takes the same side there is no facing window, so there is no gap to leave
    /// and the point, the knob and the members' shared edge are one coordinate. Reserving half a gap
    /// there anyway would pull every member back off the point the knob is drawn at — pressing the
    /// knob and letting go would shrink all of them by 4 pt at the default gap.
    public func halfGap(_ gap: Double, on axis: Axis) -> Double {
        isTwoSided(on: axis) ? gap / 2 : 0
    }

    public var windowIDs: Set<UInt32> { Set(members.map { $0.window.id }) }

    public func member(_ id: UInt32) -> Member? { members.first { $0.window.id == id } }
}

/// Junctions out of the window snapshot the handle bar's poll already takes, so a junction costs no
/// new Accessibility traffic and no second window-list poll to find.
public enum JunctionDetector {
    /// Two distances at once: how far apart two window corners may lie and still be read as meeting,
    /// and how far a window's edge may be from a crossing and still count as sitting on it.
    ///
    /// **The tolerance comes from the knob, not from the gap.** Half the pair rule's own `maxGap`
    /// would be the right bound for a *pair* — two windows are a pair when their facing edges are at
    /// most `maxGap` apart, so the divider between them is at most `maxGap / 2` from either edge — and
    /// the wrong one for a *crossing*. Misalignment is the normal case there, not an edge case:
    /// windows placed by hand, and windows that landed off their nominal zone because anchoring or
    /// `roundedToPoints()` moved them. Measured: two stacked windows can disagree about their far edge
    /// by **9 pt**, which a budget only 8 pt wide throws away.
    ///
    /// So the tolerance is `JunctionGeometry.bandSize`, the 24 pt square the knob is drawn in and
    /// pressed in. That is the region in which the user can already grab this crossing, and a corner
    /// inside it is a corner the knob reaches — which is exactly the question "would a person read
    /// these windows as meeting here". On the default 16 pt `handleMaxGap` it allows **20 pt** of real
    /// misalignment over the gap.
    ///
    /// It is a floor, not a replacement: a `maxGap` wider than twice the band still sets the bound,
    /// because a pair that loose puts its own divider further out than the knob does.
    ///
    /// What keeps a window that is merely *near* a crossing out of it is the part that does the real
    /// work: at least two windows have to claim *different* quadrants, by at most one spanning member,
    /// with nothing in front lying across the band.
    public static func edgeTolerance(maxGap: Double) -> Double {
        max(max(maxGap, 2) / 2, JunctionGeometry.bandSize)
    }

    /// How far a member's edge may be from the junction's **centre**, which is a looser question than
    /// the one `edgeTolerance` answers and has to be.
    ///
    /// A junction is proposed at the mean of a cluster of corners, and every member's edge is within
    /// `edgeTolerance` of that. The centre is then re-derived from the members' own edges, and it need
    /// not be the point that proposed it: two windows above a crossing can leave gaps of different
    /// sizes below them, and the centre sits between the *furthest* low edge and the *nearest* high
    /// edge. Both the edge and the centre are within `edgeTolerance` of the proposing point, so twice
    /// it is the bound that follows.
    ///
    /// Measured rather than reasoned into existence: a live cross of Chrome, Terminal, Finder and
    /// TextEdit was detected correctly and then **refused at the press**, because Terminal quantizes
    /// its own height to whole character cells and its bottom edge sat 10 pt from a centre that
    /// `edgeTolerance` allowed 8.
    ///
    /// Stated as **twice `edgeTolerance`**, so the two move together. They have to, or a crossing
    /// accepted by `evaluate` is refused again by `revalidate` at the press and the silent rejection
    /// has merely moved one step later.
    public static func centreTolerance(maxGap: Double) -> Double { 2 * edgeTolerance(maxGap: maxGap) }

    /// One candidate crossing's outcome.
    public enum Verdict: Sendable {
        case accepted(Junction)
        case rejected(at: CGPoint, reason: Reason)
    }

    /// Why a candidate crossing was refused. `description` is what the controller logs verbatim —
    /// silence is a defect — so every case names the members involved.
    public enum Reason: Hashable, Sendable, CustomStringConvertible {
        /// Occupancy resolved to a member count outside 2…4. One member is the usual reading: two
        /// windows whose coinciding corners point the *same* way claim the same quadrant, and only the
        /// frontmost survives.
        case memberCount(Int, members: [MemberSummary])
        /// More than one member spans a divider — two windows each running past a whole divider with
        /// nobody at the crossing itself, which is not a shape the drag can resize.
        ///
        /// An empty quadrant is **not** a rejection. An L of three leaves one, a diagonal pair two,
        /// the free end of a divider two.
        case multipleSpanning(members: [MemberSummary])
        /// A window in front of at least one member intersects the knob band and cancels the crossing.
        case covered(by: UInt32, pid: Int32)

        /// One resolved (or attempted) member, named for a log line rather than read off a `Junction`
        /// — a rejection may have no valid one to hold.
        public struct MemberSummary: Hashable, Sendable, CustomStringConvertible {
            public var id: UInt32
            public var x: Junction.Role
            public var y: Junction.Role

            public init(id: UInt32, x: Junction.Role, y: Junction.Role) {
                self.id = id; self.x = x; self.y = y
            }

            public var description: String { "\(id) (\(x)/\(y))" }
        }

        public var description: String {
            switch self {
            case .memberCount(let count, let members):
                "\(count) member(s) at the crossing, need 2, 3 or 4: "
                    + members.map(\.description).joined(separator: ", ")
            case .multipleSpanning(let members):
                "more than one member spans a divider: "
                    + members.map(\.description).joined(separator: ", ")
            case .covered(let id, let pid):
                "covered by window \(id) (pid \(pid))"
            }
        }
    }

    /// What one round of occupancy resolution settled: the members that won at least one of the four
    /// cells around the crossing.
    private struct Resolution {
        var members: [Junction.Member]
    }

    /// One corner of one window, on its way to being clustered with the corners it meets.
    private struct Corner {
        let windowID: UInt32
        let point: CGPoint
    }

    /// Every candidate crossing in `windows`, judged against the full snapshot. A candidate is a point
    /// where the corners of **two or more** windows meet; what makes it a junction is that the windows
    /// around it take different sides of the two dividers, once front-to-back occupancy and the
    /// covering rule have been applied. Quadrants that no window claims are simply left empty.
    ///
    /// **Candidates come from corners, not from pairs of dividers.** Crossing every vertical divider
    /// with every horizontal one can only ever propose points where two dividers meet, and most of the
    /// shapes that deserve a knob have no such point: two windows touching corner to corner diagonally
    /// are not a `HandlePair` at all, and the free end of a divider — two windows filling only the top
    /// half of the screen, say — has no second divider to cross. A corner meeting a corner is the one
    /// thing every junction has, the T included, whose two dividers otherwise have to be *measured* as
    /// meeting and often miss by more than the tolerance allows.
    ///
    /// `coverers` are windows that are no candidate for anything and can still sit over a crossing
    /// (`CoveringSurface`): they enter the covering rule and nothing else.
    public static func evaluate(in windows: [WindowInfo], coverers: [WindowInfo] = [], maxGap: Double) -> [Verdict] {
        let tolerance = edgeTolerance(maxGap: maxGap)
        let candidates = windows.sorted { $0.id < $1.id }

        // Sorted before clustering so equal input gives equal groups, whatever order the window list
        // arrived in.
        var corners = candidates.flatMap { window -> [Corner] in
            let frame = window.frame
            return [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                    CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
                .map { Corner(windowID: window.id, point: $0) }
        }
        corners.sort { ($0.point.x, $0.point.y, $0.windowID) < ($1.point.x, $1.point.y, $1.windowID) }

        // Greedy, against each group's **first** corner rather than its running mean. Transitive
        // closure would let a chain of near misses drift a group arbitrarily far from where it
        // started; an anchor bounds every group to one tolerance box, which is the question being
        // asked — would a person read these corners as meeting at one place. A few dozen windows at
        // 10 Hz, so the O(n²) scan costs nothing.
        var groups: [[Corner]] = []
        for corner in corners {
            let index = groups.firstIndex { group in
                abs(group[0].point.x - corner.point.x) <= tolerance
                    && abs(group[0].point.y - corner.point.y) <= tolerance
            }
            if let index { groups[index].append(corner) } else { groups.append([corner]) }
        }

        return groups.compactMap { group in
            // A lone window's corners are not a crossing, however many of them coincide.
            guard Set(group.map(\.windowID)).count >= 2 else { return nil }
            let point = CGPoint(x: group.map(\.point.x).reduce(0, +) / Double(group.count),
                                y: group.map(\.point.y).reduce(0, +) / Double(group.count))
            return judge(candidates: candidates, at: point, tolerance: tolerance, windows: windows + coverers)
        }
    }

    /// `evaluate`'s accepted junctions. A caller that also wants the verdicts — the controller logs
    /// every rejection — evaluates once and asks `junctions(from:)`.
    public static func junctions(in windows: [WindowInfo], maxGap: Double) -> [Junction] {
        junctions(from: evaluate(in: windows, maxGap: maxGap))
    }

    /// The accepted junctions among `verdicts`, deduplicated — two candidates that disagree by a
    /// rounding error describe one junction — and in the same order for equal inputs.
    ///
    /// **The key is the members *and* the point.** The same set of windows can make two different
    /// junctions: a plain left-half / right-half split has the members `{A, B}` at the top end of
    /// their gap and the same `{A, B}` at the bottom end, and keying on the ids alone would silently
    /// drop one of the two knobs.
    public static func junctions(from verdicts: [Verdict]) -> [Junction] {
        struct Key: Hashable { let ids: Set<UInt32>; let x: Int; let y: Int }
        var found: [Junction] = []
        var seen: Set<Key> = []
        for verdict in verdicts {
            guard case .accepted(let junction) = verdict else { continue }
            let key = Key(ids: junction.windowIDs, x: Int(junction.point.x.rounded()),
                          y: Int(junction.point.y.rounded()))
            guard seen.insert(key).inserted else { continue }
            found.append(junction)
        }
        return found.sorted { ($0.point.x, $0.point.y) < ($1.point.x, $1.point.y) }
    }

    /// The junction at `point` among `candidates`, or nil if they do not make one — including because
    /// something in `windows` covers it. Kept for `revalidate`, whose only candidates are a junction's
    /// own freshly re-read members, offered as both lists, so nothing external can cover it there.
    public static func junction(among candidates: [WindowInfo], at point: CGPoint, tolerance: Double,
                                windows: [WindowInfo]) -> Junction? {
        guard case .accepted(let junction) = judge(candidates: candidates, at: point, tolerance: tolerance,
                                                   windows: windows) else { return nil }
        return junction
    }

    /// The junction these members still make once their frames have been re-read, or nil if they have
    /// moved out of it. The press path uses it: the pairs a junction was offered from are up to one
    /// poll old, and three or four windows that have shifted since are not a junction any more.
    public static func revalidate(_ junction: Junction, frames: [UInt32: CGRect], maxGap: Double) -> Junction? {
        let windows = junction.members.map { member -> WindowInfo in
            var window = member.window
            if let frame = frames[window.id] { window.frame = frame }
            return window
        }
        // Asked at the centre, so the looser of the two tolerances — and safe at that, because a
        // member set that has changed at all is refused outright on the next line.
        guard let fresh = self.junction(among: windows, at: junction.point,
                                        tolerance: centreTolerance(maxGap: maxGap), windows: windows),
              fresh.windowIDs == junction.windowIDs else { return nil }
        return fresh
    }

    /// One candidate crossing's verdict: resolve occupancy front-to-back among `candidates`, check the
    /// shape, then ask whether anything in the full `windows` snapshot covers it.
    private static func judge(candidates: [WindowInfo], at point: CGPoint, tolerance: Double,
                              windows: [WindowInfo]) -> Verdict {
        let resolution = resolveMembers(in: candidates, at: point, tolerance: tolerance)
        let summaries = resolution.members.map { Reason.MemberSummary(id: $0.window.id, x: $0.x, y: $0.y) }
        // An empty quadrant is normal now: an L leaves one, a diagonal pair two, the free end of a
        // divider two. Two is the smallest junction there is, and occupancy is still what makes the
        // members point in *different* directions — two windows sharing a bottom-right corner claim
        // the same cell, only the frontmost survives, and one member is not a junction.
        guard resolution.members.count >= 2, resolution.members.count <= 4 else {
            return .rejected(at: point, reason: .memberCount(resolution.members.count, members: summaries))
        }
        guard resolution.members.filter({ $0.x == .spanning || $0.y == .spanning }).count <= 1 else {
            return .rejected(at: point, reason: .multipleSpanning(members: summaries))
        }
        let centre = centre(of: resolution.members, at: point)
        let junction = Junction(point: centre, members: resolution.members)
        if let coverer = coveringWindow(of: junction, in: windows) {
            return .rejected(at: point, reason: .covered(by: coverer.id, pid: coverer.pid))
        }
        return .accepted(junction)
    }

    /// Resolves which window, if any, occupies each of the four cells around the crossing —
    /// front-to-back, so a window hidden behind the one that actually meets the divider there is
    /// never a member. Candidates that claim the *same* cell(s) are resolved purely by
    /// `zIndex` — the frontmost of the group wins, with no separate frame-intersection test, because
    /// `role`'s own `tolerance` window is what makes two same-cell candidates that do not actually
    /// intersect practically unreachable: both edges are already within a few points of the same
    /// divider, on the same side of it.
    ///
    /// **A member keeps the cells it wins and is dropped only when it wins none.** Requiring it to win
    /// *every* cell it claims would cost every T with a window in front of part of its spanning
    /// member: a spanning member claims two cells, anything in front of it over one of them takes that
    /// cell, and an all-or-nothing rule would drop the spanning member outright — leaving a T that has
    /// lost the very thing that made it one. The rule is that the frontmost claimant of each quadrant
    /// wins and the members are the distinct winners. A window that spans a divider still spans it —
    /// it is the roles, not the cell count, that say what a drag resizes.
    ///
    /// **This is also what makes the corners point in different directions.** Cells no window claims
    /// are left empty, so an L, a diagonal pair and the free end of a divider all resolve; but two
    /// windows whose coinciding corners point the *same* way claim the same single cell, only the
    /// frontmost survives it, and one member is not a junction.
    ///
    /// Still a fixed point rather than one pass: dropping a candidate that won nothing cannot change
    /// any winner, so the second round confirms the first and returns.
    private static func resolveMembers(in windows: [WindowInfo], at point: CGPoint,
                                       tolerance: Double) -> Resolution {
        struct Candidate { let window: WindowInfo; let x: Junction.Role; let y: Junction.Role }
        var remaining: [Candidate] = windows.compactMap { window in
            guard let x = role(min: window.frame.minX, max: window.frame.maxX, at: point.x, tolerance: tolerance),
                  let y = role(min: window.frame.minY, max: window.frame.maxY, at: point.y, tolerance: tolerance)
            else { return nil }
            // A window that spans both dividers covers the crossing rather than meeting it — the
            // covering rule handles that, not occupancy.
            guard x != .spanning || y != .spanning else { return nil }
            return Candidate(window: window, x: x, y: y)
        }

        while true {
            var winner: [[WindowInfo?]] = [[nil, nil], [nil, nil]]
            for candidate in remaining {
                for i in indices(candidate.x) {
                    for j in indices(candidate.y) {
                        if let current = winner[i][j] {
                            if candidate.window.zIndex < current.zIndex { winner[i][j] = candidate.window }
                        } else {
                            winner[i][j] = candidate.window
                        }
                    }
                }
            }
            let next = remaining.filter { candidate in
                indices(candidate.x).contains { i in
                    indices(candidate.y).contains { j in winner[i][j]?.id == candidate.window.id }
                }
            }
            if next.count == remaining.count {
                let members = next
                    .map { Junction.Member(window: $0.window, x: $0.x, y: $0.y) }
                    .sorted { $0.window.id < $1.window.id }
                return Resolution(members: members)
            }
            guard !next.isEmpty else { return Resolution(members: []) }
            remaining = next
        }
    }

    /// The frontmost window that (a) is in front of at least one member, (b) intersects the 24 pt knob
    /// band, and (c) is not itself entirely hidden, within that intersection, behind a member that is
    /// in front of *it*. **A coverer has to be visible over the band**: a window that already lost the
    /// occupancy contest for its own cell to a more-front member sitting at the identical place must
    /// not be able to cancel the crossing merely by being in front of a *different* member elsewhere.
    /// Judged against the full snapshot rather than the occupancy candidates, because a coverer need
    /// not be adjacent to anything.
    private static func coveringWindow(of junction: Junction, in windows: [WindowInfo]) -> WindowInfo? {
        guard let maxMemberZ = junction.members.map(\.window.zIndex).max() else { return nil }
        let band = JunctionGeometry.band(at: junction.point)
        let memberIDs = junction.windowIDs
        return windows
            .filter { !memberIDs.contains($0.id) && $0.zIndex < maxMemberZ && $0.frame.intersects(band) }
            .filter { !isEntirelyHidden($0.frame.intersection(band), of: $0, behind: junction.members) }
            .min { $0.zIndex < $1.zIndex }
    }

    /// Whether `region` — the covering candidate's own overlap with the knob band — is entirely
    /// covered by members that are in front of `window`, i.e. whether `window` is invisible everywhere
    /// it would otherwise cancel the crossing.
    ///
    /// Exact, for axis-aligned rectangles, by coordinate compression: `region` is cut into a grid by
    /// every edge of every such member that falls strictly inside it, and each cell is tested once, by
    /// its centre, against the union of those members — a grid line never crosses a member's own edge,
    /// so a cell's centre being covered means the whole cell is. At most 5×5 cells for a junction's 3
    /// or 4 members (two edges each).
    private static func isEntirelyHidden(_ region: CGRect, of window: WindowInfo,
                                         behind members: [Junction.Member]) -> Bool {
        guard !region.isEmpty else { return true }
        let fronters = members.filter { $0.window.zIndex < window.zIndex }.map(\.window.frame)
        guard !fronters.isEmpty else { return false }

        var xs: Set<Double> = [region.minX, region.maxX]
        var ys: Set<Double> = [region.minY, region.maxY]
        for frame in fronters {
            if frame.minX > region.minX, frame.minX < region.maxX { xs.insert(frame.minX) }
            if frame.maxX > region.minX, frame.maxX < region.maxX { xs.insert(frame.maxX) }
            if frame.minY > region.minY, frame.minY < region.maxY { ys.insert(frame.minY) }
            if frame.maxY > region.minY, frame.maxY < region.maxY { ys.insert(frame.maxY) }
        }
        let sortedX = xs.sorted(), sortedY = ys.sorted()
        for i in 0..<(sortedX.count - 1) {
            for j in 0..<(sortedY.count - 1) {
                let centre = CGPoint(x: (sortedX[i] + sortedX[i + 1]) / 2, y: (sortedY[j] + sortedY[j + 1]) / 2)
                guard fronters.contains(where: { $0.contains(centre) }) else { return false }
            }
        }
        return true
    }

    /// Where a window sits relative to one divider, or nil if it is not at this divider at all.
    /// `.low` is tested first so a window narrower than twice the tolerance resolves rather than
    /// claiming both sides.
    static func role(min lo: Double, max hi: Double, at divider: Double, tolerance: Double) -> Junction.Role? {
        if abs(hi - divider) <= tolerance { return .low }
        if abs(lo - divider) <= tolerance { return .high }
        if lo < divider - tolerance && hi > divider + tolerance { return .spanning }
        return nil
    }

    private static func indices(_ role: Junction.Role) -> [Int] {
        switch role {
        case .low: [0]
        case .high: [1]
        case .spanning: [0, 1]
        }
    }

    /// The middle of the gap the members leave: between the furthest low edge and the nearest high
    /// edge on each axis.
    ///
    /// With empty quadrants allowed, an axis can have members on only one side of it — a diagonal
    /// pair's top-left window is `.low` on both axes and its bottom-right one `.high` on both, so
    /// neither axis is missing anything, but the free end of a divider has two windows that are
    /// `.low`/`.high` on x and *both* `.low` on y. There the gap has only one edge, so that edge is
    /// the answer; and an axis with no member at all falls back to the candidate point.
    private static func centre(of members: [Junction.Member], at point: CGPoint) -> CGPoint {
        func axis(low: [Double], high: [Double], fallback: Double) -> Double {
            switch (low.max(), high.min()) {
            case let (lo?, hi?): (lo + hi) / 2
            case let (lo?, nil): lo
            case let (nil, hi?): hi
            case (nil, nil): fallback
            }
        }
        return CGPoint(
            x: axis(low: members.filter { $0.x == .low }.map { $0.window.frame.maxX },
                    high: members.filter { $0.x == .high }.map { $0.window.frame.minX },
                    fallback: point.x),
            y: axis(low: members.filter { $0.y == .low }.map { $0.window.frame.maxY },
                    high: members.filter { $0.y == .high }.map { $0.window.frame.minY },
                    fallback: point.y))
    }
}
