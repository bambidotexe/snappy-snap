import AppKit
import os
import QuartzCore
import SnapCore

/// A 1 × 1 panel whose only job is to be **displaced when the Space slides**.
///
/// Measured: a sentinel at a display's leading edge loses visibility **27–53 ms** after a slide
/// begins (the trailing edge at 439–472 ms) against 972–1007 ms for
/// `activeSpaceDidChangeNotification`. The occlusion notification is the alarm; one window-list read
/// in the same turn is the confirmation, because a *menu* covering the same point occludes it too and
/// only a slide moves it.
///
/// **This is deliberately not an `OverlayPanel`, and the difference is the whole mechanism.** Every
/// other surface in this app is `.moveToActiveSpace` so that it leaves with the Space rather than
/// riding along to the next one. A sentinel must be the opposite: **Space-bound**, with neither
/// `.canJoinAllSpaces` nor `.moveToActiveSpace`, because a panel that follows the user is never
/// displaced and would report nothing, for ever, silently. (It could not inherit from `OverlayPanel`
/// in any case — that type lives in the app target and this one in the adapters — but the rule is
/// written here because the cost of getting it wrong is a feature that fails without a symptom.)
///
/// At `.statusBar` level for a second reason of the same kind: a sentinel spends its life *visible*,
/// so a slide is a change of occlusion rather than one more occluded window staying occluded. A
/// normal-level 1 × 1 panel behind a maximized window is already unoccludable and would post nothing
/// when the Space moved it. It sits above Mission Control's backdrop (CG layer 19) too, so entering
/// Mission Control is not mistaken for a slide even before the displacement test.
@MainActor
final class SpaceSentinelPanel: NSPanel {
    /// **Unverified on hardware**: nothing measures whether a near-zero alpha still receives
    /// occlusion changes — that needs a running app and a Space switch. The conservative reading of
    /// "smallest alpha that works" is therefore *small but not zero* — AppKit is documented to treat a
    /// fully transparent window as contributing nothing, and a window that contributes nothing has no
    /// occlusion to change.
    /// 5 % of black over one point at the extreme edge of a display is not visible; if it ever is, it
    /// can go down, and if occlusion stops arriving it has to go up.
    static let alpha: CGFloat = 0.05

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .black
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        // Space-bound: see the class comment. `.stationary` is deliberately *absent* — being moved is
        // the signal. `.ignoresCycle` keeps it out of window cycling; nothing else is wanted.
        collectionBehavior = [.ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        alphaValue = Self.alpha
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The two ways the system takes the user away from the arrangement every surface of this app is
/// about, reported as one thing (`SpaceInterruption`).
///
/// **They are not the same kind of signal, and the difference is measured, not assumed.**
///
/// - **Mission Control** posts nothing at all — see `MissionControlDetector` for the list of observers
///   that were registered at once and stayed silent. The window list is the only place it shows, so
///   this polls for it. Its backdrop is up **26–57 ms** after the gesture, so the poll rate is the
///   only thing that can make the reading late. It polls at **60 Hz while anything is live** — a
///   `CGWindowListCopyWindowInfo` is 0.250 ms for 17 windows, so 60 of them is about 1.5 % of one
///   core — and drops back to 10 Hz the moment nothing would be interrupted. Idle, which is
///   nearly all the time, is four boolean reads on a 10 Hz timer and no window list at all.
/// - **A Space change** posts `NSWorkspace.activeSpaceDidChangeNotification`, which is free, exact and
///   covers full-screen apps entering and leaving as well — but arrives at **972–1007 ms**, at the end
///   of the slide rather than the start of it. It stays as the backstop and as the only signal for a
///   full-screen transition. Ahead of it are two `SpaceSentinelPanel`s per display, watched for
///   occlusion and confirmed with one window-list read: **27–53 ms** on the leading edge.
///
/// **Exactly one `.spaceChange` per change, across both routes.** The sentinel route beats the
/// notification by most of a second, so the notification for the very slide the sentinels already
/// reported would otherwise arrive as a second interruption — and the fan-out it drives cancels
/// gestures and restores parked windows. `spaceChangeCoalescing` is what makes the two routes one.
@MainActor
public final class SpaceWatcher {
    /// Nothing is live: four boolean reads, no window list. The handle bar's own cadence.
    public static let idlePollInterval: TimeInterval = 0.1
    /// Something is live, or Mission Control is already up.
    public static let livePollInterval: TimeInterval = 1.0 / 60

    /// How long after one route has reported a Space change the other is not believed. It has to
    /// cover the gap between the sentinel (27–53 ms) and the notification (972–1007 ms) with room for
    /// a slow machine, and no more: two genuine Space changes inside it would be reported as one.
    /// That is the harmless direction — everything this app had on screen went with the first.
    public static let spaceChangeCoalescing: TimeInterval = 1.5

    /// Called on the main actor when the user has left. Fires **once** per interruption: Mission
    /// Control is made so by `MissionControlGate`, a Space change by `spaceChangeCoalescing`.
    public var onInterruption: (@MainActor (SpaceInterruption) -> Void)?

    /// Whether anything would be interrupted right now. The poll's whole cost, the 60 Hz rate and the
    /// sentinels are all behind this.
    private let isLive: @MainActor () -> Bool

    /// Display frames in CG space, read afresh each pass: a display change is somebody else's
    /// interruption and this must not hold a stale list across one.
    private let displays: @MainActor () -> [CGRect]

    /// Whether Mission Control (or App Exposé) is on screen **as of the last pass**, for the features
    /// that must stand down for as long as it is rather than be cancelled once.
    ///
    /// The handle bar is why this is a level and not only an edge. Its pill is re-offered on its own
    /// 10 Hz poll, from a window list whose entries, inside Mission Control, are the scaled thumbnails
    /// — so a single cancellation would be undone a tenth of a second later by a pill drawn between
    /// two pictures of windows. It stands down on this instead, and comes back when it goes false.
    ///
    /// This is also what makes the polling condition safe. `tick` polls while `isLive` **or** while
    /// this is true, so suspending the very features that made it live cannot switch the poll off and
    /// leave the suspension latched — which would be an oscillation, or a pill that never came back.
    public var isMissionControlShowing: Bool { gate.isShowing }

    /// The re-entry grace: ~150 ms after Mission Control's falling edge before a pill or a knob may
    /// be offered again. The backdrop leaves 332 ms after the exit keystroke and the Spaces
    /// bar at 466, but the windows are still growing back for about 300 ms after that, and a handle
    /// offered inside that window is drawn at a gap that is about to stop existing.
    public func isInReofferGrace(now: TimeInterval) -> Bool { gate.isInGrace(now: now) }

    /// Whether this is watching at all: started and not stopped. The Health page's answer to "does the
    /// app stand down when the screen changes under a gesture".
    public var isWatching: Bool { timer != nil }

    private var gate = MissionControlGate()
    private var spaceObserver: (any NSObjectProtocol)?
    private var occlusionObservers: [any NSObjectProtocol] = []
    private var timer: Timer?
    private var timerInterval: TimeInterval = SpaceWatcher.idlePollInterval
    private var windowManagerPID: Int32?
    private var sentinels: [Sentinel] = []
    private var lastSpaceChangeAt: TimeInterval?
    /// When the gate last rose, so the falling log line can say how long it was up.
    private var missionControlSince: TimeInterval?

    private static let log = Logger(subsystem: "dev.rubens.SnappySnap", category: "app")

    /// One sentinel: its panel, the window number the window list knows it by, the CG frame it was
    /// placed at, and which edge of which display it is — the last only so the log line can say.
    private struct Sentinel {
        let panel: SpaceSentinelPanel
        let id: UInt32
        let placed: CGRect
        let edge: String
    }

    public init(isLive: @escaping @MainActor () -> Bool, displays: @escaping @MainActor () -> [CGRect]) {
        self.isLive = isLive
        self.displays = displays
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard timer == nil else { return }
        // `NSWorkspace`'s own centre, not the default one: the Space notification is posted there and
        // nowhere else.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        schedule(interval: Self.idlePollInterval)
    }

    /// Stops watching. The gate is re-armed with it: a watcher that is not looking must not go on
    /// telling the handle bar to stand down for a Mission Control it can no longer see end. The
    /// sentinels come down with it, for the same reason and one more — they are panels on the user's
    /// screen, and a stopped watcher owns nothing there.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        lowerSentinels()
        gate.forget()
        missionControlSince = nil
    }

    // MARK: - The poll

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so the poll keeps running while a menu is tracking or a window is being resized:
        // those are precisely the moments a gesture is live and something may cover the screen.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One pass. Internal rather than private so a test or a probe can drive it without a run loop.
    ///
    /// The poll runs while there is something to interrupt **or** while Mission Control is already up.
    /// The second half is not redundant: the features that made it live are the ones that stand down
    /// for it, so without it they would switch off the only thing that can tell them when to come
    /// back. Idle costs `isLive`'s boolean reads, one comparison for the rate and one for the
    /// sentinels, and nothing else — no window list.
    func tick() {
        let live = isLive()
        // Both of these are a comparison against a stored flag on every other pass, which is what
        // keeps the idle path at "four boolean reads" as costed.
        setSentinels(up: live)
        setRate(live: live || gate.isShowing)
        guard live || gate.isShowing else { return }
        // A pid this cannot resolve is a Mission Control this cannot see, and that is a reading of
        // **false**, not a pass. Returning early here would have latched the gate for the rest of the
        // session the one time WindowManager was restarted mid-phase — the poll would go on running,
        // `isMissionControlShowing` would stay true, and the handle bar and the junction knobs would
        // never be offered again. Every other way this pass can come up empty — no surfaces, no
        // displays — already falls through to the same reading of false.
        let displays = displays()
        var backdrop: (window: SystemWindow, display: Int)?
        if let pid = resolvedWindowManagerPID() {
            backdrop = MissionControlDetector.backdrop(in: WindowList.onScreenSurfaces(),
                                                       windowManagerPID: pid, displays: displays)
        }
        let showing = backdrop != nil
        let now = CACurrentMediaTime()
        let wasShowing = gate.isShowing
        let rose = gate.update(showing: showing, now: now)
        // Logged on change only — never per tick, which at 60 Hz would be 60 lines a second.
        if rose, let backdrop {
            missionControlSince = now
            Self.log.info("""
                mission control gate up: pid \(backdrop.window.ownerPID, privacy: .public) \
                layer \(backdrop.window.layer, privacy: .public) \
                \(NSStringFromRect(backdrop.window.frame), privacy: .public) \
                covers display \(backdrop.display, privacy: .public)
                """)
        } else if wasShowing && !showing {
            let held = now - (missionControlSince ?? now)
            missionControlSince = nil
            Self.log.info("mission control gate down after \(held, format: .fixed(precision: 2), privacy: .public)s")
        }
        guard rose else { return }
        onInterruption?(.missionControl)
    }

    private func setRate(live: Bool) {
        let wanted = live ? Self.livePollInterval : Self.idlePollInterval
        guard timer != nil, wanted != timerInterval else { return }
        schedule(interval: wanted)
    }

    /// The WindowManager process, cached until it is not that process any more. It is resolved by
    /// bundle identifier because CGWindowList's owner names are localized (`MissionControlDetector`),
    /// and re-resolved if it has gone: WindowManager is restartable, and a stale pid would make this
    /// feature quietly stop working rather than fail.
    private func resolvedWindowManagerPID() -> Int32? {
        if let pid = windowManagerPID, NSRunningApplication(processIdentifier: pid) != nil { return pid }
        windowManagerPID = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.WindowManager" }?
            .processIdentifier
        return windowManagerPID
    }

    // MARK: - The sentinels

    private func setSentinels(up: Bool) {
        if up {
            guard sentinels.isEmpty else { return }
            raiseSentinels()
        } else {
            guard !sentinels.isEmpty else { return }
            lowerSentinels()
        }
    }

    /// Two per display, at the vertical middle of the leading and trailing edges — the two points a
    /// horizontal slide reaches first and last (27–53 ms and 439–472 ms measured). Up only while
    /// something is live: they are windows on the user's screen, and an idle app owns none.
    private func raiseSentinels() {
        let displays = displays()
        for (index, display) in displays.enumerated() {
            for (edge, x) in [("leading", display.minX), ("trailing", display.maxX - 1)] {
                let placed = CGRect(x: x, y: display.midY - 0.5, width: 1, height: 1)
                let panel = SpaceSentinelPanel()
                panel.setFrame(CoordinateSpace.cocoaRect(fromCG: placed), display: false)
                panel.orderFrontRegardless()
                let name = displays.count > 1 ? "\(edge) of display \(index)" : edge
                let sentinel = Sentinel(panel: panel, id: UInt32(bitPattern: Int32(panel.windowNumber)),
                                        placed: placed, edge: name)
                sentinels.append(sentinel)
                occlusionObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sentinelOcclusionChanged(sentinel) }
                })
            }
        }
    }

    private func lowerSentinels() {
        for observer in occlusionObservers { NotificationCenter.default.removeObserver(observer) }
        occlusionObservers = []
        for sentinel in sentinels { sentinel.panel.orderOut(nil) }
        sentinels = []
    }

    /// The alarm. One window-list read confirms it or does not: a slide **displaces** the sentinel, a
    /// menu or a window covering that one point does not. Nothing else is done with the
    /// occlusion state itself — going *back* to visible is the user returning, and the sentinel is
    /// then exactly where it was put, so `isSliding` answers false and this costs one read.
    private func sentinelOcclusionChanged(_ sentinel: Sentinel) {
        let began = CACurrentMediaTime()
        guard sentinels.contains(where: { $0.id == sentinel.id }) else { return }
        guard SpaceSlideDetector.isSliding(sentinelID: sentinel.id, placed: sentinel.placed,
                                           listed: WindowList.onScreenIDsAndFrames()) else { return }
        report(.spaceChange, via: "sentinel at \(sentinel.edge)",
               after: (CACurrentMediaTime() - began) * 1000)
    }

    /// The backstop, and the only signal a full-screen app entering or leaving gives at all. It is
    /// suppressed when the sentinels have already reported this same slide — see
    /// `spaceChangeCoalescing`.
    private func spaceChanged() {
        report(.spaceChange, via: "notification", after: nil)
    }

    /// Exactly once per change, whichever route saw it first.
    private func report(_ interruption: SpaceInterruption, via route: String, after ms: Double?) {
        let now = CACurrentMediaTime()
        if let last = lastSpaceChangeAt, now - last < Self.spaceChangeCoalescing { return }
        lastSpaceChangeAt = now
        if let ms {
            Self.log.info("space change detected via \(route, privacy: .public) (\(ms, format: .fixed(precision: 1), privacy: .public) ms after occlusion)")
        } else {
            Self.log.info("space change detected via \(route, privacy: .public)")
        }
        // The sentinels belong to the Space the user has just left and are no use on the one they are
        // arriving at — a `setSentinels(up: true)` that found a non-empty list would keep them there
        // for the rest of the session and this feature would silently stop working. Dropped here; the
        // next pass that finds something live plants a fresh pair on the Space that is now showing.
        lowerSentinels()
        onInterruption?(interruption)
    }
}
