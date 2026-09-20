import AppKit

/// Where an overlay sits in the app's own stack. One order is fixed: the snap bar strictly above the
/// zone preview, because the preview calls `orderFrontRegardless()` on every zone change and would
/// otherwise climb over the bar the cursor is aiming at. The window server enforces window levels
/// absolutely — a window never draws above one of a higher level, whatever order it is shown in — so
/// the ordering cannot be inverted by any sequence of show/hide calls.
///
/// The offsets are dim 0, zone preview 1, Snap Assist 4, handle bar 8, snap bar 12. Each is an offset
/// from `.statusBar`, written once in `OverlayPanel.init` and required there rather than defaulted.
/// Only preview < snapBar is a rule; the gaps leave room to move a surface between two slots without
/// renumbering, and the two middle slots never share the screen with the bar anyway.
///
/// Nothing reads a raw value; the enum is the contract, and `windowLevel` is the one place a raw
/// offset becomes an `NSWindow.Level`.
enum OverlayLevel: Int {
    /// The handle drag's dim, at `.statusBar` itself — **25**, which is above the main-menu level (24)
    /// and the Dock (20). The dim covers the *entire* display, menu bar and Dock included, because
    /// during a divider drag nothing on screen is true and a bright menu bar over a dimmed desktop
    /// reads as a rendering fault. The previews at 1 and the pill at 8 stay above it — they are what
    /// the gesture is asking the user to look at.
    case dim = 0
    case zonePreview = 1
    case snapAssist = 4
    case handleBar = 8
    case snapBar = 12

    /// Offset from `.statusBar` (25). Nothing in AppKit sits between it and `.popUpMenu` (101), so the
    /// whole stack stays above normal windows and still below an open menu.
    var windowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + rawValue)
    }
}

/// Borderless, transparent, non-activating panel above normal windows, on the Space that is active
/// when it is shown.
class OverlayPanel: NSPanel {
    /// One interruption fade, 120 ms, **alpha only**, for every surface, on both interruptions —
    /// Mission Control and a Space change.
    ///
    /// It is not "whatever each panel's own dismiss does", and the difference is the point. The zone
    /// preview leaves in 100 ms, the Snap Assist surface in 150, the pill and the knob in 120; on the
    /// ordinary end of a gesture those differences are the feel of each surface and they stay. An
    /// interruption is one event that takes every surface off the screen at once, and five surfaces
    /// leaving a screen at three different speeds reads as five bugs rather than as one dismissal.
    /// Alpha only, with no frame animation: the arrangement the frames describe is already gone.
    static let interruptionFadeDuration: TimeInterval = 0.12

    init(acceptsMouse: Bool, level: OverlayLevel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level.windowLevel
        ignoresMouseEvents = !acceptsMouse
        // `.moveToActiveSpace`, **not** `.canJoinAllSpaces`. Measured: an all-Spaces panel rides the
        // old Space off and is then re-planted on the destination at +994.8 ms — 12.7 ms *before* the
        // app is told the Space changed. That leaves the panel standing on the next Space with no turn
        // in which this app could take it down first. A `.moveToActiveSpace` panel leaves with the
        // Space it was shown on and
        // re-plants in ~7 ms on the next `orderFrontRegardless()`, which is why every show path in
        // this app orders front before it asks for key. `isOnActiveSpace` lies for one turn after a
        // change and is deliberately never read.
        collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Fading

    /// Whether the panel is *meant* to be up — never `alphaValue`, which reports the value in flight
    /// during a fade and reads a panel mid-dismiss as still visible, which strands an overlay on
    /// screen (see `ZonePreviewPanel`). Named apart from the three panels that keep a private
    /// `isShown` of their own: this is the shared one, and a stored property cannot be overridden.
    private(set) var isFadedIn = false
    /// Voids the completion of a fade-out that a later show or dismiss has superseded.
    ///
    /// **One counter for the whole panel, shared with the subclasses that fade on their own terms**
    /// (the zone preview, the snap bar, the Snap Assist surface). A counter per subclass would not
    /// survive `fadeOutForInterruption` fading the same panel from the base class: two counters mean
    /// two fades that each believe they own the panel's exit, and the loser still orders out a panel a
    /// later `present` has put back on screen.
    var fadeGeneration = 0

    /// Orders the panel in and fades it to opaque. The generation is bumped even when the panel is
    /// already up, so a fade-out still in flight cannot order it out behind this call's back.
    func fadeIn(duration: TimeInterval) {
        fadeGeneration &+= 1
        guard !isFadedIn else { return }
        isFadedIn = true
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = 1
        }
    }

    /// Fades to transparent and orders out — but only if nothing superseded this particular fade.
    func fadeOut(duration: TimeInterval) {
        guard isFadedIn else { return }
        isFadedIn = false
        fadeAlphaOut(duration: duration)
    }

    /// The fade itself, with **no** "is it up" gate of its own: alpha to 0 over `duration`, and an
    /// order-out at the end unless a later show or dismiss superseded it. Subclasses whose ordinary
    /// dismiss is gated on an `isShown` of their own call this once they have cleared it.
    func fadeAlphaOut(duration: TimeInterval) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.orderOut(nil)
            }
        })
    }

    /// The one way off the screen when the *system* took the user away, rather than the user ending
    /// the gesture. Subclasses that keep an `isShown` of their own, or that hold something a
    /// dismiss releases — mouse events, a cursor assertion, a hosting view — override this, do that
    /// part, and call `super`.
    ///
    /// Deliberately not gated on `isFadedIn`: the three panels that fade on their own terms do not
    /// set it, and this has to reach them. `isVisible` is the one honest question — a panel that was
    /// never ordered in has nothing to fade — and it is true for a panel mid-fade, which is exactly
    /// the panel this most needs to reach.
    func fadeOutForInterruption() {
        guard isVisible else { return }
        isFadedIn = false
        fadeAlphaOut(duration: Self.interruptionFadeDuration)
    }

    /// Off screen inside this call, with no animation at all — alpha to 0 and ordered out on this same
    /// turn of the run loop, unlike `fadeOut`/`fadeOutForInterruption`, both of which take 120 ms.
    /// For the one caller that cannot afford even that: the Command key hiding the pill and the knob so a
    /// mouse-down arriving right behind it lands on the window underneath rather than on a panel still
    /// fading out. Bumps the fade generation so a fade already in flight cannot order this panel back
    /// out from under a later show.
    func hideAtOnce() {
        fadeGeneration &+= 1
        isFadedIn = false
        alphaValue = 0
        orderOut(nil)
    }
}
