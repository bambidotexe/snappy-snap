import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// The custom areas of one display, drawn at once. Rects are in the panel's own space — origin at the
/// display's top-left, y down — which is also SwiftUI's, so nothing here converts.
///
/// Every area **is** `ZonePreviewView`, the ordinary drop preview, in full. The one the pointer is in
/// differs by a heavier fill and nothing else.
struct CustomZonesView: View {
    let rects: [CGRect]
    let filled: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(rects.indices, id: \.self) { index in
                if index != filled {
                    place(ZonePreviewView(padding: 0), in: rects[index])
                }
            }
            // Last, so it is on top of any area it overlaps: it is the first in array order that holds
            // the pointer, which is the one the drop goes to.
            if let filled, rects.indices.contains(filled) {
                place(ZonePreviewView(padding: 0, heavierFill: true), in: rects[filled])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func place(_ view: some View, in rect: CGRect) -> some View {
        view.frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

/// One panel covering one display, at the zone preview's level — it replaces the preview while Command
/// is down. Click-through, and planted on that display for good: what it draws never leaves it.
final class CustomZonesPanel: OverlayPanel {
    static let fadeDuration: TimeInterval = 0.10

    private let host = NSHostingView(rootView: CustomZonesView(rects: [], filled: nil))

    init() {
        super.init(acceptsMouse: false, level: .zonePreview)
        contentView = host
        alphaValue = 0
    }

    /// `displayFrame` is in Cocoa coordinates; `rects` are already local to the display.
    func present(displayFrame: NSRect, rects: [CGRect], filled: Int?) {
        if frame != displayFrame { setFrame(displayFrame, display: false) }
        host.rootView = CustomZonesView(rects: rects, filled: filled)
        fadeIn(duration: Self.fadeDuration)
    }

    func dismiss() { fadeOut(duration: Self.fadeDuration) }
}

/// Puts the custom areas of the display under the pointer on that display's panel, and takes them away.
@MainActor
final class CustomZonesController {
    private struct Shown: Equatable {
        let displayID: UInt32
        let rects: [CGRect]
        let filled: Int?
    }

    private var panels: [UInt32: CustomZonesPanel] = [:]
    private var shown: Shown?

    /// `rects` are CG space, in priority order; `filled` indexes the one to fill, or nil for none. Called
    /// on every drag event, so an unchanged picture does nothing.
    func show(_ rects: [CGRect], filled: Int?, on display: DisplayInfo) {
        let next = Shown(displayID: display.id, rects: rects, filled: filled)
        guard next != shown else { return }
        if let shown, shown.displayID != display.id { panels[shown.displayID]?.dismiss() }
        shown = next
        let panel = panels[display.id] ?? {
            let p = CustomZonesPanel()
            panels[display.id] = p
            return p
        }()
        let local = rects.map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        panel.present(displayFrame: CoordinateSpace.cocoaRect(fromCG: display.frame), rects: local, filled: filled)
    }

    func dismiss() {
        guard let shown else { return }
        panels[shown.displayID]?.dismiss()
        self.shown = nil
    }

    /// Every pooled panel, not only the one that is up: see `ZonePreviewController`.
    func dismissForInterruption() {
        for panel in panels.values { panel.fadeOutForInterruption() }
        shown = nil
    }

    func pruneDisplays(keeping live: [DisplayInfo]) {
        let ids = Set(live.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panel.dismiss()
            panels[id] = nil
        }
        if let shown, !ids.contains(shown.displayID) { self.shown = nil }
    }
}
