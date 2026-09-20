import CoreGraphics

/// The two-dimensional drag of the junction knob, and the write plan it produces.
///
/// It is `HandleDragMath` with a second axis and a variable number of windows, and it keeps that
/// type's two rules exactly: far edges never move, and the gap between the windows becomes the gap
/// setting. What is new is that **each axis clamps on its own** — a drag blocked by a minimum size
/// horizontally still moves vertically — and that the plan says, per window, whether its *origin*
/// moved. A 2×2 cross is 4 size writes and 3 position writes, not 8 writes, and at 8.1 ms for a
/// Finder size write against 0.13 ms for its position the difference is worth spending code on.
public enum JunctionDragMath {
    /// What one window has to be told, if anything.
    public struct Change: Hashable, Sendable {
        public var id: UInt32
        public var frame: CGRect
        /// The window's origin moved, so it needs a position write. False for the one member of a
        /// cross whose corner is the junction's top-left — it keeps its origin and only grows.
        public var movesOrigin: Bool
        /// The window's size changed, so it needs a size write — the dear one.
        public var changesSize: Bool
        /// The window is being asked to give up extent on at least one axis, so it is written size
        /// first (it can then be moved into the space it just freed) and it is the only kind of
        /// window that can prove a minimum by refusing.
        public var shrinks: Bool

        public init(id: UInt32, frame: CGRect, movesOrigin: Bool, changesSize: Bool, shrinks: Bool) {
            self.id = id
            self.frame = frame
            self.movesOrigin = movesOrigin
            self.changesSize = changesSize
            self.shrinks = shrinks
        }

        public var writes: Int { (movesOrigin ? 1 : 0) + (changesSize ? 1 : 0) }
    }

    public struct Result: Hashable, Sendable {
        /// The junction after each axis clamped independently. Not rounded: the knob follows the
        /// cursor, and only the frames written to windows are whole points.
        public var point: CGPoint
        /// Every member's frame, whether or not it changed, rounded to whole points.
        public var frames: [UInt32: CGRect]
        /// What actually has to be written, shrinking windows first so no window ever grows through
        /// one that has not yet given way. Members with nothing to say are not in here.
        public var changes: [Change]

        public func frame(_ id: UInt32) -> CGRect? { frames[id] }
        public var writes: Int { changes.reduce(0) { $0 + $1.writes } }
    }

    /// New frames for a junction dragged to `requested`.
    ///
    /// `minSizes` is per window id, and the learned minimum is `HandleDragMath.learnedMinimum`'s —
    /// the same rule, the same tolerance, applied per window per axis. On each axis the clamp is the
    /// tightest of every member's: with four windows the binding constraint can come from any of
    /// them. An axis on which no position satisfies every minimum does not move at all, and the other
    /// one still does.
    ///
    /// The gap is spent per axis, not per junction: see `Junction.halfGap`. A press and a release that
    /// never moved the pointer therefore asks every member for the frame it already has, on a
    /// one-sided axis as much as on a two-sided one.
    public static func frames(for junction: Junction, to requested: CGPoint, gap: Double,
                              visibleFrame: CGRect, minSizes: [UInt32: CGSize]) -> Result {
        // Per axis, because an axis whose members all take the same side has no facing window and so
        // no gap to leave: there the crossing *is* their shared edge. `Junction.halfGap` is the one
        // place that is decided, and `JunctionGeometry` draws the knob by the same rule, so the disc
        // and the edges it is dragging stay the same coordinate.
        let halfX = junction.halfGap(gap, on: .x)
        let halfY = junction.halfGap(gap, on: .y)
        let x = clamp(requested.x, on: .x, of: junction, gap: gap,
                      visibleFrame: visibleFrame, minSizes: minSizes)
        let y = clamp(requested.y, on: .y, of: junction, gap: gap,
                      visibleFrame: visibleFrame, minSizes: minSizes)

        var frames: [UInt32: CGRect] = [:]
        var changes: [Change] = []
        for member in junction.members {
            let current = member.window.frame
            var origin = current.origin
            var size = current.size
            switch member.x {
            case .low: size.width = x - halfX - current.minX
            case .high: origin.x = x + halfX; size.width = current.maxX - (x + halfX)
            case .spanning: break
            }
            switch member.y {
            case .low: size.height = y - halfY - current.minY
            case .high: origin.y = y + halfY; size.height = current.maxY - (y + halfY)
            case .spanning: break
            }
            // Rounded here rather than by the caller, because the three flags below describe the
            // writes that will actually be made: a fractional frame rounded afterwards can turn a
            // change into a no-op, and then the plan would promise a write nothing needed.
            let wanted = CGRect(origin: origin, size: size).roundedToPoints()
            frames[member.window.id] = wanted
            let movesOrigin = wanted.origin != current.origin
            let changesSize = wanted.size != current.size
            guard movesOrigin || changesSize else { continue }
            changes.append(Change(id: member.window.id, frame: wanted, movesOrigin: movesOrigin,
                                  changesSize: changesSize,
                                  shrinks: wanted.width < current.width || wanted.height < current.height))
        }
        // Shrinking first, then by id so the order is the same every pass and a test can state it.
        changes.sort { ($0.shrinks ? 0 : 1, $0.id) < ($1.shrinks ? 0 : 1, $1.id) }
        return Result(point: CGPoint(x: x, y: y), frames: frames, changes: changes)
    }

    /// A member that landed **larger than the frame it was asked for** on one axis — an application
    /// refusing to shrink. It is what the release round produces and what `refit` consumes.
    ///
    /// `edge` is the edge that window actually took at the crossing, which is the only thing about it
    /// the re-fit needs: `maxX`/`maxY` for a `.low` member, `minX`/`minY` for a `.high` one. Both
    /// encroach on the crossing, and that is not obvious for the `.high` case — anchoring is what
    /// makes it so. A right- or bottom-hand window that refuses the size it was given is placed at the
    /// size it *will* take, anchored to the outer edge of the frame it was asked for
    /// (`Geometry.anchoredOrigin`), so the extra extent comes back **inwards**, across the divider,
    /// rather than off the display.
    public struct Refusal: Hashable, Sendable {
        public var id: UInt32
        public var axis: Junction.Axis
        /// Which side of the divider the refuser is on. A `.spanning` member is not resized on that
        /// axis and so can never refuse one; `refit` ignores any refusal that claims otherwise.
        public var role: Junction.Role
        /// The edge the window actually took at the crossing.
        public var edge: Double
        /// How far past the size it was asked for the window landed, on this axis. Only used to pick
        /// between two refusals on one axis — two windows that both refuse cannot both be cleared, and
        /// the larger overshoot is the one worth clearing.
        public var overshoot: Double

        public init(id: UInt32, axis: Junction.Axis, role: Junction.Role, edge: Double, overshoot: Double) {
            self.id = id
            self.axis = axis
            self.role = role
            self.edge = edge
            self.overshoot = overshoot
        }
    }

    /// Where the members that share a divider with a refuser belong, once that refuser has landed
    /// somewhere other than the frame it was asked for.
    ///
    /// It is `HandleDragMath.refit` with a second axis and a variable number of windows, and it keeps
    /// that function's rule exactly: a moved member's **far** edge stays where it is and its **near**
    /// edge is set half a gap clear of the divider the refuser's own edge implies, so the arrangement
    /// cannot end overlapping whatever any application did with the size it was given. Each axis is
    /// decided on its own, from the worst refusal on it, and only the members on the *opposite* side of
    /// that divider move — a member on the refuser's own side is already where the drag asked it to be.
    ///
    /// `current` is where each member is believed to be now: the frame it landed on where that is
    /// known, so an application that repositioned itself while answering is not fought, and the frame
    /// it was asked for otherwise. `minSizes` clamps the **size** only, never the near edge: a member
    /// squeezed past its floor keeps the position that clears the overlap and overruns its own far
    /// edge, because an overlap is what the user sees and a far edge a few points past where it was is
    /// not.
    ///
    /// Returns only the members whose frame actually changes, rounded to whole points.
    public static func refit(_ junction: Junction, current: [UInt32: CGRect],
                             refusals: [Refusal], gap: Double,
                             minSizes: [UInt32: CGSize]) -> [UInt32: CGRect] {
        // The divider each axis really ended at, which side proved it, and the half-gap that axis is
        // spending — `Junction.halfGap` again, so a one-sided axis clears an overlap without inventing
        // a gap the drag itself never left. `max(by:)` over the overshoot is the tie-break: the
        // deepest refusal is the one that has to be cleared.
        var dividers: [Junction.Axis: (position: Double, role: Junction.Role, half: Double)] = [:]
        for axis in Junction.Axis.allCases {
            let half = junction.halfGap(gap, on: axis)
            let onAxis = refusals.filter { $0.axis == axis && $0.role != .spanning }
            guard let worst = onAxis.max(by: { $0.overshoot < $1.overshoot }) else { continue }
            dividers[axis] = (worst.role == .low ? worst.edge + half : worst.edge - half, worst.role, half)
        }
        guard !dividers.isEmpty else { return [:] }

        var fitted: [UInt32: CGRect] = [:]
        for member in junction.members {
            guard let base = current[member.window.id] else { continue }
            let minimum = minSizes[member.window.id] ?? CGSize(width: 1, height: 1)
            var frame = base
            if let divider = dividers[.x], member.x != .spanning, member.x != divider.role {
                if member.x == .high {
                    let near = divider.position + divider.half
                    frame = CGRect(x: near, y: frame.minY,
                                   width: max(frame.maxX - near, minimum.width), height: frame.height)
                } else {
                    let near = divider.position - divider.half
                    frame = CGRect(x: frame.minX, y: frame.minY,
                                   width: max(near - frame.minX, minimum.width), height: frame.height)
                }
            }
            if let divider = dividers[.y], member.y != .spanning, member.y != divider.role {
                if member.y == .high {
                    let near = divider.position + divider.half
                    frame = CGRect(x: frame.minX, y: near,
                                   width: frame.width, height: max(frame.maxY - near, minimum.height))
                } else {
                    let near = divider.position - divider.half
                    frame = CGRect(x: frame.minX, y: frame.minY,
                                   width: frame.width, height: max(near - frame.minY, minimum.height))
                }
            }
            let wanted = frame.roundedToPoints()
            guard wanted != base.roundedToPoints() else { continue }
            fitted[member.window.id] = wanted
        }
        return fitted
    }

    /// The window of positions this axis allows, from every member's minimum size on it and, on a
    /// one-sided axis, from the working area it may not be dragged past. Returns the junction's
    /// current position on that axis when the two cannot both be honoured — the axis stops, and
    /// `frames` then produces no change for it while the other axis keeps moving.
    ///
    /// The half-gap is this axis's own — `Junction.halfGap`, the same number `frames` places the
    /// members' edges by — so the minimum-size bound is where each member's minimum really runs out:
    /// on a one-sided axis it is zero and the floor is the edge itself. It is derived here rather than
    /// passed in, so a caller cannot hand this function a half that disagrees with the one the frames
    /// were built with.
    ///
    /// **The working-area bound applies only where the axis is one-sided.** A two-sided axis moves the
    /// divider between two windows whose far edges are already fixed, so it can never leave the
    /// screen; a one-sided axis grows the members' shared *near* edge — the crossing itself — outwards
    /// with nothing else to stop it. That edge is the junction point, so the point is what is bounded,
    /// and it is held a **whole** gap off the working area, not a half, because a whole gap is what a
    /// snapped window leaves between itself and the screen edge.
    static func clamp(_ requested: Double, on axis: Junction.Axis, of junction: Junction,
                      gap: Double, visibleFrame: CGRect, minSizes: [UInt32: CGSize]) -> Double {
        let half = junction.halfGap(gap, on: axis)
        var lower = -Double.infinity
        var upper = Double.infinity
        for member in junction.members {
            let frame = member.window.frame
            let minimum = minSizes[member.window.id] ?? CGSize(width: 1, height: 1)
            let low = axis == .x ? frame.minX : frame.minY
            let high = axis == .x ? frame.maxX : frame.maxY
            let extent = axis == .x ? minimum.width : minimum.height
            switch member.role(on: axis) {
            case .low:
                lower = max(lower, low + extent + half)
                // One-sided: nothing faces these members, so the crossing is their outer edge and the
                // working area is what stops it.
                if !junction.isTwoSided(on: axis) {
                    upper = min(upper, (axis == .x ? visibleFrame.maxX : visibleFrame.maxY) - gap)
                }
            case .high:
                upper = min(upper, high - extent - half)
                if !junction.isTwoSided(on: axis) {
                    lower = max(lower, (axis == .x ? visibleFrame.minX : visibleFrame.minY) + gap)
                }
            case .spanning: break
            }
        }
        let current = axis == .x ? junction.point.x : junction.point.y
        guard lower <= upper else { return current }
        return min(max(requested, lower), upper)
    }
}
