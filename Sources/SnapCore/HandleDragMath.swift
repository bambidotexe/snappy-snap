import CoreGraphics

public enum HandleDragMath {
    /// Smallest sizes each window accepts. Learned at runtime when a set size comes back larger.
    public struct MinSizes: Hashable, Sendable {
        public var a: CGSize
        public var b: CGSize
        public init(a: CGSize = CGSize(width: 1, height: 1), b: CGSize = CGSize(width: 1, height: 1)) {
            self.a = a
            self.b = b
        }
    }

    public struct Result: Hashable, Sendable {
        public var a: CGRect
        public var b: CGRect
        public var divider: Double
    }

    /// How much larger than the request a size may come back and still not be a refusal.
    ///
    /// **Measured.** Half a point covers an application that rounds its own frame, which is all
    /// TextEdit and Finder ever need. Terminal does something else: it snaps its window to whole
    /// character cells. At 0.5 pt of tolerance every such landing reads as a refusal, the learned
    /// minimum ratchets up to the size the window is *already* at, and the drag freezes solid — a live
    /// cross of Chrome, Terminal, Finder and TextEdit moves 8 pt and stops.
    ///
    /// **The grid, and the rounding policy, measured directly** (`axprobe setframeid`, re-seating the
    /// window at 524 × 390 between every ask so each is an independent sample):
    ///
    /// | axis | cells | ask → land | switch point |
    /// |---|---|---|---|
    /// | height | 18 pt (…372, 390…) | 384→390, 383→390, 382→390, **381→390**, **380→372**, 379→372, 378→372 | 381, the exact midpoint |
    /// | width | 8 pt (…516, 524…) | 523→524, 521→524, **520→524**, **519→516**, 517→516 | 520, the exact midpoint |
    ///
    /// So Terminal rounds **to the nearest cell**, ties upward — not up. That distinction is the whole
    /// question, because under round-*up* an 18 pt row would overshoot by up to 17 pt and no allowance
    /// below 18 would hold. Under round-to-nearest the worst overshoot is exactly half a cell: **9 pt
    /// on the row, 4 on the column**, and it is reached only at the midpoint (ask 381, get 390).
    /// 380→372 is the sample that tells the two policies apart.
    ///
    /// 12 pt is a third more than that measured 9, and the two ways of being wrong are not symmetric.
    /// Too small and a window that rounds freezes the whole gesture, every axis it touches. Too large
    /// and a genuine minimum is learned a pass or two late, so the divider slides up to about this far
    /// past a window that has already stopped and then snaps back to it — and for the junction knob
    /// the final pass re-clamps, so it does not survive the release.
    ///
    /// **What still fails.** An application whose size grid is coarser than twice this — a terminal at
    /// roughly a third more than the default font, since 18 pt rows come from the shipped one — can
    /// still ratchet a false minimum from its very first read, before any grain has been observed.
    /// The gesture is recoverable by releasing and dragging again, because minimums are per-gesture.
    /// The general fix, not taken here, is to treat a shortfall smaller than this as a *candidate*
    /// minimum and promote it only when a second, smaller request lands on the same size: a window
    /// that rounds answers a different size each time, a window at its floor answers the same one.
    public static let roundingAllowance: Double = 12

    /// A size that comes back larger than it was asked for is the window refusing to shrink, and that
    /// size is its floor from then on. `tolerance` absorbs what an app rounds by — see
    /// `roundingAllowance`, which is measured off a real window grid and not a guess.
    ///
    /// Minimums only ever grow within one drag: a window that proved it will not go below 400 pt does
    /// not stop being that window because a later pass asked it for 600 and got 600.
    public static func learnedMinimum(_ current: CGSize, landed: CGSize, requested: CGSize,
                                      tolerance: Double = roundingAllowance) -> CGSize {
        CGSize(
            width: landed.width > requested.width + tolerance ? max(current.width, landed.width) : current.width,
            height: landed.height > requested.height + tolerance ? max(current.height, landed.height) : current.height
        )
    }

    /// Where the neighbour belongs once the other window has **landed** somewhere other than the frame
    /// it was asked for — a window that refused to shrink and so kept an edge inside the gap, or one
    /// that anchoring pushed back across it.
    ///
    /// The rule is the gesture's own, applied to a fact instead of to a request: the neighbour's **far**
    /// edge stays exactly where it is, and its **near** edge is set one `gap` clear of the edge the
    /// other window actually took. So the pair cannot end overlapping, whatever either application did
    /// with the size it was given.
    ///
    /// `neighbourIsB` says which side the neighbour is: `b` is the right window of a horizontal pair and
    /// the lower one of a vertical pair, so its near edge is its minimum and `a`'s is its maximum.
    ///
    /// `minimum` is the floor the neighbour is already known to have. It is applied to the **size**
    /// only, never to the near edge: a neighbour squeezed past its floor keeps the position that clears
    /// the overlap and overruns its own far edge, because an overlap is what the user sees and a far
    /// edge a few points past where it was is not.
    public static func refit(_ neighbour: CGRect, after landed: CGRect,
                             orientation: HandlePair.Orientation, neighbourIsB: Bool,
                             gap: Double, minimum: CGSize) -> CGRect {
        switch orientation {
        case .horizontal:
            if neighbourIsB {
                let x = landed.maxX + gap
                return CGRect(x: x, y: neighbour.minY,
                              width: max(neighbour.maxX - x, minimum.width), height: neighbour.height)
            }
            let maxX = landed.minX - gap
            return CGRect(x: neighbour.minX, y: neighbour.minY,
                          width: max(maxX - neighbour.minX, minimum.width), height: neighbour.height)
        case .vertical:
            if neighbourIsB {
                let y = landed.maxY + gap
                return CGRect(x: neighbour.minX, y: y,
                              width: neighbour.width, height: max(neighbour.maxY - y, minimum.height))
            }
            let maxY = landed.minY - gap
            return CGRect(x: neighbour.minX, y: neighbour.minY,
                          width: neighbour.width, height: max(maxY - neighbour.minY, minimum.height))
        }
    }

    /// New frames for a divider at `requested`. Far edges stay put, the gap becomes `gap`, and the
    /// divider is clamped so neither window shrinks below its minimum. If both minimums cannot fit
    /// at once, the frames are returned unchanged.
    ///
    /// The clamp is what makes the divider **stop** at a window's floor while the pointer carries on,
    /// and — because the answer is a pure function of `requested` and nothing is carried between passes
    /// — what makes it pick the pointer back up with no jump when it returns past the limit.
    public static func frames(for pair: HandlePair, divider requested: Double, gap: Double, minSizes: MinSizes) -> Result {
        let a = pair.a.frame, b = pair.b.frame
        let half = gap / 2
        switch pair.orientation {
        case .horizontal:
            let lower = a.minX + minSizes.a.width + half
            let upper = b.maxX - minSizes.b.width - half
            guard lower <= upper else { return Result(a: a, b: b, divider: pair.divider) }
            let d = min(max(requested, lower), upper)
            return Result(
                a: CGRect(x: a.minX, y: a.minY, width: d - half - a.minX, height: a.height),
                b: CGRect(x: d + half, y: b.minY, width: b.maxX - (d + half), height: b.height),
                divider: d
            )
        case .vertical:
            let lower = a.minY + minSizes.a.height + half
            let upper = b.maxY - minSizes.b.height - half
            guard lower <= upper else { return Result(a: a, b: b, divider: pair.divider) }
            let d = min(max(requested, lower), upper)
            return Result(
                a: CGRect(x: a.minX, y: a.minY, width: a.width, height: d - half - a.minY),
                b: CGRect(x: b.minX, y: d + half, width: b.width, height: b.maxY - (d + half)),
                divider: d
            )
        }
    }
}
