import CoreGraphics

/// Gives the session's mouse stream the press and the release the window server kept for itself.
///
/// A window-move gesture the window server runs — fn held with a drag anywhere on a window — reaches
/// a session-level event tap as `leftMouseDragged` events alone: **the `leftMouseDown` and the
/// `leftMouseUp` never arrive**, while a tap at the device (HID) level sees all three (measured: 30
/// drags and no press at the session, press + 30 drags + release at the device, the window's origin
/// following the pointer throughout). A drag session that arms on a press therefore never arms.
///
/// The session stream stays the authority — it carries everything any event source posts at its
/// level — and the device stream only fills what is missing. One event has **the same timestamp at
/// both taps** (measured on three presses and three releases), which is what lets a press be claimed
/// whichever callback the run loop happens to service first.
public struct PressReconciler: Sendable {
    /// The device's press nobody has claimed yet.
    private var unclaimed: (point: CGPoint, timestamp: UInt64)?
    private var lastSessionDown: UInt64?
    private var lastDeliveredUp: UInt64?
    /// Whether the gesture in hand is one whose press the session never delivered, so its release
    /// will not be delivered either.
    private var swallowed = false

    public init() {}

    /// A press seen at the device level. Delivers nothing: the session usually follows with the same
    /// press, and only a drag that arrives first proves it did not.
    public mutating func deviceDown(at point: CGPoint, timestamp: UInt64) {
        swallowed = false
        guard timestamp != lastSessionDown else { return }
        unclaimed = (point, timestamp)
    }

    /// A press the session delivered. Always true — the session's own press is always delivered — and
    /// it claims the device's copy of it.
    public mutating func sessionDown(timestamp: UInt64) -> Bool {
        lastSessionDown = timestamp
        unclaimed = nil
        swallowed = false
        return true
    }

    /// A drag the session delivered. Answers the press to deliver **before** it, when the device saw
    /// one the session never did.
    public mutating func sessionDragged() -> CGPoint? {
        guard let press = unclaimed else { return nil }
        unclaimed = nil
        swallowed = true
        return press.point
    }

    /// A release seen at the device level. True when it has to be delivered from here, because the
    /// gesture is one the session will not end.
    public mutating func deviceUp(timestamp: UInt64) -> Bool {
        unclaimed = nil
        guard swallowed else { return false }
        swallowed = false
        lastDeliveredUp = timestamp
        return true
    }

    /// A release the session delivered. False only for the one the device level already delivered.
    public mutating func sessionUp(timestamp: UInt64) -> Bool {
        timestamp != lastDeliveredUp
    }
}
