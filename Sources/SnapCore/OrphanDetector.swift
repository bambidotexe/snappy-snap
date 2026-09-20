import Foundation

/// When a handle drag has outlived its mouse button — and, more delicately, when it merely *looks*
/// as though it has.
///
/// **The problem the bare button test has.** `CGEventSource.buttonState(.combinedSessionState,
/// button: .left)` is one bit for the whole session, and it flips at the moment of the **physical**
/// release — several milliseconds before the session tap delivers `.up` to the app. Both the handle
/// features' 10 Hz `Timer` and the tap's `CFMachPort` live on the main run loop, and `CFRunLoop` fires
/// due timers *before* version-1 (mach port) sources in the same iteration, so a tick landing in that
/// window does not merely tie the race — it wins it. The drag is then orphaned instead of released:
/// the forced pass at mouse-up never posts, the windows keep the last posted frames, an error-level
/// line claims a lost mouse-up that was not lost, and the `.up` travels on to whatever is behind the
/// handle. That is an ordinary release, ruined, roughly once every (tap latency ÷ poll interval)
/// drags.
///
/// **The rule.** Cancel only on evidence the mouse-up is *lost*, never merely that the button is up.
/// Two things have to hold at once:
///
/// - the button has read up on **two consecutive polls** — one tick is the race above, two is 100 ms
///   of a button that is not coming back;
/// - and **no mouse event has arrived for this drag** within the last poll — a `.dragged` a moment ago
///   means the stream is alive and the `.up` is on its way behind it.
///
/// Neither weakens the case the watchdog exists for. A Space change, a Mission Control gesture or a
/// tap the window server disabled swallows the event for far longer than two polls, so the genuine
/// orphan is still caught — 200 ms later than a bare button test would, with nothing written in the
/// meantime because an orphan writes nothing anyway.
///
/// A `.up` that does arrive always wins: it ends the drag through the ordinary path before the next
/// tick can run, which is why this rule never has to reason about it.
public enum OrphanDetector {
    /// How many consecutive polls must read the button up. Two, because one is the physical-release
    /// race and there is nothing between one and two to choose from.
    public static let confirmingTicks = 2

    /// How long the mouse stream must have been silent. One poll of the handle features — the callers
    /// pass their own interval, and this is what that is today.
    public static let quietPeriod: Double = 0.1

    /// Whether this poll should orphan the drag.
    ///
    /// - `buttonUp`: what the window server says right now.
    /// - `ticksUp`: consecutive polls that have read the button up, **including this one**. The caller
    ///   resets it to zero on any poll that reads the button down; that is what makes "consecutive"
    ///   true rather than "two since the drag began".
    /// - `lastEventAt`: when this drag last saw a mouse event — the press, then every `.dragged`.
    /// - `now`: this poll's clock reading, on the same clock as `lastEventAt`.
    /// - `quietFor`: how long that silence must have lasted.
    public static func shouldCancel(buttonUp: Bool, ticksUp: Int, lastEventAt: Double, now: Double,
                                    quietFor: Double = quietPeriod) -> Bool {
        guard buttonUp, ticksUp >= confirmingTicks else { return false }
        return now - lastEventAt >= quietFor
    }
}
