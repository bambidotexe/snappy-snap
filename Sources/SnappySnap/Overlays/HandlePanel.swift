import AppKit
import os
import SnapCore
import SwiftUI
import SystemAdapters

@MainActor
final class HandleModel: ObservableObject {
    /// The pill's own size, from `HandleBarGeometry` — the view draws it and nothing else decides it.
    @Published var pillSize: CGSize = .zero
}

/// A pill in `OverlayAppearance.shapeColor`, `HandleBarGeometry.pillThickness` thick, fully rounded,
/// with a soft shadow, at the one size that fits between two windows. The shadow is the whole of what
/// separates it from a pale wallpaper, the colour being opaque. The thickness is read from the
/// constant rather than repeated here, so the pill and the geometry that places it cannot disagree.
struct HandlePillView: View {
    @ObservedObject var model: HandleModel

    var body: some View {
        Capsule()
            .fill(OverlayAppearance.shapeColor)
            .frame(width: model.pillSize.width, height: model.pillSize.height)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's content view, and the home of the resize cursor — which **public AppKit alone** cannot
/// show from an app that never activates, and which this class shows anyway.
///
/// Shared with the junction knob, which asserts the system's move glyph on it: the keepalive, the
/// band test and the drag flag are the same machinery, and everything below applies unchanged to any
/// glyph at all.
///
/// **What public AppKit does.** Proved by elimination, reading `NSCursor.currentSystem` from inside
/// the app (30×24 is `columnResize`, 28×40 the arrow):
///
/// | what was tried | cursor update delivered | what the screen showed |
/// |---|---|---|
/// | `.mouseEnteredAndExited` + `.activeAlways` tracking area + `set()` | yes (enter/exit fire) | 28×40 arrow |
/// | `acceptsMouseMovedEvents = true` | no | 28×40 arrow |
/// | `.cursorUpdate` + `.activeAlways` tracking area | **yes, it does fire** — AppKit simply does not deliver it to an inactive app | 28×40 arrow |
/// | SwiftUI `.pointerStyle(.columnResize)` | n/a | 28×40 arrow |
/// | panel made key (`canBecomeKey`, `makeKeyAndOrderFront`) | yes — but **making a panel key is activating**, which is the one thing this app must never do | 28×40 arrow |
/// | key **and** `NSApp.activate()` | yes | 30×24, ours — at the cost of stealing focus on every gap crossed |
///
/// So AppKit's delivery is one gate and the window server is the other: **it takes a cursor only from
/// the active application.** No arrangement of public AppKit passes the second gate without
/// activating.
///
/// **The route that works**, measured: that second gate is a property of our *window-server
/// connection*, not a law. `BackgroundCursor.enable()` sets `SetsCursorInBackground` on
/// it and the plain public `NSCursor.set()` then reaches the screen with the app inactive and no panel
/// key. Two consequences shape this class:
///
/// - **The override is global.** Whatever we set wins everywhere, so a cursor is asserted only while
///   the pointer is genuinely inside the handle's hover band — and the band is re-tested on every
///   keepalive tick, not only when an event arrives, so a timer that outlives its reason self-corrects.
/// - **A single `set()` does not stick** and a tap-driven assert flickers. It is re-asserted on a
///   keepalive at one display frame (16 ms; 50 ms also held 10/10, 100 ms held 9/10). `NSCursor.set()`
///   costs 0.0003 ms, so the keepalive is free.
///
/// **Stopping is not setting an arrow.** `stopAsserting()` stops; it never calls `NSCursor.arrow.set()`,
/// which would stomp the I-beam of the app underneath — globally, since the override is global. The
/// app underneath gets its own cursor back the moment we stop.
///
/// `ignoresMouseEvents = false` on the panel is load-bearing and stays: the window server hands the
/// cursor region to the topmost non-click-through window under the pointer, and a click-through panel
/// would leave the window underneath free to reset the cursor from its own tracking areas.
final class HandleContentView: NSView {
    /// One display frame. Measured: 16 ms and 50 ms each held 10/10, 100 ms held 9/10; ≤ 16 ms is the
    /// requirement.
    static let keepaliveInterval: TimeInterval = 1.0 / 60.0

    /// The cursor this handle stands for. Set by the panel's layout, asserted by the keepalive.
    var cursor: NSCursor = .arrow

    /// While the handle is being dragged the cursor stays asserted even when the pointer leaves the
    /// band: the divider clamps at a window's minimum size and the pointer walks off the panel, and
    /// the cursor must not flicker back for the rest of a gesture that is entirely ours — and the
    /// gesture runs to the mouse-up, since nothing is written before it.
    private(set) var isDragging = false

    /// "Is the pointer in the band the panel is drawn for", supplied by the panel from the same
    /// geometry function that positions it: two hit areas that can disagree are a bug.
    private var isPointerInBand: (@MainActor () -> Bool)?
    private var keepalive: Timer?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }

    /// Starts asserting `cursor` while the pointer is in the band, or does nothing at all when the
    /// route is unavailable — private interfaces switched off, or SkyLight's symbols missing on this
    /// macOS. `enable()` is asked on every call rather than once per launch: it is two C calls, a
    /// window-server reconnect drops the property, and the Settings switch has to take effect on the
    /// next band entry without a relaunch.
    func startAsserting(_ cursor: NSCursor, whilePointerIn band: @escaping @MainActor () -> Bool) {
        self.cursor = cursor
        isPointerInBand = band
        guard BackgroundCursor.enable() else { stopAsserting(); return }
        if keepalive == nil {
            let timer = Timer(timeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0
            // `.common`, so the assertion survives any run-loop mode AppKit enters while an overlay is
            // up. Nothing here is modal, but a keepalive that stops without stopping asserting is the
            // one failure this class must not have.
            RunLoop.main.add(timer, forMode: .common)
            keepalive = timer
        }
        tick()
    }

    /// Stops asserting. **Never sets a cursor** — see the class comment.
    func stopAsserting() {
        keepalive?.invalidate()
        keepalive = nil
        isPointerInBand = nil
    }

    /// Re-asserts, or stops when there is no longer a reason to assert. Runs at 60 Hz and logs nothing.
    private func tick() {
        guard isDragging || isPointerInBand?() == true else { stopAsserting(); return }
        cursor.set()
    }

    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        if dragging {
            // The press came from inside the band, so there is already a keepalive; this only stops
            // the next tick from reading a band the pointer has since left.
            tick()
        } else if isPointerInBand?() != true {
            stopAsserting()
        }
    }

    // Logged because this pair of messages is the *only* thing in the handle bar that AppKit
    // delivers — everything else comes off the event tap. The cursor does not depend on them: the
    // keepalive's own band test is what starts and stops the assertion, and an exit is noticed within
    // one frame whether or not AppKit says so.
    override func mouseEntered(with event: NSEvent) {
        Logger.handle.debug("pointer entered the handle")
    }

    override func mouseExited(with event: NSEvent) {
        Logger.handle.debug("pointer left the handle; dragging=\(self.isDragging)")
    }
}

/// The handle. One panel for the whole app: only one gap is ever hovered.
///
/// It takes mouse events, which is unusual for an overlay here, and **not** because it handles any:
/// mouse down, drag and up all arrive through the event tap, in `HandleBarController`. It takes them
/// because the window server hands the cursor to the topmost window under the pointer that is not
/// click-through, and a click-through panel would leave the window underneath free to reset the
/// cursor from its own tracking areas the moment the pointer crossed one. Taking the events also
/// means the press that starts a divider drag is swallowed here instead of reaching the desktop
/// behind the gap. At rest it covers **exactly the band it is pressed in** and not a point more, so
/// there is no ring of panel where a click would do nothing; while the handle is dragged it is
/// `dragBandThickness` wide, which costs nothing because the button is already down. It goes
/// click-through the instant it starts to fade, so it never catches a click on its way out.
final class HandlePanel: OverlayPanel {
    static let fadeDuration: TimeInterval = 0.12

    private let model = HandleModel()
    private let content = HandleContentView()

    /// What the last layout was for, so `setDragging` can redo it at the new width.
    private var lastPair: HandlePair?
    private var lastDivider: Double?
    /// The hover band the panel is currently drawn for, in CG space — what the cursor keepalive tests
    /// the pointer against. Re-computed in `layout` from `HandleBarGeometry.band`, the same function
    /// `HandleBarController` hit-tests the press with, so the cursor and the click agree by
    /// construction.
    private var band: CGRect = .zero

    init() {
        super.init(acceptsMouse: true, level: .handleBar)
        let hosting = NSHostingView(rootView: HandlePillView(model: model))
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        contentView = content
        alphaValue = 0
    }

    /// Positions the panel over the pair's band (CG space) and fades it in over 120 ms.
    func show(pair: HandlePair) {
        layout(pair: pair, divider: pair.divider)
        // The cursor is asserted on every show, not only on the first: the panel can appear under a
        // pointer that is not moving, and no tracking-area entry follows that. The keepalive that
        // starts here stops itself the moment the pointer is no longer in the band.
        content.startAsserting(Self.cursor(for: pair.orientation)) { [weak self] in
            guard let self else { return false }
            return self.band.contains(BackgroundCursor.pointerLocation)
        }
        // Before the fade: `dismiss` makes the panel click-through on its way out, and a show that
        // lands during that fade has to take it back whether or not it is the *first* show.
        ignoresMouseEvents = false
        fadeIn(duration: Self.fadeDuration)
    }

    /// Slides the panel to a new divider during a drag. No animation: the panel follows the previews
    /// the drag is drawing, and an animator here would lag the divider the user is holding.
    func move(divider: Double, pair: HandlePair) {
        layout(pair: pair, divider: divider)
    }

    func setDragging(_ dragging: Bool) {
        content.setDragging(dragging)
        // The panel's width across the divider depends on this, so re-lay it out at once rather than
        // waiting for the first drag event.
        if let lastPair, let lastDivider { layout(pair: lastPair, divider: lastDivider) }
    }

    /// Stops the cursor assertion without taking the pill down, for the caller that owns this panel's
    /// visibility.
    func stopAsserting() { content.stopAsserting() }

    func dismiss() {
        guard isFadedIn else { return }
        // Click-through before the fade, not after it: for the 120 ms this takes the panel is still on
        // screen and would otherwise still be taking clicks aimed at the windows it sits between.
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        fadeOut(duration: Self.fadeDuration)
    }

    /// Same as `dismiss()` — click-through, the drag width dropped, the cursor assertion stopped — but
    /// with no fade. See `OverlayPanel.hideAtOnce`. Only ever called on a hover with nothing being
    /// dragged: a live drag's pill *is* the divider, not a hover to take away.
    ///
    /// Gated on `isVisible` and not on `isFadedIn`, so a pill part-way through its own 120 ms
    /// fade-out is taken the rest of the way now. Command promises the screen is clear on the
    /// keystroke, and a pill that merely happened to be leaving already is still a pill on screen.
    override func hideAtOnce() {
        guard isVisible else { return }
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        super.hideAtOnce()
    }

    /// The shared interruption fade. Everything `dismiss` does — click-through first, the drag width
    /// dropped, the cursor assertion stopped — and the shared duration instead of this panel's own.
    /// The two are the same 120 ms today; routing through the constant is what keeps them the same.
    override func fadeOutForInterruption() {
        guard isVisible else { return }
        ignoresMouseEvents = true
        content.setDragging(false)
        content.stopAsserting()
        super.fadeOutForInterruption()
    }

    /// A vertical divider (a pair side by side, `orientation == .horizontal`) resizes across, a
    /// horizontal one up and down. `directions: .all` because the divider moves both ways from here.
    private static func cursor(for orientation: HandlePair.Orientation) -> NSCursor {
        orientation == .horizontal
            ? NSCursor.columnResize(directions: .all)
            : NSCursor.rowResize(directions: .all)
    }

    private func layout(pair: HandlePair, divider: Double) {
        lastPair = pair
        lastDivider = divider
        model.pillSize = HandleBarGeometry.pillSize(orientation: pair.orientation, overlap: pair.overlapLength)
        content.cursor = Self.cursor(for: pair.orientation)
        band = HandleBarGeometry.band(for: pair, divider: divider)
        let rect = HandleBarGeometry.panelRect(for: pair, divider: divider, dragging: content.isDragging)
        setFrame(CoordinateSpace.cocoaRect(fromCG: rect), display: true)
    }
}
