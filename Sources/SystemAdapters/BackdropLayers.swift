import AppKit
import QuartzCore
import os

/// The two private Core Animation pieces behind the notch shape's backdrop, and nothing else: a layer
/// that shows *what is behind this window*, and a filter that blurs it by a per-pixel radius.
///
/// **Why not `NSVisualEffectView`.** A material is a uniform blur *plus a tint*, and the tint is
/// the whole problem: around a black shape over a light window it reads as a grey frame, and masking
/// it only moves the frame's edge. A `CABackdropLayer` with `windowServerAware` set is the same
/// window-server picture with nothing laid over it — measured: with a window of our own underneath,
/// its luminance callback reports 1.0000 over white, 0.0000 over black and 0.5000 over mid grey — and
/// `variableBlur` then blurs that picture by `inputRadius` scaled, per pixel, by a mask's alpha. Where
/// the mask is clear the backdrop is drawn unblurred, which is indistinguishable from not being there.
///
/// Both classes are asked for on every call, through `PrivateAPI`. With either absent, or the switch
/// off, the makers return nil and the caller draws no backdrop at all.
@MainActor
public enum BackdropLayers {
    /// Whether both classes answer right now — the switch is on and this macOS has them. Two
    /// dictionary lookups, so a caller can ask before doing any work that only the private route needs.
    public static var isAvailable: Bool {
        PrivateAPI.shared.pointer(for: .caBackdropLayer) != nil && PrivateAPI.shared.pointer(for: .caFilter) != nil
    }

    /// A layer that draws what is behind its window, or nil on the public route.
    public static func makeBackdropLayer() -> CALayer? {
        guard let pointer = PrivateAPI.shared.pointer(for: .caBackdropLayer),
              let type = unsafeBitCast(pointer, to: AnyClass.self) as? CALayer.Type else { return nil }
        let layer = type.init()
        // Without this the layer samples only the layers beneath it in its own window — which, in a
        // transparent panel, is nothing.
        layer.setValue(true, forKey: "windowServerAware")
        return layer
    }

    /// A `variableBlur` filter: the backdrop blurred by `radius` where `mask` is opaque, not at all
    /// where it is clear, and proportionally between. Nil on the public route.
    ///
    /// `inputNormalizeEdges` keeps the blur from pulling in transparent black at the layer's bounds,
    /// which would otherwise darken its rim.
    public static func makeVariableBlur(radius: Double, mask: CGImage) -> NSObject? {
        guard let pointer = PrivateAPI.shared.pointer(for: .caFilter),
              let type = unsafeBitCast(pointer, to: AnyClass.self) as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard type.responds(to: make),
              let filter = type.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject else {
            Logger.privateAPI.info("CAFilter has no variableBlur on this macOS; the notch shape draws no backdrop blur")
            return nil
        }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }
}

/// Reads how bright the backdrop behind a region of a window is, from the window server itself — no
/// Screen Recording, because the picture never leaves the window server; only one number does.
///
/// A backdrop layer with `tracksLuma` set tells its delegate the mean luminance of what it covers,
/// 0…1, whenever that changes. The layer has no filter, so it draws the backdrop exactly as it is and
/// is invisible. Install `layer` wherever the reading should be taken; it is nil on the public route,
/// where `onChange` is never called.
@MainActor
public final class BackdropLumaTracker: NSObject, CALayerDelegate {
    public let layer: CALayer?
    /// Called on the main thread with the backdrop's mean luminance, 0…1.
    public var onChange: (@MainActor (Double) -> Void)?

    public override init() {
        layer = BackdropLayers.makeBackdropLayer()
        super.init()
        layer?.setValue(true, forKey: "tracksLuma")
        layer?.delegate = self
    }

    /// `CABackdropLayer`'s delegate callback. The window server calls it on the main thread.
    @objc(backdropLayer:didChangeLuma:)
    nonisolated func backdropLayer(_ layer: CALayer, didChangeLuma luma: Double) {
        MainActor.assumeIsolated { onChange?(luma) }
    }

    /// A backdrop layer has no content of its own to animate, and an implicit action on its bounds
    /// would make the reading lag the region it is supposed to cover.
    public nonisolated func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}
