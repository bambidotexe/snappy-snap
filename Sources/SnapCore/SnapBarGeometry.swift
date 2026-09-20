import CoreGraphics

/// Layout of the snap bar panel in CG space, shared by hit testing and drawing.
public struct SnapBarGeometry: Hashable, Sendable {
    public static let cellSize = CGSize(width: 96, height: 64)
    public static let spacing: Double = 8
    public static let padding: Double = 12
    public static let innerGap: Double = 3
    /// The cell's corner: the working area a layout stands for.
    public static let cellRadius: Double = 8
    /// A zone corner that faces a seam, or that touches only one of the cell's edges.
    public static let zoneRadius: Double = 4
    /// A zone corner that sits at a corner of the cell, **concentric** with the cell's own corner so
    /// the rim between the two curves is even the whole way round. Two corners `innerGap` apart with
    /// the *same* radius are not parallel: the inner curve converges on the outer one through the
    /// bend, and the rim reads thinner there than along the straight edges.
    public static let zoneOuterRadius: Double = cellRadius - innerGap
    /// How far a zone's edge may sit from the cell's inset edge and still count as lying on it.
    /// `Geometry` never rounds, so a zone's coordinates carry the layout's own arithmetic.
    public static let cornerTolerance: Double = 0.5
    /// Distance from the working area's top edge to the bar's top edge: the two bands the
    /// eye reads there — menu bar to the preview's stroke, and that stroke to the bar — are both one
    /// `gap`. The stroke sits inside the zone rect, whose top is already `gap` down, so clearing it
    /// costs `gap + strokeWidth` and the matching band below costs another `gap`. It follows the gap
    /// setting: a fixed inset would leave the bar above the very border it exists to clear at gap 24.
    public static func topInset(gap: Double) -> Double { gap + ZonePreview.strokeWidth + gap }
    public static let hideMargin: Double = 16
    /// Side of the partner app's icon in the pair cell. The half it sits in is 43.5×58 pt
    /// at the built-in cell size, so 24 reads as an app icon without crowding the zone it labels.
    public static let pairIconSide: Double = 24

    public let layouts: [Layout]
    /// The conditional **first** cell, or nil when there is no window to pair with. A non-nil
    /// one prepends a cell: it shifts every layout cell one slot to the right and widens the bar by
    /// `cellSize.width + spacing`. It is not padded to keep a constant width — the bar's width follows
    /// the cell count.
    ///
    /// Every accessor below still indexes `layouts`, so `cellRect(0)` is the halves layout's cell with
    /// the pair cell or without it; the pair cell has accessors of its own. Callers therefore never
    /// have to know whether the indices are shifted, which is the whole reason the shift is private.
    public let pairCell: PairCell?
    public let displayID: UInt32
    /// The bar's hit region: the floating bar's own rect, or the notch shape or the island grown to hold
    /// the row.
    public let frame: CGRect
    /// The panel the bar is drawn in, which is what every `local…` rect below is relative to. The
    /// floating bar's panel *is* its frame; the notch shape's and the island's are larger than the shape
    /// and do not move while the shape grows inside it.
    public let panelFrame: CGRect
    /// Where the first cell's top-left corner goes.
    private let rowOrigin: CGPoint
    /// Non-nil exactly when the bar is drawn in the notch shape: the notch appearance on a display with a
    /// camera housing.
    public let notch: NotchGeometry?
    /// Non-nil exactly when the bar is drawn in the island: the notch appearance on a display with no
    /// camera housing. Never set together with `notch`.
    public let island: IslandGeometry?
    /// What this geometry draws the bar as.
    public var surface: SnapBarSurface {
        if island != nil { return .island }
        return notch == nil ? .floatingBar : .notchShape
    }
    /// The band this bar armed on, kept so it releases on the same number it armed on.
    public let edgeBand: Double

    /// Takes the whole `Settings` rather than the two numbers it reads, so the bar cannot arm on a
    /// different band from the one `ZoneResolver` resolves the top zone with — the point is that
    /// they are the same test.
    public init(layouts: [Layout], display: DisplayInfo, settings: Settings, pairCell: PairCell? = nil) {
        self.layouts = layouts
        self.pairCell = pairCell
        self.displayID = display.id
        self.edgeBand = settings.edgeBand
        let n = Double(layouts.count + (pairCell == nil ? 0 : 1))
        let rowWidth = n * Self.cellSize.width + max(0, n - 1) * Self.spacing
        switch settings.snapBarAppearance.surface(on: display) {
        case .floatingBar:
            let width = Self.padding * 2 + rowWidth
            let height = Self.padding * 2 + Self.cellSize.height
            frame = CGRect(x: display.frame.midX - width / 2,
                           y: display.visibleFrame.minY + Self.topInset(gap: settings.gap),
                           width: width, height: height)
            panelFrame = frame
            rowOrigin = CGPoint(x: frame.minX + Self.padding, y: frame.minY + Self.padding)
            notch = nil
            island = nil
        case .notchShape, .island:
            // The housing decides between the two, and `NotchGeometry` is what reads it: it is nil
            // exactly where the surface is the island.
            let rowSize = CGSize(width: rowWidth, height: Self.cellSize.height)
            if let geometry = NotchGeometry(display: display, rowSize: rowSize) {
                frame = geometry.expanded
                panelFrame = geometry.panel
                rowOrigin = geometry.rowOrigin(rowWidth: rowWidth)
                notch = geometry
                island = nil
            } else {
                let geometry = IslandGeometry(display: display, rowSize: rowSize)
                frame = geometry.expanded
                panelFrame = geometry.panel
                rowOrigin = geometry.rowOrigin(rowWidth: rowWidth)
                notch = nil
                island = geometry
            }
        }
    }

    /// How many slots the pair cell occupies at the head of the bar: one when it is shown, none when it
    /// is not. The one place the shift is written down.
    private var leadingSlots: Int { pairCell == nil ? 0 : 1 }

    /// The nth cell of the bar counting from its left edge, pair cell included. Private: `cellRect` and
    /// `pairCellRect` are the two public ways in, and neither exposes the slot numbering.
    private func slotRect(_ slot: Int) -> CGRect {
        CGRect(
            x: rowOrigin.x + Double(slot) * (Self.cellSize.width + Self.spacing),
            y: rowOrigin.y,
            width: Self.cellSize.width,
            height: Self.cellSize.height
        )
    }

    /// The cell of `layouts[index]`, shifted one slot right when the pair cell is shown.
    public func cellRect(_ index: Int) -> CGRect { slotRect(index + leadingSlots) }

    /// The pair cell, first in the bar, or nil when it is not shown.
    public var pairCellRect: CGRect? { pairCell == nil ? nil : slotRect(0) }

    /// One half of the pair cell as it is **drawn** — same `innerGap`, same arithmetic as a layout's
    /// zone, because it *is* the halves layout's cell (see `PairCell`). Nothing hit-tests against it:
    /// the pair cell is one region and `hit` answers for the whole of `pairCellRect`.
    public func pairZoneRect(cellIndex: Int) -> CGRect? {
        guard let cell = pairCellRect, PairCell.layout.cells.indices.contains(cellIndex) else { return nil }
        return Geometry.frame(for: PairCell.layout.cells[cellIndex], in: cell, gap: Self.innerGap)
    }

    public func zoneRect(layoutIndex: Int, cellIndex: Int) -> CGRect {
        Geometry.frame(for: layouts[layoutIndex].cells[cellIndex], in: cellRect(layoutIndex), gap: Self.innerGap)
    }

    /// The same zone as a **target**: the identical arithmetic with no gap, so a layout's zones tile
    /// their cell edge to edge. `zoneRect` is what is drawn, inset by `innerGap` so the eye reads a
    /// rim inside the cell and a seam between zones; neither is a strip the pointer has to find. The
    /// seam splits down its middle between the two zones it separates and the rim belongs to the zone
    /// it borders, so sweeping across a cell hands one zone straight to the next.
    ///
    /// Deliberately not a named `hitGap` constant beside `innerGap`: any value but zero puts the dead
    /// strip back.
    private func hitZoneRect(layoutIndex: Int, cellIndex: Int) -> CGRect {
        Geometry.frame(for: layouts[layoutIndex].cells[cellIndex], in: cellRect(layoutIndex), gap: 0)
    }

    /// The zone of `layouts[layoutIndex]` whose hit region's centre is nearest `point`, ties going to
    /// the lowest cell index.
    ///
    /// The fallback for a point a cell claims that no hit region does. A layout whose cells tile the
    /// unit square leaves only its own far edge, which `CGRect.contains` excludes and rounding can put
    /// a fraction short of the cell's; a hand-edited `Layouts.json` is validated for bounds but never
    /// for coverage, so it may leave a hole anywhere. Either way the rule is the same — no point
    /// inside a cell resolves to the bar's background.
    ///
    /// Only ever consulted once containment has found nothing: for cells of unequal size, nearest by
    /// centre disagrees with containment well inside the larger one.
    private func nearestZoneIndex(to point: CGPoint, layoutIndex: Int) -> Int? {
        layouts[layoutIndex].cells.indices.min {
            Self.squaredDistanceToCentre(of: hitZoneRect(layoutIndex: layoutIndex, cellIndex: $0), from: point)
                < Self.squaredDistanceToCentre(of: hitZoneRect(layoutIndex: layoutIndex, cellIndex: $1), from: point)
        }
    }

    private static func squaredDistanceToCentre(of rect: CGRect, from point: CGPoint) -> Double {
        let dx = rect.midX - point.x, dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    /// Panel-relative rects (origin top-left of the panel, y down) for SwiftUI.
    public func localCellRect(_ index: Int) -> CGRect { cellRect(index).offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY) }

    public func localZoneRect(layoutIndex: Int, cellIndex: Int) -> CGRect {
        zoneRect(layoutIndex: layoutIndex, cellIndex: cellIndex).offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
    }

    public var localPairCellRect: CGRect? {
        pairCellRect.map { $0.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY) }
    }

    /// The four radii a drawn zone's corners take, named for a left-to-right layout.
    public struct ZoneCornerRadii: Hashable, Sendable {
        public let topLeading: Double
        public let bottomLeading: Double
        public let bottomTrailing: Double
        public let topTrailing: Double
    }

    /// A zone corner that coincides with a corner of its cell is rounded `zoneOuterRadius`, concentric
    /// with the cell's own corner; every other corner keeps `zoneRadius`.
    ///
    /// **Both** of a corner's coordinates must lie on the cell's inset bounds. A corner matching on one
    /// axis only is halfway along one of the cell's edges, facing a seam across the other, and a wide
    /// corner there would round away from a neighbour it is meant to sit flush beside.
    ///
    /// Takes the cell rather than the layout so the pair cell — whose halves come from `PairCell` and
    /// not from `layouts` — is rounded by the same rule as everything else.
    public static func zoneCornerRadii(zone: CGRect, in cell: CGRect) -> ZoneCornerRadii {
        let inner = cell.insetBy(dx: innerGap, dy: innerGap)
        let atLeading = abs(zone.minX - inner.minX) < cornerTolerance
        let atTrailing = abs(zone.maxX - inner.maxX) < cornerTolerance
        let atTop = abs(zone.minY - inner.minY) < cornerTolerance
        let atBottom = abs(zone.maxY - inner.maxY) < cornerTolerance
        func radius(_ isCellCorner: Bool) -> Double { isCellCorner ? zoneOuterRadius : zoneRadius }
        return ZoneCornerRadii(topLeading: radius(atTop && atLeading),
                               bottomLeading: radius(atBottom && atLeading),
                               bottomTrailing: radius(atBottom && atTrailing),
                               topTrailing: radius(atTop && atTrailing))
    }

    /// Both halves of the pair cell in panel-relative order, or empty when it is not shown — so the
    /// view iterates it instead of unwrapping one rect per half.
    public var localPairZoneRects: [CGRect] {
        guard pairCell != nil else { return [] }
        return PairCell.layout.cells.indices.compactMap {
            pairZoneRect(cellIndex: $0)?.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        }
    }

    /// Where one half's app icon goes: centred in that half, so the user sees both windows the drop
    /// pairs — the dragged one at `PairCell.draggedCellIndex`, the partner at
    /// `PairCell.partnerCellIndex`. One function for both halves rather than one property each,
    /// because the two icons are the same size and the same centring and differ only in which half
    /// they sit in; a second body is a second place for them to drift apart.
    ///
    /// Panel-relative, because only the view reads it — but it is geometry, so it is here and
    /// unit-tested rather than computed in a SwiftUI body. Nil for any index the cell does not have,
    /// and for every index while the cell is not shown.
    public func localPairIconRect(cellIndex: Int) -> CGRect? {
        guard let zone = pairZoneRect(cellIndex: cellIndex)?
            .offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY) else { return nil }
        return CGRect(x: zone.midX - Self.pairIconSide / 2, y: zone.midY - Self.pairIconSide / 2,
                      width: Self.pairIconSide, height: Self.pairIconSide)
    }

    public func hit(_ point: CGPoint) -> SnapBarHit? {
        guard frame.contains(point) else { return nil }
        // The pair cell first, because it is the first cell — and the **whole** cell, not its two drawn
        // halves: the pair cell is one drop region with fixed sides, so the gap between the halves
        // belongs to it rather than falling through to the bar's background (which would resolve to
        // Fill). This is also why it is `pairCellRect` and not `pairZoneRect` — the halves exist only to
        // be drawn. When the cell is not shown `pairCellRect` is nil and nothing here matches it.
        if pairCellRect?.contains(point) == true { return .pair }
        // A cell owns every point inside it. The cell rect is tested first so that the bar's two kinds
        // of empty space — the padding around the row and the spacing between two cells — cannot be
        // claimed by a neighbour's hit region, and still resolve to Fill.
        for (li, layout) in layouts.enumerated() where cellRect(li).contains(point) {
            for ci in layout.cells.indices where hitZoneRect(layoutIndex: li, cellIndex: ci).contains(point) {
                return .cell(layoutIndex: li, cellIndex: ci)
            }
            if let ci = nearestZoneIndex(to: point, layoutIndex: li) { return .cell(layoutIndex: li, cellIndex: ci) }
        }
        return .background
    }

    /// Within `band` of the display's top edge. With `settings.edgeBand` this is the arming rule and
    /// is the identical test `ZoneResolver` uses for the top zone, so the bar and the Fill
    /// preview appear on the same event; with the release hysteresis added it is the first hide clause.
    static func isWithinTopBand(cursor: CGPoint, display: DisplayInfo, band: Double) -> Bool {
        cursor.y - display.frame.minY <= band
    }

    /// Arming for a bar that does not exist yet. It needs no panel and no geometry, so the hidden
    /// path builds nothing per event.
    ///
    /// The floating bar arms on the top zone's own test. The notch shape and the island arm where
    /// they are — the camera housing, or on a display with none the island's capsule and the strip
    /// above it — while the top zone keeps the whole edge, so in that appearance Fill is offered along
    /// the edge and the bar only where the shape is.
    public static func isWithinArmingBand(cursor: CGPoint, display: DisplayInfo, settings: Settings) -> Bool {
        switch settings.snapBarAppearance.surface(on: display) {
        case .floatingBar: isWithinTopBand(cursor: cursor, display: display, band: settings.edgeBand)
        case .notchShape, .island: (display.housing ?? IslandGeometry.armRegion(of: display)).contains(cursor)
        }
    }

    /// Armed within `edgeBand` of the display's top edge; once visible it stays while
    /// **either** the cursor is still within `edgeBand + releaseHysteresis` of that edge — the same
    /// release the top zone uses — **or** it is within `hideMargin` of the bar horizontally and no
    /// lower than the bar's bottom edge plus `hideMargin`. The second clause is what lets the cursor
    /// travel down into the bar: the bar sits below the release band. Both regions start at the
    /// display's top edge, so their union is contiguous whatever the gap does to the bar's position.
    ///
    /// `display` must be the display this geometry was built for — the second clause mixes the band,
    /// which is measured against `display`, with `frame`, which is fixed to `displayID`. Nothing here
    /// enforces it; the sole caller (`SnapBarController.update`) reaches this only inside
    /// `current.displayID == display.id`, and a bar on another display is rebuilt rather than asked.
    public func shouldShow(cursor: CGPoint, display: DisplayInfo, visible: Bool) -> Bool {
        // The notch shape: armed inside the housing, kept while the pointer is inside the grown shape
        // plus `hideMargin` on the three sides that are not the screen's edge. The housing is inside
        // that region, so there is no strip where the shape opens and closes again.
        if let notch {
            if notch.housing.contains(cursor) { return true }
            return visible && notch.stayRegion(margin: Self.hideMargin).contains(cursor)
        }
        // The island: armed inside its capsule and the strip above it, kept while the pointer is
        // inside the grown shape plus `hideMargin` on its left, right and bottom and up to the
        // screen's edge. The arming region is inside that one.
        if let island {
            if island.armRegion.contains(cursor) { return true }
            return visible && island.stayRegion(margin: Self.hideMargin).contains(cursor)
        }
        if Self.isWithinTopBand(cursor: cursor, display: display, band: edgeBand) { return true }
        guard visible else { return false }
        if Self.isWithinTopBand(cursor: cursor, display: display, band: edgeBand + ZoneResolver.releaseHysteresis) {
            return true
        }
        return cursor.x >= frame.minX - Self.hideMargin
            && cursor.x <= frame.maxX + Self.hideMargin
            && cursor.y <= frame.maxY + Self.hideMargin
    }
}
