import AppKit
import os
import SnapCore
import SystemAdapters

/// Asking an application what it will not shrink below — the one measurement both handle features
/// clamp their divider with, and the one place the question is asked.
///
/// **Why a probe exists at all.** Neither the pill nor the knob resizes anything while the divider
/// moves, so there is no write inside the gesture to read a refusal back from: the preview would
/// happily draw a window narrower than its application allows and the release would land it wider than
/// the preview showed. The minimum therefore has to arrive before the first `.dragged` event, from
/// `MinimumSizeStore` or, when the application has no row there, from the application itself.
///
/// The price is one visible blink of that window at the press, for the 30–50 ms this takes, and it is
/// paid **once per application**: the answer becomes the application's row, and an application with
/// a row is never probed outside the deck again. A window whose probe was not believed is not asked
/// again this session either (`MinimumSizeStore.wasProbed`), so an application that never answers
/// believably blinks each of its windows once rather than at every press.
///
/// **There is no periodic background sweep, and that is a decision rather than an omission.** Two
/// populations of unprobed windows are deliberately left unprobed:
///
/// - **Windows on another Space.** They are not in `WindowList.snapshot` at all — it asks for
///   `.optionOnScreenOnly` — so finding them would mean an Accessibility sweep of every running
///   application's `kAXWindowsAttribute` on every tick of a timer, which is the poll that costs when
///   idle this app does not make. On top of that, whether a size write to an off-Space window is
///   honoured, and whether it drags the window onto the current Space, is not established. An
///   unestablished write is not a write this app makes.
/// - **Windows completely covered on this Space.** These *are* enumerable, and a 1 × 1 shrink is
///   anchored at the top-left so the probed rect stays inside the covered one — genuinely invisible.
///   The objection is not visibility, it is that **a resize is not a side-effect-free operation**. A
///   terminal reflows its scrollback at 1 × 1 and does not unreflow it; an editor re-wraps; a web view
///   fires every responsive breakpoint it has. At a press the user has asked for a gesture and the
///   cost is attributable. Unattended, on a timer, on a window the user cannot see, the same write
///   becomes damage with nothing to blame it on — and no restore can undo it, so "restore the size"
///   is not the safety property that matters here.
///
/// **The press probe is the user's to switch off.** `Settings.probeMinimumSizes` gates it and
/// nothing else: off, a press clamps with `MinimumSizePolicy.floorWithoutProbing(stored:)` and no
/// window ever blinks under the pointer. The deck's probe is not gated, because its blink lands on a
/// card parked in a screen corner rather than where the user is looking.
///
/// So a window is probed at a press, and from the deck through `SnapAssistController.probeFromDeck`
/// — the same blink, spent at the one moment the app already has the user's windows off their
/// positions and the user's eye on a deck, bounded there by a budget of 4 windows.
///
/// `OversizeWatcher` does sweep the window list ten times a second, but it never *probes* from there —
/// it only lowers a saved size that the window standing in front of it has shown to be too high,
/// which costs the window nothing at all. Lowering unattended is safe in exactly the way resizing
/// unattended is not.
@MainActor
enum MinimumProbe {
    /// The minimum given to a window on an axis nobody knows — its application has no row, and the
    /// window has no floor of its own there. Deliberately generous: erring small lets the divider
    /// promise a size the application will refuse, which is the failure this whole mechanism exists to
    /// remove, and erring large only stops the divider a little early on a window that would have gone
    /// further.
    static let fallback = CGSize(width: 200, height: 150)

    /// How long a background probe waits for one of its two writes. Twice the 0.25 s per-element
    /// messaging timeout plus room for a queue behind it: long enough that any application answering at
    /// all makes it, short enough that a chain of probes cannot outlive the deck it is riding.
    static let backgroundDeadline: TimeInterval = 0.6

    /// How long a **background** probe waits before its confirming read, when the first read was not
    /// believable (see `MinimumSizePolicy.believableFloor`). It is spent on no thread — an
    /// `asyncAfter` between two flushes — and only on a window whose first read was already suspect,
    /// so the ordinary card costs nothing and the whole deck cannot lose more than
    /// `deckProbeBudget × backgroundSettle`.
    ///
    /// 120 ms: three or four display frames, enough for an application that defers its layout to a
    /// later run-loop turn (which is the whole failure this is here for) and far short of the
    /// `backgroundDeadline` the flush behind it carries.
    ///
    /// **The press path has no equivalent and must not grow one.** A sleep there would be a sleep on
    /// the run loop that serves the event tap, and the tap is disabled at about a second; what the
    /// press path spends instead is one more Accessibility round trip, which is a turn of the *target*
    /// application's run loop rather than of ours.
    static let backgroundSettle: TimeInterval = 0.12

    /// This window's floor, for this gesture, in the order `docs/functional.md` §6 gives:
    ///
    /// 1. the window is **observed** at its current size, which may lower its row and its own floor;
    /// 2. probing is off → no blink; the clamp is the larger of what is known and `unprobedFloor`,
    ///    per axis. The switch forbids the measurement, not the knowledge;
    /// 3. the application **has a row** → no probe, whatever the switch says; the clamp is the row
    ///    raised by the window's own floor;
    /// 4. this window **was probed this session** → no second blink; the clamp is its own floor where
    ///    it has one and `fallback` where it has not;
    /// 5. otherwise the one probe, whose answer becomes the application's row.
    static func minimum(of handle: WindowHandle, currentSize: CGSize, area: CGSize? = nil,
                        ax: AccessibilityWindows, store: MinimumSizeStore, log: Logger,
                        probingAllowed: Bool) -> CGSize {
        let name = HandleBarController.appKey(for: handle)
        let window = handle.windowID ?? 0
        logLowering(store.observe(handle, size: currentSize), window: window, size: currentSize, log: log)
        guard probingAllowed else {
            let floor = MinimumSizePolicy.floorWithoutProbing(stored: store.minimum(for: handle))
            log.info("""
                probing is off; clamping \(name, privacy: .public) at \
                \(floor.width, format: .fixed(precision: 0))×\(floor.height, format: .fixed(precision: 0)) \
                rather than blinking it
                """)
            return floor
        }
        if store.hasRow(for: handle.pid) {
            let floor = clamp(store.minimum(for: handle) ?? .zero)
            log.debug("""
                \(name, privacy: .public) has a row; window \(window) clamps at \
                \(floor.width, format: .fixed(precision: 0))×\(floor.height, format: .fixed(precision: 0)), no probe
                """)
            return floor
        }
        if store.wasProbed(handle) {
            let floor = clamp(store.minimum(for: handle) ?? .zero)
            log.info("""
                window \(window) of \(name, privacy: .public) was probed this session and its \
                application still has no row; clamping at \
                \(floor.width, format: .fixed(precision: 0))×\(floor.height, format: .fixed(precision: 0)) \
                rather than blinking it again
                """)
            return floor
        }
        return probe(handle, currentSize: currentSize, area: area, ax: ax, store: store, log: log)
    }

    /// One line per saved size an observation lowered, with the window's size and both numbers.
    /// Nothing when nothing moved — a look that changes nothing is the ordinary case and is silent.
    static func logLowering(_ seen: MinimumSizeStore.Observation, window: CGWindowID, size: CGSize,
                            log: Logger) {
        if let row = seen.row {
            log.info("""
                window \(window) is \(size.width, format: .fixed(precision: 0))×\
                \(size.height, format: .fixed(precision: 0)); the row for \
                \(seen.bundleID ?? "?", privacy: .public) lowered from \
                \(row.from.width, format: .fixed(precision: 0))×\(row.from.height, format: .fixed(precision: 0)) to \
                \(row.to.width, format: .fixed(precision: 0))×\(row.to.height, format: .fixed(precision: 0))
                """)
        }
        if let own = seen.windowFloor {
            log.info("""
                window \(window) is \(size.width, format: .fixed(precision: 0))×\
                \(size.height, format: .fixed(precision: 0)); its own floor lowered from \
                \(own.from.width, format: .fixed(precision: 0))×\(own.from.height, format: .fixed(precision: 0)) to \
                \(own.to.width, format: .fixed(precision: 0))×\(own.to.height, format: .fixed(precision: 0))
                """)
        }
    }

    /// The same question asked **off the main thread**, through `WindowWriter`, for a window the user
    /// is not looking at — the deck probe.
    ///
    /// Two posts and two flushes on the window's own pid queue: size 1 × 1 with a read-back, then the
    /// size it came in with. Nothing here reads Accessibility on the main thread, which is the writer's
    /// standing contract for a window with posts in flight.
    ///
    /// **A third flush when the first read is not believable.** A flush with nothing pending *is* a
    /// read, taken on the worker, so the confirming read costs the main thread a timer and nothing
    /// else — which is why this path can afford a real `backgroundSettle` pause where the press path
    /// can only afford another round trip. See `probe(_:currentSize:area:ax:store:log:)` for why a
    /// read-back is not believed on its own.
    ///
    /// **The probe is spent the moment the 1 × 1 is posted** (`MinimumSizeStore.markProbed`), whatever
    /// it reads back, so a card that never settles is not probed again this session.
    ///
    /// **The restore is unconditional.** It is posted whatever the first flush answered — landed, timed
    /// out, or cancelled — because the one thing a probe may never do is leave a window at the probed
    /// size. It is still not a guarantee on its own: a `cancel` from another subsystem can take the
    /// restore out of the mailbox before it runs, so the caller keeps its own net (see
    /// `SnapAssistController.restoreProbedSizes`) and `completion` is its cue to drop it.
    ///
    /// `frame` is where the window is **now** — the deck slot, not its home — because only the size is
    /// written and the origin has to stay exactly where the deck put it.
    static func probeInBackground(_ handle: WindowHandle, at frame: CGRect, area: CGSize? = nil,
                                  writer: WindowWriter, store: MinimumSizeStore, log: Logger,
                                  completion: @escaping @MainActor (CGSize?) -> Void) {
        let generation = writer.begin(handle, current: frame)
        writer.post(WindowWriter.Request(frame: CGRect(origin: frame.origin,
                                                       size: CGSize(width: 1, height: 1)),
                                         writePosition: false, writeSize: true, readBack: true),
                    to: handle)
        store.markProbed(handle)
        writer.flush(handle, deadline: backgroundDeadline) { outcome in
            let first = (outcome?.generation == generation) ? outcome?.landedSize : nil
            let believed = first.map {
                MinimumSizePolicy.believableFloor(readBack: $0, before: frame.size, area: area)
            }
            // The first read is believable on both axes: nothing to confirm, restore now. Either it is
            // not, and the application is answering — in which case it is worth one more read after a
            // pause — or there was no read at all, and a pause would buy nothing but time at 1 × 1.
            guard let first, let believed, believed != first else {
                finishBackground(handle, at: frame, floor: believed,
                                 writer: writer, store: store, log: log, completion: completion)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + backgroundSettle) {
                MainActor.assumeIsolated {
                    writer.flush(handle, deadline: backgroundDeadline) { confirming in
                        var floor = believed
                        if confirming?.generation == generation, let second = confirming?.landedSize {
                            floor = MinimumSizePolicy.believableFloor(
                                readBack: MinimumSizePolicy.settledFloor(first, second),
                                before: frame.size, area: area)
                        }
                        finishBackground(handle, at: frame, floor: floor,
                                         writer: writer, store: store, log: log, completion: completion)
                    }
                }
            }
        }
    }

    /// Records whatever the background probe ended up believing, puts the size back, and answers the
    /// caller. Split out only because the confirming read gives the probe two ways to reach it.
    private static func finishBackground(_ handle: WindowHandle, at frame: CGRect, floor: CGSize?,
                                         writer: WindowWriter, store: MinimumSizeStore, log: Logger,
                                         completion: @escaping @MainActor (CGSize?) -> Void) {
        let believed = floor ?? .zero
        let name = HandleBarController.appKey(for: handle)
        let window = handle.windowID ?? 0
        var learned: CGSize?
        switch store.recordProbe(believed, for: handle) {
        case .row(let row):
            learned = believed
            log.info("""
                probed minimum for \(name, privacy: .public) off screen: \
                \(believed.width, format: .fixed(precision: 0))×\(believed.height, format: .fixed(precision: 0)); \
                it is now the row for \(row.bundleID, privacy: .public)
                """)
        case .windowFloor(let own):
            learned = believed
            log.info("""
                probed minimum for \(name, privacy: .public) off screen: \
                \(believed.width, format: .fixed(precision: 0))×\(believed.height, format: .fixed(precision: 0)) \
                (0 = not believed); the row stands and window \(window)'s own floor is \
                \(own.width, format: .fixed(precision: 0))×\(own.height, format: .fixed(precision: 0))
                """)
        case .nothing:
            log.info("""
                minimum probe of window \(window) off screen was not settled enough to believe, or read \
                nothing above its row; nothing stored
                """)
        }
        writer.post(WindowWriter.Request(frame: frame, writePosition: false, writeSize: true), to: handle)
        writer.flush(handle, deadline: backgroundDeadline) { restored in
            if restored == nil || restored?.succeeded == false {
                log.error("""
                    the size restore after probing window \(window) did not confirm; \
                    the caller's net has to put it back
                    """)
            }
            completion(learned)
        }
    }

    /// Asks the application what it will not go below: set 1 × 1, read back the size the window
    /// actually took — which is its floor on **both** axes at once — and set the original size again.
    ///
    /// **Only the size is written.** A shrink is anchored at the window's top-left, so nothing here can
    /// meet macOS's position clamp and there is no origin to restore.
    ///
    /// **A read-back is not believed until the application has had a turn to settle into it.** An
    /// application that reflows its content on resize — a terminal re-wrapping its scrollback, and
    /// Terminal reports its size in *characters* precisely because it does — can answer a read taken
    /// straight after the write with the size it still had when the write arrived. Stored, that number
    /// freezes the window at whatever size it happened to have, and nothing inside this app can argue
    /// with it until the user resizes the window by hand: the divider stops there, so the window never
    /// gets small enough to show the row wrong.
    ///
    /// The evidence this asks for is **a second read**, and the second read is the point rather than
    /// the number it returns: an Accessibility read is a synchronous round trip served on the target
    /// application's own main thread, so asking twice hands that application another full turn of its
    /// run loop between the write and the answer we keep. `MinimumSizePolicy.settledFloor` then takes
    /// the smaller of the two, because a settling window is on its way *down* towards the 1 × 1 it was
    /// asked for.
    ///
    /// **The second read is only taken when the first is not believable**, so the ordinary probe still
    /// costs three round trips and 0.75 s worst case against a hung application — the press path's
    /// budget is unchanged for every window that answers properly. The fourth trip is spent only when
    /// the first answer was suspect, which by definition means the application *is* answering, so it
    /// is a few milliseconds rather than another timeout.
    ///
    /// What is stored is only what was believed, through `MinimumSizeStore.recordProbe`: both axes
    /// make the application's row, one axis the window's own floor on that axis, none nothing. The
    /// probe is spent the moment the 1 × 1 is written, whatever comes back. This gesture clamps with
    /// `fallback` on any axis that was not believed.
    private static func probe(_ handle: WindowHandle, currentSize: CGSize, area: CGSize?,
                              ax: AccessibilityWindows, store: MinimumSizeStore, log: Logger) -> CGSize {
        ax.setSize(CGSize(width: 1, height: 1), of: handle)
        store.markProbed(handle)
        let first = ax.size(of: handle)
        var floor = first.map {
            MinimumSizePolicy.believableFloor(readBack: $0, before: currentSize, area: area)
        }
        if let first, let believed = floor, believed != first, let second = ax.size(of: handle) {
            floor = MinimumSizePolicy.believableFloor(
                readBack: MinimumSizePolicy.settledFloor(first, second), before: currentSize, area: area)
        }
        ax.setSize(currentSize, of: handle)

        let believed = floor ?? .zero
        let name = HandleBarController.appKey(for: handle)
        let window = handle.windowID ?? 0
        switch store.recordProbe(believed, for: handle) {
        case .row(let row):
            log.info("""
                probed minimum for \(name, privacy: .public): \
                \(believed.width, format: .fixed(precision: 0))×\(believed.height, format: .fixed(precision: 0)); \
                it is now the row for \(row.bundleID, privacy: .public)
                """)
        case .windowFloor(let own):
            log.info("""
                probed minimum for \(name, privacy: .public): \
                \(believed.width, format: .fixed(precision: 0))×\(believed.height, format: .fixed(precision: 0)) \
                (0 = not settled enough to believe); half a measurement makes no row — it is the floor \
                of window \(window) alone, \
                \(own.width, format: .fixed(precision: 0))×\(own.height, format: .fixed(precision: 0))
                """)
        case .nothing:
            log.info("""
                minimum probe of window \(window) of \(name, privacy: .public) answered nothing this \
                gesture can use (\(String(describing: first), privacy: .public) against a \
                \(currentSize.width, format: .fixed(precision: 0))×\
                \(currentSize.height, format: .fixed(precision: 0)) window); nothing stored, and no \
                second blink this session
                """)
        }
        return clamp(store.minimum(for: handle) ?? .zero)
    }

    /// What this gesture clamps with: the floor on every axis something knows, and `fallback` on
    /// every axis nothing does. Erring small here is the cheap error — the application refuses the size
    /// and the release raises the window's own floor from the refusal — where erring large stops the
    /// divider before the window would have stopped.
    private static func clamp(_ floor: CGSize) -> CGSize {
        CGSize(width: floor.width > 0 ? floor.width : fallback.width,
               height: floor.height > 0 ? floor.height : fallback.height)
    }
}
