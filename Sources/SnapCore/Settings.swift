import Foundation

/// How often the Snap Assist deck computes and posts a target frame, read through `PostRate`: the
/// display's own refresh rate, 60 a second, or 30, never above what the display can do. The deck is
/// the only subsystem it governs — the snap engine posts at the display link's own rate. The writes
/// themselves are paced by `WindowWriter`'s per-window mailbox, where a post to a busy window replaces
/// the pending frame and the worker's own write is the back-pressure.
///
/// The raw values are persisted in the user's settings file.
public enum Smoothness: String, Codable, Hashable, Sendable, CaseIterable {
    /// Aim at the display's own refresh rate.
    case smooth
    /// Aim at 60 posts a second, whatever the display can do. Titled "Balanced" in Settings.
    case adaptive
    /// Aim at 30 posts a second.
    case battery

    /// The segment's label in Settings, where the three are one segmented control.
    public var title: String {
        switch self {
        case .smooth: L("Smooth")
        case .adaptive: L("Balanced")
        case .battery: L("Battery")
        }
    }
}

/// Where the snap bar is drawn. The raw values are persisted in the user's settings file.
public enum SnapBarAppearance: String, Codable, Hashable, Sendable, CaseIterable {
    /// Inside a black shape that grows out of the display's camera housing — or, on a display that
    /// has none, in an island that floats under the top edge.
    case notch
    /// A floating bar that slides down below the menu bar, on every display.
    case bar
    /// The black shape on a display that has a camera housing, the floating bar on every other.
    case notchOrBar

    public var title: String {
        switch self {
        case .notch: L("Notch or island")
        case .bar: L("Floating bar")
        case .notchOrBar: L("Notch or floating bar")
        }
    }

    /// The hint under the Style group in Settings while this option is the selected one. Here beside
    /// the titles because the two are read together: a label and its explanation in different targets
    /// is how they drift apart.
    public var detail: String {
        switch self {
        case .notch:
            L("On a Mac with a notch, the bar grows out of the notch, and the rest of the top edge still fills the screen. A display without a notch shows a small island under its top edge while you drag, and the bar grows out of that.")
        case .bar:
            L("A bar slides down below the menu bar when you drag a window to the top of the screen. It looks the same on every display.")
        case .notchOrBar:
            L("The bar grows out of the notch on a Mac that has one. Every other display gets the floating bar.")
        }
    }

    /// What this choice comes to on one display. The camera housing decides, display by display, so
    /// one drag can meet two surfaces.
    public func surface(on display: DisplayInfo) -> SnapBarSurface {
        surface(withHousing: display.housing != nil)
    }

    /// The same rule for a display known only by whether it has a camera housing, which is all the
    /// Settings window's pictures of a MacBook and of an external display know about theirs.
    public func surface(withHousing hasHousing: Bool) -> SnapBarSurface {
        switch self {
        case .notch: hasHousing ? .notchShape : .island
        case .bar: .floatingBar
        case .notchOrBar: hasHousing ? .notchShape : .floatingBar
        }
    }
}

/// What the snap bar is drawn as on one display.
public enum SnapBarSurface: Hashable, Sendable {
    /// The Liquid Glass bar below the menu bar.
    case floatingBar
    /// The black shape that grows out of the camera housing.
    case notchShape
    /// The black island that floats under the top edge of a display with no housing.
    case island
}

/// The user's choices — and **only** the choices.
///
/// Every stored property here is a control in the Settings window and a key in the settings file.
/// Everything else is in `Settings.Fixed`: a constant in code, reachable by editing one line and by
/// nothing else — in particular not by `defaults write`.
///
/// The constants are read as `settings.gap`, `settings.animationDuration` and so on, so there is one
/// name for each quantity and no call site has to know which kind it is. They are computed properties,
/// which is also what keeps them out of `Codable`'s synthesis: nothing writes them to the file, and a
/// file that holds a key for one of them simply has it ignored.
public struct Settings: Codable, Hashable, Sendable {

    /// The constants. One line each, with what it does written beside it — changing one is a
    /// one-line edit here, and promoting one back into the struct above is the same line moved.
    public enum Fixed {
        /// How far from a corner the pointer counts as being in that corner's zone.
        public static let cornerBand: Double = 120
        /// How close to an edge the pointer has to come for that edge's zone to arm.
        public static let edgeBand: Double = 24
        /// The same for an edge shared with another display. Twice as forgiving: that edge is aimed at
        /// from a display the pointer can overshoot into, rather than from the dead end an outer edge is.
        public static let sharedEdgeBand: Double = edgeBand * 2
        /// How long a window takes to animate to a zone it was snapped to.
        public static let animationDuration: Double = 0.25
        /// How long the pointer must hold the snap bar's arming region before the bar is shown, so a
        /// drag that only crosses it on the way to the top edge never flashes the bar. Fitted by hand:
        /// 0.150 read as a lag on a deliberate summon, 0.100 let a fast pass through.
        public static let snapBarArmingDwell: Double = 0.125
        /// How far apart two windows' facing edges may be and still be offered a handle between them.
        public static let handleMaxGap: Double = 16
        /// How much two windows must overlap along their shared edge to be offered a handle.
        public static let handleMinOverlap: Double = 60
        /// How many windows the Snap Assist deck will animate. Above it the overflow is placed with
        /// no animation, because a deck that stutters is worse than one that does not play.
        public static let deckCeiling: Int = 20
        /// Whether a snap takes the space an adjacent snapped window leaves free rather than its
        /// nominal cell — Windows' own `SnapFill`, on by default there since Windows 10.
        public static let snapFill = true
        /// The gap, when the user has the gap switched on: what a snapped window leaves between
        /// itself and the screen edge, and half of what it leaves between itself and its neighbour.
        /// Off, the gap is 0 — see `Settings.gap`, which is the only thing that reads this.
        public static let gap: Double = 8
        /// How long after a Space change before a drag the user is still holding may come back. The
        /// slide runs on for about 450 ms after it is detected, and a window list read taken during
        /// it describes the Space being left rather than the one arriving.
        public static let dragResumeSettle: Double = 0.6
        /// How far the pointer must travel from where a Space change found it before the resumed
        /// drag presents anything. It is still resting against the edge that triggered the slide,
        /// and a zone lit under a motionless hand is one the user never aimed at.
        public static let dragResumeTravel: Double = 8
        /// How close a custom area's side must come to the working area's own edge to count as lying
        /// on it, and so to be inset by a whole gap rather than half of one.
        public static let customAreaEdgeTolerance: Double = 0.5
        /// How closely a `screenResolution:` selector must match the display's frame, on each side,
        /// for that key to claim the display.
        public static let customAreaResolutionTolerance: Double = 0.5
        /// How long the update check waits for GitHub before it gives up. The check is a button
        /// press with a status line under it, so a wait long enough to cross a slow network is
        /// cheaper than an answer that gives up while the reply is still coming.
        public static let updateCheckTimeout: TimeInterval = 15
        /// How long after launch the app first asks GitHub on its own: long enough for a Mac that
        /// starts the app at login to have found its network.
        public static let updateLaunchDelay: TimeInterval = 10
        /// How long after the last check that got an answer the app asks again on its own.
        public static let updateInterval: TimeInterval = 7 * 24 * 3600
        /// How long after a check that could not reach GitHub the app tries again.
        public static let updateRetryDelay: TimeInterval = 3600
        /// How often the app asks whether a check is due. One week-long timer would sleep through
        /// its date with the Mac. With a tick shorter than `updateRetryDelay`, a retry comes at the
        /// first tick once that delay has passed: 60 to 90 minutes after the failure.
        public static let updateTick: TimeInterval = 1800
        /// Seconds after the click on Install and Relaunch at which an app that is still running
        /// stops the install helper and says it did not quit. One clock decides: the helper's own
        /// limit, `updateQuitWait`, is longer and only ever serves an app too hung to do that.
        public static let updateStallNotice: TimeInterval = 20
        /// The install helper's three waits, in seconds: for the app to quit before it gives up,
        /// untouched; for the new version to show among the running processes; and how long after
        /// that it is looked for once more.
        public static let updateQuitWait = 30
        public static let updateLaunchWait = 15
        public static let updateSettle = 2
        /// How long the outcome of an install is news. A line found later than that was left behind
        /// by an install nobody is waiting on any more, and opens no window.
        public static let updateResultShelfLife: TimeInterval = 600
        /// How far back the Health page counts crash reports. A week covers the gap between two weekly
        /// update checks, and a crash older than that has either been fixed by a release or been seen
        /// again since.
        public static let healthCrashWindow: TimeInterval = 7 * 24 * 60 * 60
        /// The shortest time the Health page's overview reads *Checking* after Check Again. Most checks
        /// answer in a few milliseconds, and a mark that changes back before it can be seen reads as a
        /// button that did nothing; half a second is seen and does not keep anyone waiting.
        public static let healthMinimumBusy: TimeInterval = 0.5
    }

    // MARK: - Stored: the user's choices

    // Snapping
    public var sideHalves = true
    public var optionHalves = false
    public var corners = true
    public var topFill = true
    public var snapBar = true
    public var snapBarAppearance: SnapBarAppearance = .notch
    public var snapAssist = true
    /// Whether the trackpad taps once at the instant the snap bar appears — on any surface — after
    /// its arming dwell. **On by default**: the dwell already means the bar is never summoned by
    /// accident, so the tap only ever confirms something the user was reaching for. Off, nothing is
    /// felt and the bar is unchanged. The pattern is `SystemAdapters.Haptics`' to choose; an AppKit
    /// value cannot live in this target.
    ///
    /// A Mac with no Force Touch trackpad has no actuator, so the switch is on and felt by nobody
    /// there. That is not worth hiding the control for: there is no way to ask macOS whether a tap
    /// landed, and a row that disappears on some Macs is harder to explain than one that does nothing.
    public var hapticFeedback = true
    /// Whether holding Command during a window drag offers the custom areas instead of the ordinary
    /// zones. **On by default**: the switch is here for a user who wants Command to keep its one
    /// other meaning — uncovering a window's resize edge — and nothing else. Off, Command changes
    /// nothing about a drag and the areas are never drawn, whatever the JSON holds.
    public var customAreas = true
    // Layout
    /// The gap is a switch, not a number. On, windows keep `Fixed.gap` from the screen edges and from
    /// each other; off, they touch. The **size** of the gap is a code constant on purpose, so the only
    /// thing persisted here — and the only thing a settings file can say about the gap — is on or off.
    public var gapEnabled = true
    /// Whether a window that outgrows the space the gap leaves is brought back inside it. **On by
    /// default**, because it is what makes one arrangement have one kind of edge in it: macOS's own
    /// zoom, a title-bar double-click and its tiling gestures all place a window flush against the
    /// working area, and this is how it ends up where SnappySnap would have put it. Off, those windows
    /// are left exactly where the system put them.
    ///
    /// Read only while `gapEnabled` is on — with no gap there is nothing for a window to outgrow —
    /// so the two switches read together, and this one is shown beneath it.
    public var correctOversizedWindows = true
    public var restoreOnDragAway = false
    // Motion
    public var smoothness: Smoothness = .adaptive
    // Handles
    public var handleBar = true
    /// Whether pressing a pill or a knob may probe a window's minimum size — the write-1×1,
    /// read-back, write-back-original that costs one visible blink. **Default on**, because that
    /// blink is what lets the divider stop exactly where the window stops. Off, a press never
    /// blinks a window: it clamps with `MinimumSizePolicy.floorWithoutProbing(stored:)`, which is
    /// whatever is already known for that window or `unprobedFloor` where nothing is. The Snap
    /// Assist deck's own opportunistic probe, and learning a floor from a refusal, are unaffected
    /// either way — the switch is about the blink, not about what the app is allowed to know.
    public var probeMinimumSizes = true
    // Compatibility
    /// The one global switch over every private macOS symbol the app uses. **Default on**, because
    /// the private routes are what make the app faster and smoother; off is the promise that each of
    /// those routes has a public one behind it that still works.
    /// The flag lives here, with every other user choice, but nothing in `SnapCore`
    /// reads it: `SystemAdapters.PrivateAPI` is what resolves symbols, and `AppDelegate` mirrors this
    /// value into it on launch and on every change, so flipping it takes effect on the next call
    /// rather than on the next launch.
    public var usePrivateAPIs = true
    // Menu bar
    /// Whether the status item is shown in the menu bar. **On by default.** Off, the app keeps
    /// running exactly as before — the event tap, drags, the snap bar, Snap Assist and the handle
    /// bar are all unaffected — but the icon is gone, and Settings is reached by opening the app
    /// again from the Applications folder or Spotlight.
    public var showInMenuBar = true

    // MARK: - Fixed: read exactly as before, stored nowhere

    /// What the app leaves between a snapped window and the screen edge, and between two snapped
    /// windows. `Fixed.gap` while the switch is on, 0 while it is off.
    public var gap: Double { gapEnabled ? Fixed.gap : 0 }
    public var cornerBand: Double { Fixed.cornerBand }
    public var edgeBand: Double { Fixed.edgeBand }
    public var sharedEdgeBand: Double { Fixed.sharedEdgeBand }
    public var animationDuration: Double { Fixed.animationDuration }
    public var handleMaxGap: Double { Fixed.handleMaxGap }
    public var handleMinOverlap: Double { Fixed.handleMinOverlap }
    public var deckCeiling: Int { Fixed.deckCeiling }
    public var snapFill: Bool { Fixed.snapFill }

    public init() {}

    /// `gap` is reinterpreted rather than dropped: an older file holds a **number** under it. Read
    /// here under its own container so the synthesized `CodingKeys` stays exactly the stored
    /// properties.
    private enum LegacyKeys: String, CodingKey { case gap }

    /// Tolerant decoding: any missing key keeps its default, so adding a setting never resets the
    /// user's file, and **removing** one never fails to read it. The keys an older file may hold —
    /// `paused`, `cornerBand`, `edgeBand`, `animationDuration`, `handleMaxGap`, `handleMinOverlap`,
    /// `handleRelease`, `deckCeiling`, `snapFill`, and `customGap` and `layoutMode` — are unknown keys
    /// here, and a file that still holds them decodes and is rewritten without them on the next save.
    ///
    /// `gap` is the exception, because it is the one key whose *meaning* differs: a file holding a
    /// number is read as "on unless it was 0", which is what setting that number to 0 meant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        sideHalves = try c.decodeIfPresent(Bool.self, forKey: .sideHalves) ?? d.sideHalves
        optionHalves = try c.decodeIfPresent(Bool.self, forKey: .optionHalves) ?? d.optionHalves
        corners = try c.decodeIfPresent(Bool.self, forKey: .corners) ?? d.corners
        topFill = try c.decodeIfPresent(Bool.self, forKey: .topFill) ?? d.topFill
        snapBar = try c.decodeIfPresent(Bool.self, forKey: .snapBar) ?? d.snapBar
        snapBarAppearance = try c.decodeIfPresent(SnapBarAppearance.self, forKey: .snapBarAppearance)
            ?? d.snapBarAppearance
        snapAssist = try c.decodeIfPresent(Bool.self, forKey: .snapAssist) ?? d.snapAssist
        hapticFeedback = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? d.hapticFeedback
        customAreas = try c.decodeIfPresent(Bool.self, forKey: .customAreas) ?? d.customAreas
        restoreOnDragAway = try c.decodeIfPresent(Bool.self, forKey: .restoreOnDragAway) ?? d.restoreOnDragAway
        smoothness = try c.decodeIfPresent(Smoothness.self, forKey: .smoothness) ?? d.smoothness
        handleBar = try c.decodeIfPresent(Bool.self, forKey: .handleBar) ?? d.handleBar
        probeMinimumSizes = try c.decodeIfPresent(Bool.self, forKey: .probeMinimumSizes) ?? d.probeMinimumSizes
        correctOversizedWindows = try c.decodeIfPresent(Bool.self, forKey: .correctOversizedWindows)
            ?? d.correctOversizedWindows
        usePrivateAPIs = try c.decodeIfPresent(Bool.self, forKey: .usePrivateAPIs) ?? d.usePrivateAPIs
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? d.showInMenuBar
        if let stored = try c.decodeIfPresent(Bool.self, forKey: .gapEnabled) {
            gapEnabled = stored
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Double.self, forKey: .gap) {
            gapEnabled = legacy != 0
        } else {
            gapEnabled = d.gapEnabled
        }
    }
}
