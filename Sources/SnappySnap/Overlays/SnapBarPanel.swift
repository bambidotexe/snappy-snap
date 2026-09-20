import AppKit
import QuartzCore
import SwiftUI
import SnapCore
import SystemAdapters

/// The snap bar itself: one panel, moved between displays. Driven by our event tap while the mouse
/// button is down, so it never takes mouse events of its own. It does take **key** in the floating
/// appearance — see `wantsKey` — which is the only way its Liquid Glass renders; that is safe with the
/// button down because `.nonactivatingPanel` takes key without activating this app, and the drag is
/// read from the tap rather than from any window.
///
/// It has three ways onto the screen. The **floating bar** is the panel:
/// it slides and fades, and its frame is the bar's. The **notch shape** is drawn *inside* a panel that
/// is larger than the shape and does not move or fade while the shape grows — every part of that
/// entrance is the SwiftUI shape's own spring, plus one Core Animation fade on the backdrop blur under
/// it. Nothing in either path runs per frame on the main thread, which is where the zone preview
/// animates. The **island** is drawn the same way as the notch shape, in a panel that holds still, and
/// differs in arriving and departing through a motion of its own: `IslandPresence` says which springs,
/// and this class plays them.
final class SnapBarPanel: OverlayPanel {
    static let presentDuration: TimeInterval = 0.18
    /// The bar's own dismiss, for the ordinary end of a drag. An independent literal that happens to
    /// equal `OverlayPanel.interruptionFadeDuration`; it is not routed through it, and changing one
    /// does not change the other.
    static let dismissDuration: TimeInterval = 0.12
    /// How far above its resting place the panel starts, so it slides down from under the menu bar.
    static let slideDistance: CGFloat = 20
    /// The backdrop blur's fades. It arrives a little behind the shape and leaves a little ahead of
    /// it, so it is never seen without the shape it belongs to.
    static let blurFadeIn: TimeInterval = 0.25
    static let blurFadeOut: TimeInterval = 0.15

    let model: SnapBarModel
    private let backdrop = NotchBackdropView(frame: .zero)

    /// The panel's intent, and the guard that keeps a superseded fade-out from ordering it out — see
    /// `ZonePreviewPanel` for what reading `alphaValue` mid-fade costs.
    private var isShown = false
    /// What the notch shape has last been asked to be. `model.expanded` follows it one run-loop turn
    /// later on the way out, so this — not the model — is what a reversal is checked against.
    private var wantsExpanded = false
    /// Whether the panel may take key, which is what makes `canBecomeKey` true. **macOS renders true
    /// Liquid Glass only in the key window**, so the floating bar has to be key or its material is a
    /// flat fallback of itself; the notch shape is drawn on black and has no glass to lose.
    ///
    /// Set by `present(frame:)` and cleared by every way the bar leaves the screen. The notch paths
    /// never touch it and do not need to: `SnapBarController.panel(for:geometry:)` keys its panel on
    /// the surface it draws and builds a new one when that changes, so one instance never serves both.
    private var wantsKey = false
    /// What the island has last been asked to be: the target of the latest step started. SwiftUI is
    /// animating towards it from whatever is on screen, so it is what the next transition leaves from.
    private var islandState: IslandState = .hidden
    /// Bumped by every island transition, so a superseded one's delayed steps and its completion do
    /// nothing.
    private var islandGeneration = 0

    init(model: SnapBarModel) {
        self.model = model
        super.init(acceptsMouse: false, level: .snapBar)
        let hosting = NSHostingView(rootView: SnapBarView(model: model))
        // The window is sized by this class, from the geometry; the hosting view must not answer back.
        hosting.sizingOptions = []
        let container = NSView(frame: .zero)
        for view in [backdrop, hosting] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        contentView = container
        alphaValue = 0
        backdrop.onOutlineOpacity = { [weak self] opacity in self?.model.outlineOpacity = opacity }
    }

    override var canBecomeKey: Bool { wantsKey }

    // MARK: - The floating bar

    /// Slides down while fading in over 180 ms. `frame` is in Cocoa coordinates. Like the zone preview,
    /// every move goes through the animator proxy: `setFrame(_:display:animate:)` would spin a nested
    /// run loop under the event tap.
    func present(frame: NSRect) {
        fadeGeneration &+= 1
        wantsKey = true
        let wasShown = isShown
        isShown = true
        backdrop.isHidden = true
        backdrop.tearDown()
        if !wasShown {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                animator().setFrame(frame.offsetBy(dx: 0, dy: Self.slideDistance), display: true)
            }
        }
        // Ordered front **before** key, for `SnapAssistPanel.present`'s reason: `.moveToActiveSpace`
        // panels re-plant on this call, and a panel not yet on this Space may not be made key. The panel
        // is `.nonactivatingPanel`, so taking key neither activates us nor ends the drag in progress.
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.presentDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(frame, display: true)
        }
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        // Key goes back when the bar does: the fade ends in `orderOut`, which is what resigns it, and a
        // later `present(frame:)` in the meantime supersedes that fade and takes key again.
        wantsKey = false
        fadeAlphaOut(duration: Self.dismissDuration)
    }

    // MARK: - The notch shape

    /// Puts the notch shape's panel on screen, collapsed or grown. The panel takes its frame once,
    /// with no animation, and is added to the elevated Space after every order-front — a
    /// `.moveToActiveSpace` panel is moved when it is ordered in, and adding a window that is already
    /// there costs one call.
    ///
    /// A panel arriving from nothing starts collapsed with animations off, so the spring that follows
    /// has a rendered state to leave from; that state is inside the camera housing and cannot be seen.
    func presentNotch(_ geometry: SnapBarGeometry, expanded: Bool) {
        guard let notch = geometry.notch else { return }
        fadeGeneration &+= 1
        let wasShown = isShown
        isShown = true
        backdrop.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().setFrame(CoordinateSpace.cocoaRect(fromCG: geometry.panelFrame), display: true)
        }
        if !backdrop.configure(field: notch.backdrop) {
            model.outlineOpacity = NotchGeometry.outlineOpacityWithoutLuma
        }
        if !wasShown {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.expanded = false }
            wantsExpanded = false
            alphaValue = 1
        }
        orderFrontRegardless()
        ElevatedSpace.shared.add(self)
        if expanded { expand(arrivingFromNothing: !wasShown) }
    }

    /// Grows the shape, on the spring that overshoots. One run-loop turn late when the panel has only
    /// just been ordered in: SwiftUI animates from the last state it *rendered*, and a hosting view
    /// that has not drawn the collapsed shape yet would show the grown one with no motion at all.
    private func expand(arrivingFromNothing: Bool) {
        guard !wantsExpanded else { return }
        wantsExpanded = true
        let grow = { [weak self] in
            guard let self, self.isShown, self.wantsExpanded else { return }
            withAnimation(.spring(Spring(duration: NotchGeometry.openDuration, bounce: NotchGeometry.openBounce))) {
                self.model.expanded = true
            }
            self.backdrop.setBlurVisible(true, duration: Self.blurFadeIn)
        }
        if arrivingFromNothing {
            DispatchQueue.main.async { MainActor.assumeIsolated { grow() } }
        } else {
            grow()
        }
    }

    /// Shrinks the shape back into the housing on the overdamped spring. The panel is ordered out when
    /// the spring has settled, and only if nothing has presented the panel again in the meantime.
    func collapseNotch() {
        guard isShown else { return }
        wantsExpanded = false
        fadeGeneration &+= 1
        let generation = fadeGeneration
        isShown = false
        backdrop.setBlurVisible(false, duration: Self.blurFadeOut)
        withAnimation(.spring(Spring(duration: NotchGeometry.closeDuration, bounce: NotchGeometry.closeBounce)),
                      completionCriteria: .logicallyComplete) {
            model.expanded = false
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.orderOut(nil)
            }
        }
    }

    // MARK: - The island

    /// Puts the island's panel on screen and takes the island to its capsule, or to its grown shape.
    /// The panel takes its frame once, with no animation, and is added to the elevated Space after
    /// every order-front, as the notch shape's is.
    ///
    /// A panel that is off the screen has rendered nothing, so it starts hidden with animations off
    /// and plays its arrival one run-loop turn later: SwiftUI animates from the last state it
    /// *rendered*. A panel still on screen — a departure in flight — is left as it is, and the new
    /// transition retargets from what is showing.
    func presentIsland(_ geometry: SnapBarGeometry, expanded: Bool) {
        guard let island = geometry.island else { return }
        fadeGeneration &+= 1
        isShown = true
        backdrop.isHidden = false
        let arrivingFromNothing = !isVisible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().setFrame(CoordinateSpace.cocoaRect(fromCG: geometry.panelFrame), display: true)
        }
        if !backdrop.configure(field: island.backdrop) {
            model.outlineOpacity = NotchGeometry.outlineOpacityWithoutLuma
        }
        if arrivingFromNothing {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.island = .hidden }
            islandState = .hidden
        }
        // On every present, not only a fresh one: an alpha fade still in flight would otherwise run on
        // to nothing under a panel that is meant to be up.
        alphaValue = 1
        orderFrontRegardless()
        ElevatedSpace.shared.add(self)
        let target: IslandState = expanded ? .expanded : .capsule
        guard arrivingFromNothing else {
            playIsland(to: target, interrupted: false)
            return
        }
        islandGeneration &+= 1
        let generation = islandGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShown, self.islandGeneration == generation else { return }
                self.playIsland(to: target, interrupted: false)
            }
        }
    }

    /// Takes a grown island back to its capsule, where it stays for the rest of the drag.
    func collapseIsland() {
        guard isShown else { return }
        playIsland(to: .capsule, interrupted: false)
    }

    /// Takes the island off the screen through its departure, from whatever state it is in, and
    /// orders the panel out when the motion has ended — unless something presented it again first.
    /// An interruption drops the cells on the shared interruption fade and skips the collapse. A
    /// panel already departing is left to finish.
    func departIsland(interrupted: Bool) {
        guard isShown else { return }
        isShown = false
        playIsland(to: .hidden, interrupted: interrupted)
    }

    /// Starts every step of the transition: the first now, the rest after their delays. The blur
    /// leaves with anything that is not the grown shape and arrives with the spring that grows it.
    private func playIsland(to target: IslandState, interrupted: Bool) {
        islandGeneration &+= 1
        let generation = islandGeneration
        model.cellsFadeOut = interrupted ? Self.interruptionFadeDuration : IslandPresence.cellsFadeOut
        let steps = IslandPresence.steps(from: islandState, to: target, interrupted: interrupted)
        if target != .expanded { backdrop.setBlurVisible(false, duration: Self.blurFadeOut) }
        guard let last = steps.last else {
            islandTransitionEnded()
            return
        }
        for step in steps {
            let isLast = step == last
            if step.delay == 0 {
                runIslandStep(step, generation: generation, isLast: isLast)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.runIslandStep(step, generation: generation, isLast: isLast)
                    }
                }
            }
        }
    }

    private func runIslandStep(_ step: IslandStep, generation: Int, isLast: Bool) {
        guard islandGeneration == generation else { return }
        islandState = step.state
        if step.motion == .expand { backdrop.setBlurVisible(true, duration: Self.blurFadeIn) }
        let spring = step.motion.spring
        withAnimation(.spring(Spring(duration: spring.duration, bounce: spring.bounce)),
                      completionCriteria: .logicallyComplete) {
            model.island = step.state
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, isLast, self.islandGeneration == generation else { return }
                self.islandTransitionEnded()
            }
        }
    }

    /// Only a departure ends in anything: the panel leaves the screen.
    private func islandTransitionEnded() {
        guard !isShown else { return }
        orderOut(nil)
    }

    /// The shared interruption fade: `OverlayPanel.interruptionFadeDuration`, not `dismissDuration`,
    /// even though the two are the same number. Every surface leaving on the shared constant is what
    /// makes one dismissal read as one dismissal.
    override func fadeOutForInterruption() {
        isShown = false
        wantsExpanded = false
        wantsKey = false
        super.fadeOutForInterruption()
    }
}
