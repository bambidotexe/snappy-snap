import CoreGraphics
import Foundation

/// What counts as evidence of a window's floor, how a saved floor comes down, and what a gesture
/// clamps with when it may not ask. Pure; `MinimumSizeStore` applies these to the list and the
/// window table, `MinimumProbe` to a read-back.
public enum MinimumSizePolicy {
    // MARK: - Lowering a saved floor

    /// How much smaller than a saved floor a window must be seen before the floor comes down to it,
    /// and how much higher than a row a probe must read before it raises the window's own floor. One
    /// point of slack, for the rounding every application does to its own frame and for `Geometry`'s
    /// refusal to round at all: a floor one point over the window it describes is arithmetic.
    public static let observationTolerance: Double = 1

    /// What a saved floor becomes after a window of it is seen at `observed`: per axis, the observed
    /// value when it is smaller by more than `observationTolerance`, otherwise unchanged. Nil when
    /// neither axis moves. **A saved floor only ever comes down this way**; nothing here raises one.
    /// An observed axis that is not positive is a window that was not read, and says nothing.
    public static func lowered(_ floor: CGSize, seeing observed: CGSize) -> CGSize? {
        var result = floor
        var changed = false
        if let width = lowered(Double(floor.width), seeing: Double(observed.width)) {
            result.width = width
            changed = true
        }
        if let height = lowered(Double(floor.height), seeing: Double(observed.height)) {
            result.height = height
            changed = true
        }
        return changed ? result : nil
    }

    static func lowered(_ current: Double, seeing observed: Double) -> Double? {
        guard observed > 0, current - observed > observationTolerance else { return nil }
        return observed
    }

    /// What a window will not go below: its application's row lifted, per axis, by the window's own
    /// floor. Nil when there is neither; **0 on an axis nothing knows**, which `presumed` fills with
    /// `presumedFloor` and `floorWithoutProbing` with `unprobedFloor`.
    public static func floor(row: CGSize?, window: WindowFloor?) -> CGSize? {
        guard row != nil || window?.isEmpty == false else { return nil }
        return CGSize(width: max(Double(row?.width ?? 0), window?.width ?? 0),
                      height: max(Double(row?.height ?? 0), window?.height ?? 0))
    }

    // MARK: - Clamping without a probe

    /// The floor a gesture clamps with when the user has switched probing off and nothing has been
    /// measured for the window yet.
    ///
    /// It is not a guess at any application's real minimum. It is the size below which this app will
    /// not take a window whatever its application would accept, so that a divider cannot leave a
    /// window too small to see or to grab back. Wide enough for a title bar's three buttons, tall
    /// enough for that bar with content under it. **Fitted by eye; no measurement establishes it.**
    public static let unprobedFloor = CGSize(width: 120, height: 80)

    /// The floor for a press that is not allowed to probe: **the larger of what is already known and
    /// `unprobedFloor`, per axis independently.**
    ///
    /// A lower bound, not a replacement. Switching probing off says *never blink a window while I am
    /// looking at it*, not *forget what you know*: a floor already learned — from an earlier probe,
    /// from the Snap Assist deck, or from an application that refused a size — is still the truth
    /// about that window, and still stops the divider where the window really stops.
    ///
    /// `stored` is optional because there may be no record at all, and **an axis of a record reads 0
    /// when nobody has measured it**, which is the same statement made per axis. One `max` answers
    /// both.
    public static func floorWithoutProbing(stored: CGSize?) -> CGSize {
        CGSize(width: max(stored?.width ?? 0, unprobedFloor.width),
               height: max(stored?.height ?? 0, unprobedFloor.height))
    }

    // MARK: - A window nobody has measured

    /// How small a window is presumed to go when nobody has measured it, which is how far an
    /// arrangement may ask it to shrink. **No measurement establishes the number**: it is small enough
    /// that a window which can give room is asked to, and large enough that no window is ever asked to
    /// become something nobody could use. An application that refuses teaches its real minimum, and
    /// that is what the next arrangement is solved with.
    public static let presumedFloor = CGSize(width: 200, height: 150)

    /// `known`, with `presumedFloor` on every axis it says nothing about. An axis of a record reads 0
    /// when nobody has measured it, and no record at all is the same statement made of both.
    public static func presumed(_ known: CGSize?) -> CGSize {
        CGSize(width: (known?.width ?? 0) > 0 ? known!.width : presumedFloor.width,
               height: (known?.height ?? 0) > 0 ? known!.height : presumedFloor.height)
    }

    // MARK: - Believing a measurement

    /// How far a reading may sit from the size that was there before it and still count as a
    /// *measurement* rather than a stale read. The same one point of slack as `observationTolerance`, for
    /// the same reason: an application that rounds its own frame by half a point has not moved.
    public static let settleTolerance: Double = 1

    /// The largest share of the available area a probed floor may claim before it is disbelieved on its
    /// face. A window that says it cannot be narrower than four fifths of the working area is saying it
    /// can never be tiled beside anything — which a handful of applications really do mean, but which a
    /// read taken before the application settled *also* looks exactly like, and only one of those two
    /// is common. Disbelieving costs a re-probe at the next press; believing costs a window that can
    /// never be made smaller again.
    public static let implausibleFloorShare: Double = 0.8

    /// Which axes of a probe's read-back are evidence of a floor, and which are not.
    ///
    /// Returns the believable axes and **0** on every axis that is not — the convention
    /// `MinimumSizeStore.recordProbe` reads as "this probe says nothing about this axis". `.zero` means
    /// the probe taught nothing at all, which is the right answer far more often than a number is.
    ///
    /// Three ways an axis fails, and they are all the same mistake — believing a number the application
    /// has not settled into:
    ///
    /// - **A read-back that is not smaller than the size the window came in with.** The probe writes
    ///   1 × 1 and reads what the application accepted, and an application that reflows its content on
    ///   resize (a terminal re-wrapping its scrollback, an editor re-laying out) can answer the read
    ///   with the size it still had when the write arrived. That answer is indistinguishable from
    ///   "this application refused to move at all", and the two have opposite consequences: one is a
    ///   stale read worth nothing, the other freezes the window at whatever size it happened to have,
    ///   for ever. A floor that genuinely equals the window's current size is vanishingly rare and is
    ///   re-learnable at the next press; a stale read that looks like one is common and is not
    ///   recoverable. So the tie goes to learning nothing.
    /// - **A non-positive read-back.** A window that was not read, not a window with no floor.
    /// - **A floor that claims most of `area`.** See `implausibleFloorShare`. `area` is optional
    ///   because not every caller knows which display the window is on; nil simply skips this test.
    public static func believableFloor(readBack: CGSize, before: CGSize, area: CGSize?) -> CGSize {
        CGSize(width: believable(Double(readBack.width), before: Double(before.width),
                                 area: area.map { Double($0.width) }),
               height: believable(Double(readBack.height), before: Double(before.height),
                                  area: area.map { Double($0.height) }))
    }

    private static func believable(_ readBack: Double, before: Double, area: Double?) -> Double {
        guard readBack > 0 else { return 0 }
        guard before - readBack > settleTolerance else { return 0 }
        if let area, area > 0, readBack > area * implausibleFloorShare { return 0 }
        return readBack
    }

    /// Two read-backs of the same probe, taken one after the other, reduced to the one a floor may be
    /// read from: **per axis the smaller of the two**, and the other one whenever an axis of either
    /// read came back non-positive.
    ///
    /// The smaller, because the two reads bracket an application that is still settling and settling
    /// only ever goes *down* — the window is on its way to the 1 × 1 it was asked for, never away from
    /// it. And because the two errors are not symmetrical: a floor learned too small stops the divider
    /// late and the application refuses the size, which the refusal path then learns from; a floor
    /// learned too large stops the divider early and nothing the user does inside this app can argue
    /// with it.
    public static func settledFloor(_ first: CGSize, _ second: CGSize) -> CGSize {
        CGSize(width: smaller(Double(first.width), Double(second.width)),
               height: smaller(Double(first.height), Double(second.height)))
    }

    private static func smaller(_ a: Double, _ b: Double) -> Double {
        guard a > 0 else { return max(b, 0) }
        guard b > 0 else { return a }
        return min(a, b)
    }

    /// Whether a frame that landed is evidence of anything at all about the application that owns it.
    ///
    /// The two learning paths that are not probes — a snap that lands larger than its zone, a handle
    /// release that lands larger than the divider asked for — both infer *"the application refused, so
    /// its floor is at least this"* from a frame read back after a write. That inference has the same
    /// hole the probe has: a frame read before the application has applied the write is the frame it
    /// had **before**, which reads as a total refusal.
    ///
    /// A frame that differs from the one the window came in with is proof the write was applied, and
    /// then a size larger than the one asked for really is a refusal. A frame identical to the one it
    /// came in with proves nothing either way, so nothing is learned from it. In practice a snap and a
    /// divider release both move the window's origin as well as its size, so a real refusal still
    /// passes this test on its position alone; what it excludes is the frame where *nothing* happened.
    public static func landingIsEvidence(landed: CGRect, before: CGRect) -> Bool {
        abs(Double(landed.minX) - Double(before.minX)) > settleTolerance
            || abs(Double(landed.minY) - Double(before.minY)) > settleTolerance
            || abs(Double(landed.width) - Double(before.width)) > settleTolerance
            || abs(Double(landed.height) - Double(before.height)) > settleTolerance
    }

    /// The floor a landing reveals, per axis, and **0 on an axis that reveals none** — which is what
    /// `MinimumSizeStore.refused` reads as "this landing says nothing about this axis".
    ///
    /// A size that came back larger than it was asked for is a floor only past
    /// `HandleDragMath.roundingAllowance`: an application that rounds its own frame — a terminal
    /// standing on whole character cells — lands up to half a cell above an arbitrary ask, and that
    /// landing is the size it is *at*, not the size it stops at. Stored as a floor it would hold every
    /// window of the application at that size until one was seen smaller. **Every path that learns
    /// from a landing asks this**, so there is one allowance and not one per gesture.
    public static func revealedFloor(landed: CGSize, asked: CGSize) -> CGSize {
        let allowance = HandleDragMath.roundingAllowance
        return CGSize(
            width: Double(landed.width) > Double(asked.width) + allowance ? landed.width : 0,
            height: Double(landed.height) > Double(asked.height) + allowance ? landed.height : 0)
    }
}

/// What one window has shown it will not go below **beyond its application's row**: a raise per
/// axis, in memory, for the life of the window. Learned from a refusal — a landing larger than asked
/// — and from a probe that read higher than the row; lowered by every observation of the window
/// smaller than it; never persisted, because its key means nothing after the window closes.
///
/// **An axis is optional, and nil is not zero.** Nil means *nothing has raised this axis*, which reads
/// as 0 when the floor is asked for as a size and lets the row alone decide; zero would be a claim.
public struct WindowFloor: Hashable, Sendable {
    public var width: Double?
    public var height: Double?

    public init(width: Double? = nil, height: Double? = nil) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width == nil && height == nil }

    /// The raise as a size, **0 on an axis nothing raised**.
    public var size: CGSize { CGSize(width: width ?? 0, height: height ?? 0) }

    /// Per axis the larger of what was there and `size`. An axis of `size` that is not positive says
    /// nothing about that axis and leaves it as it was.
    public func raised(by size: CGSize) -> WindowFloor {
        var result = self
        if size.width > 0 { result.width = max(result.width ?? 0, Double(size.width)) }
        if size.height > 0 { result.height = max(result.height ?? 0, Double(size.height)) }
        return result
    }

    /// Per axis lowered to `observed` where the window was seen smaller than its raise by more than
    /// `MinimumSizePolicy.observationTolerance`. An axis nothing raised stays nil.
    public func lowered(seeing observed: CGSize) -> WindowFloor {
        var result = self
        if let width, let lowered = MinimumSizePolicy.lowered(width, seeing: Double(observed.width)) {
            result.width = lowered
        }
        if let height, let lowered = MinimumSizePolicy.lowered(height, seeing: Double(observed.height)) {
            result.height = lowered
        }
        return result
    }
}
