import AppKit
import QuartzCore
import SwiftUI

/// **The** choosing surface for a display: one panel covering the display's visible frame, hosting
/// every area the phase offers at its own place inside it. It is presented once, when the phase
/// starts, and goes away when the phase ends.
///
/// One panel and not one per area, because macOS renders true Liquid Glass only in the **key**
/// window — with a panel per cell, exactly one area (whichever was presented last, so it changed
/// with the arrangement) showed real refractive glass and the rest showed a flat fallback of the
/// same material. Measured twice, from screenshots. One window, one key window, glass everywhere.
///
/// Unlike the other overlays it takes mouse events — not to read them, since every click is decided
/// in `SnapAssistController` from the event tap, but so that a click meant for a card or for ending
/// the phase does not also reach the window underneath. It is key-capable too, so Escape reaches
/// `cancelOperation`. `.nonactivatingPanel` is what makes that safe: the panel takes keyboard input
/// without activating us, so the window that was just snapped keeps its focus.
final class SnapAssistPanel: OverlayPanel {
    /// Each area fades and scales in over 200 ms. Timings, not behaviour: the panel itself appears
    /// at once, and `SnapAssistAreaHost` plays these per area.
    static let presentDuration: TimeInterval = 0.2
    static let dismissDuration: TimeInterval = 0.15
    /// How much smaller an area starts, as a fraction of its cell — the "scale" half of the fade.
    static let scaleInset: CGFloat = 0.04

    var onEscape: (() -> Void)?

    /// The panel's intent, and the guard that keeps a superseded fade-out from ordering a re-shown
    /// panel off screen — see `ZonePreviewPanel` for what reading `alphaValue` mid-fade costs.
    private var isShown = false

    init() {
        super.init(acceptsMouse: true, level: .snapAssist)
        appearance = NSAppearance(named: .darkAqua)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// `frame` is the display's visible frame in Cocoa coordinates: the panel takes it directly and
    /// is fully opaque from the first frame, because what fades in is each area inside it.
    ///
    /// Called once per phase. The hosting view is rebuilt here, which is why picking a card changes
    /// the area's model instead of presenting again: a new hosting view would have no card to animate
    /// out, only a shorter list that was never longer.
    func present(frame: NSRect, content: some View) {
        fadeGeneration &+= 1
        isShown = true
        // Undoes `retire()` and the fade-out's own withdrawal: the panel is presented again by a
        // later phase and has to take mouse events like a new one.
        ignoresMouseEvents = false
        contentView = NSHostingView(rootView: content)
        // No animator and no animation group: the panel covers the whole visible frame and simply
        // appears there. The fade and the scale belong to each area now, inside the hosting view —
        // one panel cannot scale onto several cells at once.
        setFrame(frame, display: true)
        alphaValue = 1
        // Ordered front **before** key. `OverlayPanel` is `.moveToActiveSpace`, and a panel that left
        // with a previous Space re-plants on the destination on this call, measured at ~7 ms;
        // `makeKeyAndOrderFront` alone asks a panel that is not on this Space yet to become key, which
        // is a request the window server is entitled to ignore. Two calls, cheap, and the ordering is
        // the contract.
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
    }

    /// Takes key back without touching the content: picking a window raises it, which activates its
    /// owning app and steals key from a non-activating panel, and a panel that has lost key would stop
    /// hearing Escape for the rest of the phase.
    func takeKey() {
        guard isShown else { return }
        // Front before key, for `present`'s reason.
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
    }

    /// Stops taking mouse events without going away, which is what a fade-out needs: for the 120 to
    /// 150 ms the panel is still on screen it must not catch a click aimed at whatever is behind it.
    /// Key status is untouched — `ignoresMouseEvents` is a mouse hit-testing rule only, so a retired
    /// panel still hears Escape.
    func retire() {
        ignoresMouseEvents = true
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        // Retired before the fade rather than after it: for the 150 ms this takes, the panel is still
        // on screen and would otherwise still be taking clicks on its way out.
        retire()
        fadeOutAndReleaseContent(duration: Self.dismissDuration)
    }

    /// The shared 120 ms rather than the phase's own 150, because on an interruption this surface is
    /// leaving beside the pill, the dim and the previews and not on its own. Everything `dismiss` does
    /// besides the timing is done here too — the panel stops taking clicks before it starts fading,
    /// and the hosting view is released when it lands.
    override func fadeOutForInterruption() {
        guard isVisible else { return }
        isShown = false
        retire()
        fadeOutAndReleaseContent(duration: Self.interruptionFadeDuration)
    }

    private func fadeOutAndReleaseContent(duration: TimeInterval) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Only this fade-out may order the panel out, and only if nothing superseded it.
                guard let self, self.fadeGeneration == generation else { return }
                self.orderOut(nil)
                // The hosting view goes with it. It holds the area's model, its cards, and through
                // them a live `AXUIElement` and an icon per offered window; a pooled panel that the
                // next phase's layout does not reach would keep all of that for the life of the app.
                self.contentView = nil
            }
        })
    }
}
