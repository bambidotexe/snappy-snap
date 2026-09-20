import AppKit
import QuartzCore
import SnapCore
import SwiftUI

/// The macOS 27 window corner radius (17 pt, measured 34 px at 2x on a Finder window), a 3 pt stroke
/// in `OverlayAppearance.shapeColor`, a thin translucent fill, and a tight dark shadow hugging the
/// stroke. Click-through.
///
/// The fill is the one part of the preview that is **not** the shared shape colour: it lightens the
/// desktop in the light appearance and darkens it in the dark one — white at 18 %, black at 13 % —
/// and those are two colours by definition, not one drawn twice.
struct ZonePreviewView: View {
    static let cornerRadius: CGFloat = 17
    /// The snap bar's top inset is measured against this stroke, so the number lives in SnapCore and
    /// is read here rather than written down twice.
    static let strokeWidth = CGFloat(ZonePreview.strokeWidth)
    let padding: CGFloat
    /// The custom areas' highlight: the same preview with the fill twice as opaque, and nothing else changed.
    var heavierFill = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let weight = heavierFill ? ZonePreview.highlightFillWeight : 1
        ZStack {
            shape.fill(colorScheme == .dark ? Color.black.opacity(0.13 * weight) : Color.white.opacity(0.18 * weight))
            shape.strokeBorder(OverlayAppearance.shapeColor, lineWidth: Self.strokeWidth)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .clipShape(shape)
        }
        .padding(padding)
    }
}

final class ZonePreviewPanel: OverlayPanel {
    static let shadowPadding: CGFloat = 16
    static let appearDuration: TimeInterval = 0.18
    static let fadeInDuration: TimeInterval = 0.10
    static let moveDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.10

    /// Whether the panel is *meant* to be up. Never `alphaValue`: during a fade the animator reports
    /// the value in flight, so a re-show landing mid-dismiss would read "still visible", take the move
    /// branch, and leave the fade-out running until it hit 0 and ordered the panel out for the rest of
    /// the drag. The snap bar makes that sequence routine — the top band releases 5 pt above the bar,
    /// so the zone goes nil → zone within one or two events on the way in.
    private var isShown = false

    init() {
        super.init(acceptsMouse: false, level: .zonePreview)
        contentView = NSHostingView(rootView: ZonePreviewView(padding: Self.shadowPadding))
        alphaValue = 0
    }

    /// Frames in Cocoa coordinates. On first show the panel starts at `origin` (the dragged window's
    /// frame) and morphs to the zone while fading in, the way the window itself will move on drop;
    /// afterwards it slides between zones. All moves go through the animator proxy, never through
    /// `setFrame(_:display:animate:)`, which would spin a nested run loop under the event tap.
    func present(zoneFrame: NSRect, from origin: NSRect?) {
        let target = zoneFrame.insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding)
        fadeGeneration &+= 1
        let wasShown = isShown
        isShown = true
        if !wasShown {
            let start = (origin ?? zoneFrame).insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding)
            // Zero-duration group: cancels any frame animation still in flight from the previous
            // appearance, so the morph always starts from `start` rather than from a stale target.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                animator().setFrame(start, display: true)
            }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.appearDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.moveDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(target, display: true)
            }
        }
    }

    /// Glues the panel to `frame` with **no** animation at all, appearing out of `origin` the first
    /// time — the handle drag's update, where the preview is what follows the pointer and the windows
    /// do not move until the release.
    ///
    /// `moveDuration`'s 0.15 s ease is right for a preview that hops between zones a drop away and
    /// wrong for one that is being dragged: at 120 Hz a 0.15 s ease would put the panel a tenth of a
    /// second behind the divider the user is holding, which is the lag the pill must not have.
    /// A zero-duration animator group rather than a bare `setFrame`, because an appear or a move may
    /// still be in flight — the same cancellation `present` makes before its own morph, and without
    /// it the animation in flight would go on driving the frame over whatever is set here.
    func track(frame: NSRect, appearingFrom origin: NSRect?) {
        guard isShown else { present(zoneFrame: frame, from: origin); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().setFrame(frame.insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding), display: true)
        }
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        // Only this fade-out may order the panel out, and only if nothing superseded it — the
        // generation guard is inside `fadeAlphaOut`.
        fadeAlphaOut(duration: Self.fadeOutDuration)
    }

    /// The ordinary 100 ms is the feel of a preview releasing; the shared 120 ms is the whole screen
    /// clearing at once. `isShown` is cleared here so a `track` or `present` that lands afterwards
    /// morphs in again rather than sliding a panel the user cannot see.
    override func fadeOutForInterruption() {
        isShown = false
        super.fadeOutForInterruption()
    }
}
