import CoreGraphics

/// Where the handle bar's pill and its panel go, in CG space. The controller owns the polling and the
/// Accessibility writes; every number the user can see is here, and tested.
public enum HandleBarGeometry {
    /// Minimum thickness of the band that shows the handle and catches the press. It is also the
    /// thickness `AdjacencyDetector` asks its occlusion question with, so the region a pair is
    /// *offered* for and the region it is *hit* in are the same one.
    public static let bandThickness: Double = 10
    /// Measured off macOS's own tiling handle rather than chosen: its pill is 8 px thick and 96 px
    /// long in a 2× capture — **4 pt by 48 pt** — with the window gap in the same screenshot giving
    /// the scale. The *hit* band is a separate number and does not shrink with this
    /// (`bandThickness`), which is what both macOS and Windows do: a small drawn target with a
    /// generous grab region.
    public static let pillThickness: Double = 4
    public static let maxPillLength: Double = 48
    /// Below this the pill stops shrinking: a 60 pt overlap (the default `handleMinOverlap`) would
    /// otherwise leave a 44 pt pill, and the smallest overlap the setting allows is 20.
    public static let minPillLength: Double = 24
    /// How much shorter than the overlap the pill is, so the two windows' corners stay visible.
    public static let pillEndInset: Double = 16
    /// How thick the panel is across the divider **while it is being dragged**.
    ///
    /// Measured, not guessed: over a 600 ms drag the panel lags the pointer that is moving it, and
    /// the pointer left and re-entered the 10 pt band five times. Every one of those exits hands the
    /// cursor back to the window underneath, which is free to put its own I-beam up until the panel
    /// catches up. The panel is invisible outside the pill, the button is down for the whole of it,
    /// and it shrinks back on mouse-up, so the only thing this width costs is nothing.
    public static let dragBandThickness: Double = 96

    /// `min(maxPillLength, overlap − pillEndInset)`, floored at `minPillLength` so a short overlap
    /// still shows a grabbable pill — and never longer than the overlap itself, which the floor alone
    /// would allow. `handleMinOverlap` goes down to 20, and a 24 pt pill in a 20 pt panel is a pill
    /// with its ends cut off.
    public static func pillLength(overlap: Double) -> Double {
        min(overlap, min(maxPillLength, max(minPillLength, overlap - pillEndInset)))
    }

    public static func pillSize(orientation: HandlePair.Orientation, overlap: Double) -> CGSize {
        let length = pillLength(overlap: overlap)
        switch orientation {
        case .horizontal: return CGSize(width: pillThickness, height: length)
        case .vertical: return CGSize(width: length, height: pillThickness)
        }
    }

    /// The pair's hover band as it stands.
    public static func band(for pair: HandlePair) -> CGRect {
        pair.hoverBand(minThickness: bandThickness)
    }

    /// The same band re-centred on `divider`. A drag moves the divider without changing the overlap
    /// — only the two windows' widths (or heights) change — so the band keeps its length and slides.
    public static func band(for pair: HandlePair, divider: Double) -> CGRect {
        var rect = band(for: pair)
        switch pair.orientation {
        case .horizontal: rect.origin.x = divider - rect.width / 2
        case .vertical: rect.origin.y = divider - rect.height / 2
        }
        return rect
    }

    /// The panel's frame. **Exactly the band** while the handle rests, widened across the divider
    /// while it is dragged so the pointer cannot outrun it.
    ///
    /// Exactly the band, and not a point more, because the panel takes mouse events: every point it
    /// covers is a point the window underneath stops receiving clicks at, and a press there would do
    /// nothing at all — `handle(.down)` would decline it and `DragSessionController` would then reject
    /// our own pid. One rect is drawn, hovered and pressed, so there is no region where those three
    /// disagree. The cost is the outer sliver of the pill's shadow: the pill is `pillThickness` (4 pt)
    /// in a band of at least `bandThickness` (10), so the shadow is clipped from 5 pt off its centre —
    /// 3 pt beyond the pill's edge, where a 3 pt-radius shadow at 35 % is already under 2 % opacity.
    public static func panelRect(for pair: HandlePair, divider: Double, dragging: Bool = false) -> CGRect {
        let rect = band(for: pair, divider: divider)
        guard dragging else { return rect }
        switch pair.orientation {
        case .horizontal:
            return CGRect(x: divider - dragBandThickness / 2, y: rect.minY,
                          width: dragBandThickness, height: rect.height)
        case .vertical:
            return CGRect(x: rect.minX, y: divider - dragBandThickness / 2,
                          width: rect.width, height: dragBandThickness)
        }
    }

    /// The middle of the gap band two frames leave between them — where the pill belongs when those
    /// frames are the ones actually on screen.
    ///
    /// A handle drag draws its own outcome: the two previews are drawn at `roundedToPoints()` frames
    /// while `HandleDragMath.Result.divider` is not rounded at all. One pointer sample, one pass, two
    /// different roundings would be up to half a point of disagreement, resampled on every pointer
    /// event — a visible jiggle in the pill. Asking the frames that are drawn where their gap is makes
    /// the pill a function of the same numbers rather than of a parallel calculation. It is not
    /// feedback from a *window*: these are the overlay's own frames, computed from the pointer and
    /// nothing else.
    public static func divider(between a: CGRect, and b: CGRect, orientation: HandlePair.Orientation) -> Double {
        switch orientation {
        case .horizontal: (a.maxX + b.minX) / 2
        case .vertical: (a.maxY + b.minY) / 2
        }
    }

    /// Both windows' centres on one display. Two windows at the seam between two displays can sit
    /// within `handleMaxGap` of each other in the global coordinate space and are not adjacent in any
    /// sense the user means: resizing them together would drag one window on each screen.
    public static func isWithinOneDisplay(_ pair: HandlePair, displays: [DisplayInfo]) -> Bool {
        guard let display = displays.first(where: { $0.frame.contains(pair.a.frame.center) }) else { return false }
        return display.frame.contains(pair.b.frame.center)
    }
}
