import CoreGraphics

/// The **pair cell**: the snap bar's conditional first cell, which fills the display with
/// *two* windows in one drop — the dragged window on the left and the partner, the most recently
/// focused other window, on the right. This is the Windows 11 flyout's leading
/// blue-zone-plus-app-icon cell.
///
/// **One zone, drawn as two rectangles.** The sides are fixed: dragged left, partner right, always.
/// The cell offers no choice of side, so it has no left target and no right target — the whole cell is
/// a single drop region, the gap between the halves included, and hovering anywhere in it lights both
/// halves at once. That is a rule and not an implementation shortcut: a cell that
/// looks like two targets but means one must not answer differently at two points inside itself, and a
/// cursor crossing the middle must not drop and re-acquire the zone or replay the preview's appear
/// animation. Having exactly one hit case is what makes all of that true by construction rather than by
/// a tolerance.
///
/// Pure, and deliberately ignorant of *who* the partner is: whether there is one at all is the
/// eligible-window rule, which needs Accessibility and therefore lives in the app layer. What this type
/// owns is the arithmetic, and the one thing that arithmetic must never invent — the cell **is** the
/// halves layout. Both zones come from `Geometry.zone` with `LayoutCatalog.halves`, so a pair drop and
/// a drop on the bar's halves cell place the windows in identical frames *and* record identical
/// `Zone`s. That identity is the point rather than a convenience: a window paired into a half has to be
/// indistinguishable afterwards from one snapped there by hand, or `SnapRegistry`'s drag-away restore
/// and the handle bar would each see two kinds of half-screen window and have to tell them apart.
///
/// Held for a whole drag (`SnapBarController`) and read at the drop (`ZoneResolver`), so it is a value:
/// the gap it was built with is the gap the drop uses, whatever the settings do in between.
public struct PairCell: Hashable, Sendable {
    /// The arrangement the cell offers. Not a copy of the halves geometry — the halves layout itself.
    public static let layout: Layout = LayoutCatalog.halves

    /// The fixed sides: dragged left, partner right. Constants rather than a choice — the side never
    /// depends on where in the cell the release lands.
    ///
    /// Each index is also the half that window's application icon is drawn in, which is how the user
    /// reads the cell: the two icons name the two windows the one drop places, in the order they land.
    public static let draggedCellIndex = 0
    public static let partnerCellIndex = 1

    public let displayID: UInt32
    /// Where the window the user is dragging lands: the left half.
    public let dragged: Zone
    /// Where the partner lands: the right half.
    public let partner: Zone

    /// The cell as the bar shows it, or nil when there is nothing to pair with — with none, the cell
    /// is absent and the bar begins at the halves layout. `hasPartner` is the app layer's answer to
    /// the eligible-window rule; everything after it is arithmetic.
    public init?(hasPartner: Bool, display: DisplayInfo, gap: Double) {
        guard hasPartner else { return nil }
        self.init(display: display, gap: gap)
    }

    public init(display: DisplayInfo, gap: Double) {
        func zone(_ cellIndex: Int) -> Zone {
            Geometry.zone(display: display, layout: Self.layout, cellIndex: cellIndex, gap: gap)
        }
        displayID = display.id
        dragged = zone(Self.draggedCellIndex)
        partner = zone(Self.partnerCellIndex)
    }
}
