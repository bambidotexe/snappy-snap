/// The snap bar's arming clock.
///
/// The bar does not appear the moment the pointer enters its arming region. The pointer has to stay
/// there for `Settings.Fixed.snapBarArmingDwell` first, so a drag that only crosses the region on its
/// way to the top edge — the gesture that maximises a window — never flashes the bar. Leaving the
/// region drops the clock; entering again starts a new one from zero, never resuming the old one.
///
/// This is the rule, not the clock: it says whether to start waiting, keep waiting, show or drop, and
/// the controller owns the timer that measures the wait and the panel the wait is for. Nothing here
/// touches the arming region itself — that is `SnapBarGeometry.isWithinArmingBand`, unchanged by the
/// dwell — or the test that keeps a bar up once it is.
public struct SnapBarArming: Equatable, Sendable {
    /// What the bar does on this event.
    public enum Step: Equatable, Sendable {
        /// Show the bar now, with no wait. A bar already up moves to the display under the pointer at
        /// once: the dwell is for a bar that is not there yet, and moving one is not summoning one.
        case showNow
        /// Nothing is pending for this display: start a clock. Nothing is drawn until it runs out.
        case startDwell
        /// A clock for this display is already running and keeps running, undisturbed. The pointer has
        /// moved within the region, which is not a reason to start over.
        case keepWaiting
        /// The pointer is outside the arming region: drop any clock in flight.
        case cancel
    }

    /// The display a clock is running for, nil when none is.
    public private(set) var pending: UInt32?

    public init() {}

    /// Advances the rule for one drag event. `armed` is `SnapBarGeometry.isWithinArmingBand` for the
    /// pointer on `displayID`; `barShown` is whether the bar is up on any display.
    public mutating func step(armed: Bool, displayID: UInt32, barShown: Bool) -> Step {
        guard armed else {
            pending = nil
            return .cancel
        }
        guard !barShown else {
            pending = nil
            return .showNow
        }
        guard pending != displayID else { return .keepWaiting }
        pending = displayID
        return .startDwell
    }

    /// A clock ran out. True when it is the clock still being waited on — the pointer has not since
    /// left the region or crossed to another display — and so the bar is to be shown. Drops the clock
    /// either way: a wait is only ever answered once.
    public mutating func elapsed(displayID: UInt32) -> Bool {
        defer { pending = nil }
        return pending == displayID
    }

    /// The drag ended, was interrupted, or the bar came down. Any clock in flight is dropped.
    public mutating func cancel() {
        pending = nil
    }
}
