import os

extension Logger {
    static let app = Logger(subsystem: "dev.rubens.SnappySnap", category: "app")
    static let drag = Logger(subsystem: "dev.rubens.SnappySnap", category: "drag")
    static let assist = Logger(subsystem: "dev.rubens.SnappySnap", category: "assist")
    static let handle = Logger(subsystem: "dev.rubens.SnappySnap", category: "handle")
    /// The junction knob. A category of its own rather than `handle`'s: the two features share their
    /// machinery but not their cost, and a measurement of one must not read the other's lines.
    static let junction = Logger(subsystem: "dev.rubens.SnappySnap", category: "junction")
    /// The Snap Assist deck. Separate from `assist` for the same reason `junction` is separate from
    /// `handle`: the deck's cost is what a measurement of this feature is after, and it must not have
    /// to be sifted out of the choosing phase's own lines.
    static let deck = Logger(subsystem: "dev.rubens.SnappySnap", category: "deck")
    /// The update feature: every check, what it found, the fetch, the unpacking and the hand-over to the
    /// install helper, at `notice` so that `log show` keeps them.
    static let update = Logger(subsystem: "dev.rubens.SnappySnap", category: "update")
}
