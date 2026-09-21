import AppKit
import os
import SnapCore
import SystemAdapters

/// One engine for every zone. The router resolves the screen the zone lives on, runs the stepper
/// and records the result in the registry, so callers never touch either directly.
@MainActor
final class EngineRouter {
    let stepping: SteppingSnapEngine
    let state: SnapState
    let settingsStore: SettingsStore
    /// Where a landing is observed and a refusal raises the window's own floor. See `observe(landed:asked:before:handle:)`.
    let minimums: MinimumSizeStore
    /// Every display, which is what says whether a window released across an edge reaches onto
    /// another one (`Geometry.departure`).
    let screens: any ScreensProviding

    init(stepping: SteppingSnapEngine, state: SnapState, settingsStore: SettingsStore,
         minimums: MinimumSizeStore, screens: any ScreensProviding) {
        self.screens = screens
        self.stepping = stepping
        self.state = state
        self.settingsStore = settingsStore
        self.minimums = minimums
    }

    /// Starts the animation on this run-loop turn: nothing is activated, awaited or polled first.
    /// `completion` gets the landed frame, or nil when the snap was cancelled or had no screen. The
    /// display's working area travels with the zone because minimum-size anchoring needs to know
    /// which of the zone's edges are the display's own. `refusal` is what becomes of the origin when
    /// the window will not take the size: the caller's to say, because only the caller knows whether
    /// something else is going to make room for it.
    func snap(_ handle: WindowHandle, from: CGRect, to zone: Zone, display: DisplayInfo,
              refusal: RefusalPolicy, completion: @escaping @MainActor (CGRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id })
                ?? NSScreen.main ?? NSScreen.screens.first else {
            completion(nil)
            return
        }
        // The animation's start only. `from` stays what the registry records and what the landing is
        // judged against: it is where the window really was.
        let departure = Geometry.departure(
            of: from, onto: display.frame,
            otherDisplays: screens.displays.filter { $0.id != display.id }.map(\.frame))
        if departure != from {
            Logger.drag.debug("""
                window \(handle.windowID ?? 0) was released across a display seam at \
                \(String(describing: from), privacy: .public); animating from \
                \(String(describing: departure), privacy: .public) on display \(display.id)
                """)
        }
        stepping.snap(handle, from: departure, to: zone.frame, within: display.visibleFrame,
                      duration: settingsStore.settings.animationDuration, on: screen,
                      refusal: refusal) { [weak self] landed in
            if let self, let landed {
                if let id = handle.windowID {
                    self.state.registry.record(windowID: id, currentFrame: from, snappedFrame: landed, zone: zone)
                }
                self.state.lastSnap = Date()
                self.observe(landed: landed, asked: zone.frame, before: from, handle: handle)
            }
            completion(landed)
        }
    }

    func cancel(windowID: CGWindowID?) {
        stepping.cancel(windowID: windowID)
    }

    /// **A landing is a free look at the window's size, and a landing larger than asked is a refusal.**
    /// On macOS that is the only way a window ever tells us — measured: of 7 windows across 5
    /// applications and 4 toolkits not one publishes `AXMinSize` or `AXMinimumSize`; the attributes
    /// are absent, not empty.
    ///
    /// The look may lower the application's row and the window's own floor (§6). The refusal raises
    /// **the window's own floor and never the row**: a row only comes down by itself, so a refusing
    /// window stops the next drop preview of *that window* where it really stops, and a fresh window
    /// of the same application starts from the row.
    ///
    /// `HandleDragMath.roundingAllowance` is the same 12 pt the handle features clamp with,
    /// measured off a real terminal's 18 pt character grid: below it a landing is an application
    /// rounding its own frame and not refusing one, and reading those as refusals freezes a live
    /// handle drag — a 0.5 pt tolerance does exactly that. An axis that did not refuse is passed as
    /// 0, which `MinimumSizeStore.refused` takes as "this landing says nothing about this axis".
    ///
    /// **And the landing has to be evidence that anything happened at all.** `landed` is read back
    /// after the last write, and an application that has not applied that write yet answers with
    /// the frame it had *before* — which reads as a total refusal and would raise a floor the window
    /// can then never get below. `MinimumSizePolicy.landingIsEvidence` is the test: a frame that
    /// moved at all proves the write was applied, and a snap moves the origin as well as the size,
    /// so a genuine refusal still passes it on its position alone. What it excludes is the frame
    /// where nothing changed, which says nothing either way.
    private func observe(landed: CGRect, asked: CGRect, before: CGRect, handle: WindowHandle) {
        let window = handle.windowID ?? 0
        MinimumProbe.logLowering(minimums.observe(handle, size: landed.size), window: window,
                                 size: landed.size, log: Logger.drag)
        guard MinimumSizePolicy.landingIsEvidence(landed: landed, before: before) else { return }
        let floor = MinimumSizePolicy.revealedFloor(landed: landed.size, asked: asked.size)
        guard floor != .zero, let own = minimums.refused(floor, for: handle) else { return }
        Logger.drag.info("""
            window \(window) of \(HandleBarController.appKey(for: handle), privacy: .public) was asked \
            \(asked.width, format: .fixed(precision: 0))×\(asked.height, format: .fixed(precision: 0)) and took \
            \(landed.width, format: .fixed(precision: 0))×\(landed.height, format: .fixed(precision: 0)); \
            its own floor is now \(own.width, format: .fixed(precision: 0))×\
            \(own.height, format: .fixed(precision: 0)); the row stands
            """)
    }
}
