import CoreGraphics

/// Where the junction knob goes and how big it is, in CG space. The same split as `HandleBarGeometry`:
/// a small drawn target inside a generous grab region, and one function that both positions the panel
/// and answers the hit test so the two can never drift apart.
public enum JunctionGeometry {
    /// The drawn knob: a diameter matched to the pill's measured thickness so the two read as one
    /// family. It is expressed as a multiple of that thickness rather than as a number, so the two
    /// cannot come apart if the pill is measured again.
    ///
    /// Three times, not once: the pill is 4 pt thick because it is a *bar* seen across its short
    /// side, 48 pt long in the other direction. A circle has no long direction, so a 4 pt one is a
    /// speck — at 12 pt it covers the same kind of area as the pill (113 pt² against 192) and reads
    /// as the same white, round, shadowed family.
    public static let knobDiameter: Double = 3 * HandleBarGeometry.pillThickness

    /// The square that shows the knob and catches the press, centred on the junction.
    ///
    /// 24 pt is the widest gap `handleMaxGap` allows, so the band is never narrower than the gap it
    /// sits in, and it is twice the drawn knob — the pill's own ratio of grab region to drawn
    /// target (10 over 4) applied to a target that has to be caught in two dimensions at once.
    public static let bandSize: Double = 24

    /// How big the panel is **while the knob is dragged**, on *both* axes.
    ///
    /// Measured on the pair handle: over a 600 ms drag the panel lags the pointer that is moving it,
    /// and the pointer left and re-entered its 10 pt band five times, handing the cursor region back
    /// to the window underneath on every exit. `HandleBarGeometry.dragBandThickness` is the width
    /// that answers it on one axis; a knob is dragged in two, so it is the same number on both. The
    /// panel is invisible outside the knob and the button is down for the whole of it.
    public static let dragBandSize: Double = HandleBarGeometry.dragBandThickness

    /// How far a **T**'s knob is pushed off the crossing, away from the member that spans.
    ///
    /// A T's free space is not symmetric about its crossing. On the spanning member's side there is a
    /// flat face, half a gap away — 4 pt at the default. On the other side the two facing windows
    /// round their 17 pt corners away from the crossing and the gap between them carries on as a
    /// corridor, so the space keeps opening outward. A disc centred on the crossing reads as pressed
    /// against the flat face rather than sitting in that space; at 4.5 pt the 12 pt disc clears the
    /// face by 2.5 pt.
    ///
    /// **Judged by eye against the installed app, not measured.** The pocket the eye centres the disc
    /// in has no far edge to put a number on — the open side is a corridor, not a wall. The bracket is
    /// narrow: 3 pt still reads as hugging the face, 6 pt as floating free of the crossing.
    ///
    /// A flat distance, not a fraction of the gap. What opens the space is the corner radius, which is
    /// still there when the gap is switched off.
    public static let teeOffset: Double = 4.5

    /// Where the knob is drawn and pressed: the **midpoint of the two facing window edges**, per axis,
    /// as those windows actually are.
    ///
    /// **The knob is centred on the crossing on both axes, except at a T, where it is pushed
    /// `teeOffset` away from the spanning member.** A cross, an L, a diagonal pair and the free end of
    /// a divider are all drawn exactly on the crossing, and at a gap narrower than the 12 pt disc such
    /// a knob overlaps both sides equally — 2 pt each at the 8 pt default.
    ///
    /// Measured: a disc drawn from anything but the members' own edges sits **1 pt** above the middle
    /// of the gap band it is in (the vertical band was exact; the horizontal one measured 16 px of gap
    /// at 2× with the disc's 24 px centred 2 px high). What is centred is stated once and in one
    /// place: the knob's centre is read off the **members' own edges**, never off `junction.point` —
    /// a point that is *proposed* by whichever pair of dividers found the crossing and carried on the
    /// value — and never off a nominal zone or a settings gap, whose halves are exactly what anchoring
    /// and a `roundedToPoints()` leave a point away from where the windows really are.
    /// `JunctionDetector` derives its point the same way, so on a crossing it found this is the same
    /// number; on anything else it is the one that matches the screen.
    public static func knobCentre(for junction: Junction) -> CGPoint {
        knobCentre(for: junction, frames: [:])
    }

    /// The same place, asked of the frames a **drag** is drawing rather than of the frames the press
    /// read: the middle of the gap band each axis's members leave between them.
    ///
    /// The knob's half of the same rule as `HandleBarGeometry.divider(between:and:)`. The previews are
    /// drawn at `JunctionDragMath.Result.frames`, which are rounded to whole points, while
    /// `Result.point` is not: one pointer sample, one pass, two roundings would drift the knob up to
    /// half a point inside its gap on every event. Reading the drawn frames makes the two the same
    /// number. Per axis, and it falls back to `junction.point` only on an axis with no member on
    /// either side of it at all (a spanning member is not on either side of the divider it spans and
    /// says nothing about it) — which is also what the resting knob above asks for, with no drawn
    /// frames to prefer.
    ///
    /// A T's push is applied here rather than at either call site, so the knob is offset by the same
    /// amount at rest and under the pointer and nothing moves at the press.
    public static func knobCentre(for junction: Junction, frames: [UInt32: CGRect]) -> CGPoint {
        let centre = CGPoint(x: bandCentre(of: junction, on: .x, frames: frames) ?? junction.point.x,
                             y: bandCentre(of: junction, on: .y, frames: frames) ?? junction.point.y)
        return pushedFromSpanningMember(centre, of: junction)
    }

    /// A T's knob, moved `teeOffset` off the crossing away from the spanning member: outward along the
    /// divider that terminates at it, into the gap its two facing windows leave.
    ///
    /// The member's role on the axis it **spans** picks which coordinate moves, and its role on the
    /// other axis picks the sign — a member `.low` on x sits left of the vertical divider, so the
    /// space is to the right of it. Its own frame on the spanned axis plays no part: a spanning member
    /// says nothing about where the divider it runs past sits.
    ///
    /// A spanning member never spans both axes — `JunctionDetector` drops a window that covers the
    /// crossing rather than meeting it — so at most one branch fires. A junction with no spanning
    /// member at all (a cross, an L, a diagonal pair, the free end of a divider) passes through.
    private static func pushedFromSpanningMember(_ centre: CGPoint, of junction: Junction) -> CGPoint {
        guard let spanning = junction.spanningMember else { return centre }
        var centre = centre
        if spanning.y == .spanning {
            centre.x += spanning.x == .low ? teeOffset : -teeOffset
        } else if spanning.x == .spanning {
            centre.y += spanning.y == .low ? teeOffset : -teeOffset
        }
        return centre
    }

    private static func bandCentre(of junction: Junction, on axis: Junction.Axis,
                                   frames: [UInt32: CGRect]) -> Double? {
        func frame(_ member: Junction.Member) -> CGRect { frames[member.window.id] ?? member.window.frame }
        let low = junction.members
            .filter { $0.role(on: axis) == .low }
            .map { axis == .x ? frame($0).maxX : frame($0).maxY }
            .max()
        let high = junction.members
            .filter { $0.role(on: axis) == .high }
            .map { axis == .x ? frame($0).minX : frame($0).minY }
            .min()
        // Exactly `JunctionDetector.centre(of:at:)`'s rule, and it has to be: that one settles where
        // the junction rests and this one draws the disc, at rest and under the pointer alike, so a
        // knob that read a different rule would jump the moment a drag began.
        //
        // **A one-sided axis is the members' shared edge, not a midpoint.** Two windows stacked one
        // above the other are both `.low` on x at the right-hand end of their divider: there is no
        // facing edge to take a midpoint with, and demanding one is what left the disc behind while
        // the windows under it followed the pointer. The single edge is the whole answer — and it is
        // the same coordinate `JunctionDragMath` puts those windows' edges at, because
        // `Junction.halfGap` reserves nothing on an axis like this.
        switch (low, high) {
        case let (lo?, hi?): return (lo + hi) / 2
        case let (lo?, nil): return lo
        case let (nil, hi?): return hi
        case (nil, nil): return nil
        }
    }

    /// The region the knob is shown in and pressed in.
    public static func band(at point: CGPoint) -> CGRect { square(bandSize, at: point) }

    /// The panel's frame: exactly the band at rest, widened on both axes while dragging.
    ///
    /// Exactly the band, and not a point more, for the reason `HandleBarGeometry.panelRect` gives:
    /// the panel takes mouse events, so any point it covers that the controller would decline is a
    /// point where a click does nothing at all.
    public static func panelRect(at point: CGPoint, dragging: Bool = false) -> CGRect {
        square(dragging ? dragBandSize : bandSize, at: point)
    }

    private static func square(_ side: Double, at point: CGPoint) -> CGRect {
        CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    }
}
