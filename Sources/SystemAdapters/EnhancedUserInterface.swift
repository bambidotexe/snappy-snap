import ApplicationServices
import Foundation
import os

/// `AXEnhancedUserInterface`, the application attribute an assistive client turns on to ask for a richer
/// accessibility tree, and the one state in which a window write cannot be trusted.
///
/// **While it is on, writes that follow each other are lost.** AppKit then applies a position or size
/// written through Accessibility asynchronously: the call answers success in under a millisecond, and a
/// write that arrives while the previous one is still being applied is dropped. Measured on Chrome: a
/// size, a position and a size again asked for (200, 150, 900 × 650) left the window at its old origin
/// with a width of 752; a 20-step animation to the right half never left its starting origin. A write
/// on its own, a few hundred milliseconds after the last, still lands. With the attribute off around
/// each pass, the same writes take 4–18 ms and land to the point.
///
/// **Who turns it on.** VoiceOver, and any client that wants a web page's accessibility tree: Granola
/// turns it on in Chrome while a Google Meet is open, and turns it on again about every 0.56 s
/// whenever something has turned it off. An application keeps it until someone turns it off, so a
/// Chrome that has had a Meet open stays in this state after the tab is closed.
///
/// **So every write pass is made with it off** — read it, turn it off, write, turn it back on, the
/// bracket Rectangle and yabai use. Toggling costs about 0.1 ms each way on Chrome during a Meet, and
/// the read is one more round trip per pass for every application. The setter answers
/// `kAXErrorNotImplemented` on every application measured and applies anyway, so its answer is not
/// read; the attribute read after it is what is believed.
public enum EnhancedUserInterface {
    static let attribute = "AXEnhancedUserInterface"

    /// What one bracket found, for the log and the tests.
    enum Finding: Equatable {
        /// The attribute was off; the writes ran once and nothing was toggled.
        case off
        /// The application did not answer the read; the writes ran once, as if it were off.
        case unknown
        /// It was on: turned off for the writes and back on after them.
        case on
        /// It was on, and was turned on again by someone else while the writes ran, so they ran once
        /// more with it off.
        case onAgainDuringWrites
    }

    /// Runs `writes` with the enhanced user interface of application `pid` off, and puts it back on
    /// afterwards when it was on. `writes` may run twice (see `bracket`), so it must be a set of absolute
    /// writes, which window frames are. Off the main thread: it adds a round trip, and `WindowWriter`'s
    /// workers are where round trips are spent.
    public static func suspended<T>(for pid: pid_t, _ writes: () -> T) -> T {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AccessibilityWindows.messagingTimeout)
        let (result, finding) = bracket(
            read: { AX.bool(app, attribute) },
            set: { on in _ = AXUIElementSetAttributeValue(app, attribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) },
            writes)
        note(finding, pid: pid)
        return result
    }

    /// The rule, behind closures. Off or unanswered: the writes run once and the attribute is left
    /// alone, so the bracket is never the reason a write is skipped. On: turned off, the writes run, and
    /// the attribute is read again before it is put back. Read on again means another client turned it
    /// on while the writes ran and some of them may have been dropped, so they run once more with it
    /// off — once, because a client flipping it twice inside one pass would be flipping it every few
    /// milliseconds, and the next pass is the retry for that.
    static func bracket<T>(read: () -> Bool?, set: (Bool) -> Void, _ writes: () -> T) -> (T, Finding) {
        guard let on = read() else { return (writes(), .unknown) }
        guard on else { return (writes(), .off) }
        set(false)
        var result = writes()
        var finding = Finding.on
        if read() == true {
            set(false)
            result = writes()
            finding = .onAgainDuringWrites
        }
        set(true)
        return (result, finding)
    }

    // MARK: - The log

    private static let log = Logger(subsystem: "dev.rubens.SnappySnap", category: "app")

    /// The applications last seen with the attribute on, so the change is logged once and not on
    /// every pass.
    private static let seenOn = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    private static func note(_ finding: Finding, pid: pid_t) {
        switch finding {
        case .unknown:
            return
        case .off:
            if seenOn.withLock({ $0.remove(pid) }) != nil {
                log.info("application \(pid) has AXEnhancedUserInterface off again")
            }
        case .on, .onAgainDuringWrites:
            if seenOn.withLock({ $0.insert(pid).inserted }) {
                log.info("application \(pid) has AXEnhancedUserInterface on: its window writes are made with it off and it is put back after each pass")
            }
            if finding == .onAgainDuringWrites {
                log.debug("application \(pid) turned AXEnhancedUserInterface back on during a write pass; the pass was written again with it off")
            }
        }
    }
}
