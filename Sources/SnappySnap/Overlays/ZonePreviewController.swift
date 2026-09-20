import AppKit
import SnapCore
import SystemAdapters

/// Shows the zone a drop would fill, and — for the pair cell — the companion half the same drop fills
/// with the partner window.
///
/// Two pools of one panel per display, not one. A pair drop's two halves are on the **same** display, so
/// a single panel per display cannot draw both, and the whole outcome has to be visible before the user
/// releases. The companion is the same `ZonePreviewView` at the same window level, so it is the ordinary
/// preview and not a second look invented for this case; the halves never overlap, so there is nothing
/// to order between them.
@MainActor
final class ZonePreviewController {
    private var panels: [UInt32: ZonePreviewPanel] = [:]
    private var companions: [UInt32: ZonePreviewPanel] = [:]
    private var shownDisplay: UInt32?
    private var shownCompanionDisplay: UInt32?

    /// `origin` (CG space) is the dragged window's frame, used only when the preview first appears.
    /// `companion` is the other half of a pair drop, or nil — and it is dropped whenever `zone` is,
    /// because there is no state in which the partner's half is previewed on its own.
    func show(_ zone: Zone?, companion: Zone? = nil, from origin: CGRect? = nil) {
        // The companion never morphs from the dragged window: that window is going to the *other* half,
        // so a morph from it would draw the wrong journey. It fades in where the partner will land. The
        // partner's own frame would be the honest origin, and reading it is an Accessibility call on
        // the drag path, which is exactly the cost this preview exists to avoid.
        shownCompanionDisplay = present(zone == nil ? nil : companion, in: &companions,
                                        shown: shownCompanionDisplay, from: nil)
        shownDisplay = present(zone, in: &panels, shown: shownDisplay, from: origin)
    }

    /// Takes every preview off the screen through the shared 120 ms interruption fade, and forgets
    /// which display was showing so the next `show` presents rather than slides.
    ///
    /// Every pooled panel, not only the two that are up: a panel left behind on a Space the user has
    /// left is one nothing else in this class can reach — `present` only ever dismisses the display it
    /// last showed on.
    func dismissForInterruption() {
        for panel in panels.values { panel.fadeOutForInterruption() }
        for panel in companions.values { panel.fadeOutForInterruption() }
        shownDisplay = nil
        shownCompanionDisplay = nil
    }

    /// Drops the panels of displays that no longer exist, from **both** pools.
    ///
    /// Panels are keyed by display id and kept for the life of the app so that moving back and forth
    /// between displays does not rebuild them. With two pools, unbounded retention would grow by two
    /// panels for every display the user ever unplugs. Each panel is an `NSPanel` with a backing
    /// surface the size of its zone, which is not nothing on a 6K display.
    ///
    /// Called from `screens.onChange`, where `Screens` has already reloaded `displays` before it fires,
    /// so `live` is the new configuration and not the old one. The session is cancelled on that same
    /// notification and takes every preview down first, so nothing here can cut a fade the user can see
    /// — and a panel released mid-fade takes the fade off the screen with it.
    func pruneDisplays(keeping live: [DisplayInfo]) {
        let ids = Set(live.map(\.id))
        for pool in [\ZonePreviewController.panels, \ZonePreviewController.companions] {
            for (id, panel) in self[keyPath: pool] where !ids.contains(id) {
                panel.dismiss()
                self[keyPath: pool][id] = nil
            }
        }
        if let shownDisplay, !ids.contains(shownDisplay) { self.shownDisplay = nil }
        if let shownCompanionDisplay, !ids.contains(shownCompanionDisplay) { self.shownCompanionDisplay = nil }
    }

    /// Presents `zone` on its display's panel from `pool`, dismissing whatever that pool had up
    /// elsewhere, and hands back the display now showing.
    private func present(_ zone: Zone?, in pool: inout [UInt32: ZonePreviewPanel], shown: UInt32?,
                         from origin: CGRect?) -> UInt32? {
        guard let zone else {
            if let shown { pool[shown]?.dismiss() }
            return nil
        }
        if let shown, shown != zone.displayID { pool[shown]?.dismiss() }
        let panel = pool[zone.displayID] ?? {
            let p = ZonePreviewPanel()
            pool[zone.displayID] = p
            return p
        }()
        panel.present(zoneFrame: CoordinateSpace.cocoaRect(fromCG: zone.frame),
                      from: origin.map { CoordinateSpace.cocoaRect(fromCG: $0) })
        return zone.displayID
    }
}
