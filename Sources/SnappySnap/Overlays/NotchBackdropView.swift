import AppKit
import QuartzCore
import os
import SnapCore
import SystemAdapters

/// What sits under the snap bar's black shape in its panel — the notch shape or the island: the
/// backdrop blur, and the layer that reads how bright the backdrop is. Both are private Core
/// Animation layers from `BackdropLayers`; on the public route this view holds nothing and draws
/// nothing.
///
/// **Nothing here runs per frame.** The blur is one layer the size of the panel whose mask is built
/// once per bar size, for the *expanded* shape; opening and closing only fades its opacity, which the
/// render server animates. A blur that followed the shape frame by frame would rebuild a bitmap on
/// the main thread on every tick of a drag — and the main thread is where the zone preview animates.
/// The field is wide and soft enough (see `BackdropField.sigma`) that fading it in at its final
/// size behind a shape still arriving does not read as a separate object.
///
/// Layer geometry is Core Animation's: origin bottom-left, y up. The mask is written row by row from
/// the top, which is how a bitmap is stored. Measured with a mask opaque in its top half only: the
/// blur appears in the visual top half and the bottom reads exactly unblurred, so no flip is needed.
@MainActor
final class NotchBackdropView: NSView {
    private var blurLayer: CALayer?
    private var luma: BackdropLumaTracker?
    /// What the current mask was built for. `BackdropField` is `Hashable`, and everything the mask
    /// depends on is in it.
    private var maskedFor: BackdropField?
    /// Called with the contrast outline's opacity whenever the backdrop's luminance crosses a threshold.
    var onOutlineOpacity: ((Double) -> Void)?
    private var outlineShown = false

    /// Mask pixels per point. The field has no feature finer than its own σ of 27 pt, and the filter
    /// stretches the mask over the layer's bounds.
    private static let maskScale: Double = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Builds, rebuilds or removes the layers for this bar. Called on every present, so the private
    /// route is asked for each time and the switch takes effect on the next drag.
    ///
    /// - Returns: whether a backdrop is in place. Without one the outline cannot follow the backdrop,
    ///   and the caller shows the constant hairline instead.
    @discardableResult
    func configure(field: BackdropField) -> Bool {
        guard BackdropLayers.isAvailable else {
            tearDown()
            return false
        }
        // Same bar as the last present: the layers and their mask still fit.
        if maskedFor == field, blurLayer != nil { return true }
        tearDown()
        let panelFrame = field.panel
        guard let mask = Self.makeMask(field: field),
              let blur = BackdropLayers.makeBackdropLayer(),
              let filter = BackdropLayers.makeVariableBlur(radius: BackdropField.blurRadius, mask: mask) else {
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blur.frame = CGRect(origin: .zero, size: panelFrame.size)
        blur.filters = [filter]
        blur.opacity = 0
        layer?.addSublayer(blur)
        blurLayer = blur

        let tracker = BackdropLumaTracker()
        if let lumaLayer = tracker.layer {
            let region = field.lumaRegion.intersection(panelFrame)
            lumaLayer.frame = CGRect(x: region.minX - panelFrame.minX,
                                     y: panelFrame.height - (region.maxY - panelFrame.minY),
                                     width: region.width, height: region.height)
            layer?.addSublayer(lumaLayer)
            tracker.onChange = { [weak self] value in self?.lumaChanged(value) }
            luma = tracker
        }
        CATransaction.commit()
        maskedFor = field
        return true
    }

    /// Fades the blur in or out. An implicit Core Animation transaction: nothing on the main thread
    /// runs while it plays.
    func setBlurVisible(_ visible: Bool, duration: TimeInterval) {
        guard let blurLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        blurLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    func tearDown() {
        blurLayer?.removeFromSuperlayer()
        blurLayer = nil
        luma?.layer?.removeFromSuperlayer()
        luma = nil
        maskedFor = nil
        outlineShown = false
    }

    /// Two thresholds rather than one, so a backdrop whose luminance sits on the line does not blink
    /// the outline.
    private func lumaChanged(_ value: Double) {
        let show = outlineShown
            ? value < NotchGeometry.outlineDisappearsAboveLuma
            : value < NotchGeometry.outlineAppearsBelowLuma
        guard show != outlineShown else { return }
        outlineShown = show
        Logger.drag.debug("snap bar backdrop luminance \(value, format: .fixed(precision: 3)); outline \(show ? "on" : "off", privacy: .public)")
        onOutlineOpacity?(show ? NotchGeometry.outlineOpacity : 0)
    }

    /// The blur field as a premultiplied RGBA bitmap whose alpha is `BackdropField.blurWeight`. Row 0
    /// is the top of the panel.
    private static func makeMask(field: BackdropField) -> CGImage? {
        let panelFrame = field.panel
        let width = max(1, Int((panelFrame.width * maskScale).rounded()))
        let height = max(1, Int((panelFrame.height * maskScale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = panelFrame.minY + (Double(row) + 0.5) / maskScale
            for column in 0..<width {
                let x = panelFrame.minX + (Double(column) + 0.5) / maskScale
                let value = UInt8((field.blurWeight(at: CGPoint(x: x, y: y)) * 255).rounded())
                let index = (row * width + column) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = value
            }
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
