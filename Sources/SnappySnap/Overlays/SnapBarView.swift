import SwiftUI
import SnapCore

@MainActor
final class SnapBarModel: ObservableObject {
    @Published var geometry: SnapBarGeometry
    @Published var highlighted: SnapBarHit?
    /// The pair cell's two app icons: the dragged window's, drawn in the left half, and the partner's,
    /// drawn in the right. Icons, not thumbnails: the app never asks for Screen Recording, and
    /// `NSRunningApplication.icon` needs no permission at all. Either may be nil — an application whose
    /// icon does not resolve leaves its half plain and takes nothing else with it.
    @Published var draggedIcon: NSImage?
    @Published var partnerIcon: NSImage?
    /// The notch shape only: whether the shape is grown to hold the cells. Set inside
    /// `withAnimation`, so the one assignment drives the shape, its shadow and its radii together.
    @Published var expanded = false
    /// The notch shape and the island: the contrast outline's opacity, 0 while the backdrop is light
    /// enough to read the shape against.
    @Published var outlineOpacity: Double = 0
    /// The island only: the state its shape is drawn in. Set inside `withAnimation` by the panel, one
    /// step of `IslandPresence` at a time, so the one assignment drives the shape, its radius, its
    /// scale and its shadow together.
    @Published var island: IslandState = .hidden
    /// The island only: how long the cells take to leave — their own fade, or the shared interruption
    /// fade when the drag was interrupted.
    @Published var cellsFadeOut: Double = IslandPresence.cellsFadeOut

    init(geometry: SnapBarGeometry) {
        self.geometry = geometry
    }
}

/// The snap bar in whichever appearance its geometry was built for: a floating Liquid Glass bar, the
/// notch shape, or the island. The cells are the same view in all three.
struct SnapBarView: View {
    @ObservedObject var model: SnapBarModel

    var body: some View {
        if model.geometry.notch != nil {
            NotchBarView(model: model)
        } else if model.geometry.island != nil {
            IslandBarView(model: model)
        } else {
            SnapBarCells(model: model, palette: .floatingBar)
                .frame(width: model.geometry.frame.width, height: model.geometry.frame.height,
                       alignment: .topLeading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// The two colours a cell is drawn in, one pair per appearance, because the two stand on different
/// ground. The highlighted zone is `Color.accentColor` in both and is deliberately not part of this:
/// a highlight is one colour across the whole app, not a property of the surface showing it.
///
/// Colours live here and not in `SnapCore`, which never imports SwiftUI. What is decidable without
/// asking macOS is the geometry, and that is `SnapBarGeometry`'s.
struct SnapBarCellPalette {
    /// The cell: the working area the layout stands for. Drawn behind the zones, so what is seen of it
    /// is the `innerGap` rim and the seams — the layout's outline.
    let workingArea: Color
    /// An un-highlighted zone inside the cell.
    let zone: Color

    /// On Liquid Glass. Translucent and `Color.primary`, so the layout carries the glass's own tone
    /// and follows the system appearance instead of fixing a grey that only suits one of them.
    static let floatingBar = SnapBarCellPalette(workingArea: Color.primary.opacity(0.09),
                                                zone: Color.primary.opacity(0.20))
    /// On the notch's pure black shape. Opaque, and fixed rather than `Color.primary`: the shape is
    /// black in either system appearance, and the outline is darker than the zones so a layout reads
    /// as light windows inside a darker display rather than as one bright slab on the black.
    static let notch = SnapBarCellPalette(workingArea: Color(white: 0.28),
                                          zone: Color(white: 0x77 / 255.0))
}

/// One cell per layout, preceded by the pair cell when there is a window to pair with; the hovered
/// zone is tinted with the accent color. Every rect is panel-relative and comes from
/// `SnapBarGeometry`, so the cells sit where the hit test says they are on every surface.
struct SnapBarCells: View {
    @ObservedObject var model: SnapBarModel
    let palette: SnapBarCellPalette

    var body: some View {
        let g = model.geometry
        ZStack(alignment: .topLeading) {
            pairCell(g)
            ForEach(Array(g.layouts.enumerated()), id: \.offset) { li, layout in
                cellBackdrop(g.localCellRect(li))
                ForEach(layout.cells.indices, id: \.self) { ci in
                    zone(g.localZoneRect(layoutIndex: li, cellIndex: ci), in: g.localCellRect(li),
                         on: model.highlighted == .cell(layoutIndex: li, cellIndex: ci))
                }
            }
        }
    }

    /// The pair cell: **one** zone drawn as two halves, each carrying its window's application icon —
    /// the dragged window's on the left, the partner's on the right, which is what tells the user
    /// which two windows the single drop places and where each one lands. Every rect comes from
    /// `SnapBarGeometry`, so there is no second opinion about where a half is.
    ///
    /// Both halves light together, from the single `.pair` hit: the cell is one drop region with fixed
    /// sides, so highlighting the half under the cursor would be showing a choice the user does not
    /// have. There is no per-half state here to get that wrong with.
    @ViewBuilder
    private func pairCell(_ g: SnapBarGeometry) -> some View {
        if let cell = g.localPairCellRect {
            let on = model.highlighted == .pair
            cellBackdrop(cell)
            ForEach(Array(g.localPairZoneRects.enumerated()), id: \.offset) { _, z in
                zone(z, in: cell, on: on)
            }
            pairIcon(model.draggedIcon, box: g.localPairIconRect(cellIndex: PairCell.draggedCellIndex))
            pairIcon(model.partnerIcon, box: g.localPairIconRect(cellIndex: PairCell.partnerCellIndex))
        }
    }

    /// One half's icon, or nothing when either the icon or the half is absent. Both halves draw
    /// through here so they can differ only in which application and which rect, never in size or
    /// rendering.
    @ViewBuilder
    private func pairIcon(_ icon: NSImage?, box: CGRect?) -> some View {
        if let icon, let box {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
        }
    }

    private func cellBackdrop(_ cell: CGRect) -> some View {
        RoundedRectangle(cornerRadius: SnapBarGeometry.cellRadius, style: .continuous)
            .fill(palette.workingArea)
            .frame(width: cell.width, height: cell.height)
            .offset(x: cell.minX, y: cell.minY)
    }

    /// Which corners round wide is `SnapBarGeometry`'s to decide — it is a function of the two rects
    /// and nothing else — so this view asks rather than repeating the test against the same rects the
    /// hit test uses.
    private func zone(_ z: CGRect, in cell: CGRect, on: Bool) -> some View {
        let radii = SnapBarGeometry.zoneCornerRadii(zone: z, in: cell)
        return UnevenRoundedRectangle(topLeadingRadius: radii.topLeading,
                                      bottomLeadingRadius: radii.bottomLeading,
                                      bottomTrailingRadius: radii.bottomTrailing,
                                      topTrailingRadius: radii.topTrailing,
                                      style: .continuous)
            .fill(on ? Color.accentColor : palette.zone)
            .frame(width: z.width, height: z.height)
            .offset(x: z.minX, y: z.minY)
            .animation(.easeOut(duration: 0.1), value: on)
    }
}
