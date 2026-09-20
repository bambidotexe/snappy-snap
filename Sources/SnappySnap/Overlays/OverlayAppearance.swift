import AppKit
import SwiftUI

/// The one colour every overlay *shape* is drawn in: the handle pill, the junction knob and the drop
/// preview's stroke. They are one family and hold one value between them, so a change cannot reach
/// two of them and miss the third.
///
/// It is stated per appearance and is **opaque in both**. macOS's own drop preview strokes with a
/// translucent grey, which composites to a different value over everything it crosses; an opaque
/// colour cannot track that and does not try to — `docs/pitfalls.md`, *An opaque stroke cannot match
/// a translucent one*.
enum OverlayAppearance {
    /// #E6E6E6 (sRGB 230/230/230) in the light appearance, #CFCFCF (sRGB 207/207/207) in the dark
    /// one. Both fitted by eye against the installed app, the dark one beside macOS's own preview.
    ///
    /// A dynamic `NSColor`, so it is resolved against the appearance of the view that draws it and
    /// follows a live System Settings switch with no observer of ours: `OverlayPanel` never sets its
    /// own `appearance`, so every overlay panel inherits the system's.
    static let shapeColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.812, green: 0.812, blue: 0.812, alpha: 1)
            : NSColor(srgbRed: 0.902, green: 0.902, blue: 0.902, alpha: 1)
    })
}
