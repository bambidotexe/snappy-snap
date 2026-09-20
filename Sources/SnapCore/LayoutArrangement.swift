import CoreGraphics

/// A layout chosen from the snap bar, with the windows that have been put in its cells so far.
///
/// **It holds nothing that was on screen before.** A drop from the snap bar is the user redoing the
/// whole working area, so the arrangement is the layout and its own members and no other window is
/// ever consulted: the two-thirds cell is the two-thirds cell whatever stands there now. What can
/// change a cell is only a member's own limits — a window that will not shrink to its cell moves the
/// divider and the other cells take the rest, one that will not grow to it leaves them more.
///
/// A cell nobody has been put in yet is an **open** cell. It is solved with a placeholder minimum so
/// that a member's needs cannot squeeze it to nothing, and it is offered only while it lies entirely
/// inside the working area: a cell hanging off the display is a cell no window should be sent to.
public struct LayoutArrangement: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var windowID: UInt32
        public var limits: SizeLimits

        public init(windowID: UInt32, limits: SizeLimits) {
            self.windowID = windowID
            self.limits = limits
        }
    }

    public struct Solved: Hashable, Sendable {
        /// Where each member goes, by the index of its cell.
        public var members: [Int: CGRect]
        /// The cells still on offer, by index.
        public var open: [Int: CGRect]
        /// Open cells the members have pushed off the display, in layout order.
        public var withdrawn: [Int]
    }

    /// What an open cell is solved with: the size any window is presumed to go down to, since any
    /// window may be the one put in it.
    public static let openCellMinimum = MinimumSizePolicy.presumedFloor

    public var layout: Layout
    public var area: CGRect
    public var gap: Double
    /// The windows placed so far, by the index of the cell each is in.
    public var members: [Int: Member]

    public init(layout: Layout, area: CGRect, gap: Double, members: [Int: Member] = [:]) {
        self.layout = layout
        self.area = area
        self.gap = gap
        self.members = members
    }

    public var arrangement: Arrangement {
        let boxes = layout.cells.indices.map { index in
            let cell = Geometry.frame(for: layout.cells[index], in: area, gap: gap)
            if let member = members[index] {
                return ArrangementBox(id: .window(member.windowID), preferred: cell, limits: member.limits)
            }
            return ArrangementBox(id: .cell(index), preferred: cell, limits: SizeLimits(minimum: Self.openCellMinimum))
        }
        return Arrangement(area: area, gap: gap, aligned: true, boxes: boxes)
    }

    public func solve() -> Solved { solved(from: arrangement.solve()) }

    /// A solution of `arrangement`, read back by cell: where each member goes, which open cells are
    /// still on offer, and which the members have pushed off the display.
    public func solved(from solution: ArrangementSolution) -> Solved {
        let inside = area.insetBy(dx: gap - ArrangementSolver.tolerance, dy: gap - ArrangementSolver.tolerance)
        var solved = Solved(members: [:], open: [:], withdrawn: [])
        for index in layout.cells.indices {
            if let member = members[index] {
                solved.members[index] = solution.frames[.window(member.windowID)]
            } else if let frame = solution.frames[.cell(index)] {
                if inside.contains(frame) { solved.open[index] = frame } else { solved.withdrawn.append(index) }
            }
        }
        return solved
    }
}

/// What a window's landing says about the sizes it will take.
///
/// macOS publishes neither a minimum nor a maximum window size, so a window's limits are only ever
/// learned by asking for a size and reading back what was accepted. A landing **larger** than it was
/// asked for is the window refusing to shrink: that size is its minimum. One **smaller** is the window
/// refusing to grow: that size is its maximum. Anything within `HandleDragMath.roundingAllowance` is an
/// application rounding its own frame — a terminal on its character grid — and says nothing.
public enum ArrangementFacts {
    /// `limits` with what this landing reveals, or nil when it reveals nothing new.
    ///
    /// `before` is the frame the window had when the write was posted: a frame identical to it is one
    /// the application has not applied yet, which reads as a total refusal and proves nothing
    /// (`MinimumSizePolicy.landingIsEvidence`).
    ///
    /// The two limits are kept consistent per axis. A minimum above an earlier maximum replaces it, and
    /// a maximum below a minimum lowers that minimum — a minimum may have been presumed, and a window
    /// standing at a size is proof that it goes that small.
    public static func revealed(_ limits: SizeLimits, asked: CGRect, landed: CGRect, before: CGRect) -> SizeLimits? {
        guard MinimumSizePolicy.landingIsEvidence(landed: landed, before: before) else { return nil }
        let allowance = HandleDragMath.roundingAllowance
        var revealed = limits

        let width = Double(landed.width), height = Double(landed.height)
        if width > Double(asked.width) + allowance {
            revealed.minimum.width = width
            if let maximum = revealed.maximumWidth, maximum < width { revealed.maximumWidth = nil }
        } else if width < Double(asked.width) - allowance {
            revealed.maximumWidth = width
            if Double(revealed.minimum.width) > width { revealed.minimum.width = width }
        }
        if height > Double(asked.height) + allowance {
            revealed.minimum.height = height
            if let maximum = revealed.maximumHeight, maximum < height { revealed.maximumHeight = nil }
        } else if height < Double(asked.height) - allowance {
            revealed.maximumHeight = height
            if Double(revealed.minimum.height) > height { revealed.minimum.height = height }
        }
        return revealed == limits ? nil : revealed
    }

    /// Whether `solved` is a frame worth writing over the one a window has now.
    ///
    /// A first write is exact: a point is a point. A **correction** allows a size the rounding
    /// allowance, because the frame it is compared with is one an application chose for itself — a
    /// terminal on its character grid lands a few points off every time it is asked, and correcting
    /// that would ask it again for ever. A window standing in the wrong place is moved either way.
    public static func isWorthWriting(_ solved: CGRect, over current: CGRect, correcting: Bool) -> Bool {
        let size = correcting ? HandleDragMath.roundingAllowance : 1
        return abs(Double(solved.minX) - Double(current.minX)) > 1 || abs(Double(solved.minY) - Double(current.minY)) > 1
            || abs(Double(solved.width) - Double(current.width)) > size
            || abs(Double(solved.height) - Double(current.height)) > size
    }
}
