import CoreGraphics
import Foundation

/// What the cursor is over in the snap bar.
public enum SnapBarHit: Hashable, Sendable {
    case cell(layoutIndex: Int, cellIndex: Int)
    /// The conditional pair cell — the bar's first cell, shown only when there is another window to
    /// pair with. **One case with no payload, on purpose**: the whole cell is a single drop region,
    /// including the space between its two halves, and the sides are fixed (dragged left, partner
    /// right). There is deliberately nothing here to say *which* half the cursor is over, because
    /// nothing downstream is allowed to care.
    case pair
    case background
}

/// Where a resolution came from. Snap Assist turns on this and nothing else: it runs after a drop
/// made from the snap bar, and never after a plain edge, corner or top snap.
public enum ZoneOrigin: Hashable, Sendable {
    /// A cell of the snap bar, or its background — the user picked a layout outright.
    case snapBar
    /// The pair cell, which fills *both* halves of the display in one drop.
    ///
    /// Its own case rather than `.snapBar`, and that is what stops Snap Assist from running after a
    /// pair drop. The reason is sharper than "the layout is full": a phase offers every cell of the
    /// layout *but the drop's own*, occupied or not — so after a pair drop the only cell it could
    /// offer is the one the partner has just been placed in, and clearing the desktop for it would
    /// park the very window this gesture placed.
    case pairCell
    /// An edge, a corner or the top of a display.
    case screenEdge
}

public struct ZoneResolution: Hashable, Sendable {
    public var zone: Zone
    /// Defaults to `.screenEdge`, which is what every path but the bar's resolves to. The default is
    /// the safe one: a resolution that forgot to say where it came from starts no choosing phase,
    /// rather than starting one after an ordinary edge snap.
    public var origin: ZoneOrigin
    /// The facing half a pair drop **also** fills, with the partner window. Nil for every other
    /// resolution, including a plain drop on the bar's halves cell.
    ///
    /// It rides along with the zone so that the drop reads one answer to "what does this gesture place,
    /// and where": by the time the window lands the bar is gone, and re-deriving the second half from a
    /// hit that no longer exists is how the two halves would come to disagree.
    public var partnerZone: Zone?

    public init(zone: Zone, origin: ZoneOrigin = .screenEdge, partnerZone: Zone? = nil) {
        self.zone = zone
        self.origin = origin
        self.partnerZone = partnerZone
    }
}

/// Turns a cursor position into a drop zone. Priority: snap bar › corner › side › top, and with
/// Option held snap bar › corner › top › the grown halves — top moves ahead of the halves there
/// because a half that reaches the middle of the display would otherwise swallow the top band and
/// leave Fill unreachable.
public enum ZoneResolver {
    /// Extra distance an active zone survives beyond the edge's own band, so the boundary never flickers.
    public static let releaseHysteresis: Double = 12

    /// `stickyBand` is 0 while no zone is active and `releaseHysteresis` while one is. An outer edge
    /// activates within `settings.edgeBand`, an edge shared with another display within
    /// `settings.sharedEdgeBand`; nothing else about a shared edge differs.
    /// `pairCell` is the bar's conditional first cell as it is actually showing it — nil when the bar
    /// has none. It is handed in rather than rebuilt here so that the cell the user aimed at and the
    /// zones the drop fills are one value: the bar holds it for the whole drag, and a gap setting changed
    /// mid-drag cannot move the halves out from under the cursor.
    ///
    /// `optionHeld` grows the side halves until they meet at `display.frame.midX`, whatever the edges'
    /// own bands. Corners and the top Fill zone keep their own bands untouched, and Fill is resolved
    /// ahead of the grown halves so that it stays reachable. The two switches it needs — `optionHalves`
    /// and `sideHalves` — are asked here rather than at the call site, so the rule is one place.
    public static func resolve(
        cursor: CGPoint,
        display: DisplayInfo,
        sharedEdges: Set<Edge>,
        barHit: SnapBarHit?,
        snapBarLayouts: [Layout],
        pairCell: PairCell? = nil,
        gap: Double,
        settings: Settings,
        stickyBand: Double = 0,
        optionHeld: Bool = false
    ) -> ZoneResolution? {
        func zone(_ layout: Layout, _ index: Int) -> Zone {
            Geometry.zone(display: display, layout: layout, cellIndex: index, gap: gap)
        }

        if settings.snapBar, let hit = barHit {
            switch hit {
            case .background:
                return ZoneResolution(zone: zone(LayoutCatalog.fill, 0), origin: .snapBar)
            case .cell(let li, let ci):
                guard li < snapBarLayouts.count, ci < snapBarLayouts[li].cells.count else { return nil }
                return ZoneResolution(zone: zone(snapBarLayouts[li], ci), origin: .snapBar)
            case .pair:
                // Only a bar that has the cell can report this hit, and the resolver is handed the cell
                // rather than taking that on trust: a `.pair` hit with no cell resolves to nothing,
                // which drops the snap instead of placing a window for a gesture nobody could have made.
                //
                // One answer for the whole cell, so every point in it — both halves and the gap between
                // them — resolves to the *same* `ZoneResolution`. That is what keeps the zone from being
                // dropped and re-acquired as the cursor crosses the middle, and what stops the preview
                // replaying its appear animation mid-hover: `DragSessionController` compares the whole
                // resolution, and here there is only one to compare against.
                guard let pairCell else { return nil }
                return ZoneResolution(zone: pairCell.dragged,
                                      origin: .pairCell, partnerZone: pairCell.partner)
            }
        }

        let f = display.frame

        /// Whether the cursor is inside `edge`'s band. A shared edge's band is the wider one; every
        /// other rule of the zone is the same on both, so a display behaves the same way whether it
        /// stands alone or has a neighbour.
        func touching(_ edge: Edge) -> Bool {
            let band = sharedEdges.contains(edge) ? settings.sharedEdgeBand : settings.edgeBand
            let distance: Double = switch edge {
            case .left: cursor.x - f.minX
            case .right: f.maxX - cursor.x
            case .top: cursor.y - f.minY
            case .bottom: f.maxY - cursor.y
            }
            return distance <= band + stickyBand
        }

        let left = touching(.left)
        let right = touching(.right)
        let top = touching(.top)

        if settings.corners {
            let band = settings.cornerBand
            let nearTop = cursor.y - f.minY <= band
            let nearBottom = f.maxY - cursor.y <= band
            let nearLeft = cursor.x - f.minX <= band
            let nearRight = f.maxX - cursor.x <= band
            let grid = LayoutCatalog.grid2x2
            if left {
                if nearTop { return ZoneResolution(zone: zone(grid, 0)) }
                if nearBottom { return ZoneResolution(zone: zone(grid, 2)) }
            }
            if right {
                if nearTop { return ZoneResolution(zone: zone(grid, 1)) }
                if nearBottom { return ZoneResolution(zone: zone(grid, 3)) }
            }
            if top {
                if nearLeft { return ZoneResolution(zone: zone(grid, 0)) }
                if nearRight { return ZoneResolution(zone: zone(grid, 1)) }
            }
        }

        // Option's halves. The side bands grow until they meet at the display's own midpoint, so every
        // point that is not a corner or the top band is a half — and the two are exactly equal even
        // where one edge is shared with another display and would otherwise arm from twice as far.
        //
        // **The centre line carries no hysteresis**, alone among every boundary here: one point either
        // side of `midX` is the other half, whichever is armed. A sticky centre reads as a dead band
        // the pointer has to overshoot to leave and overshoot again to come back to.
        if optionHeld, settings.optionHalves, settings.sideHalves {
            if settings.topFill, top { return ZoneResolution(zone: zone(LayoutCatalog.fill, 0)) }
            return ZoneResolution(zone: zone(LayoutCatalog.halves, cursor.x < f.midX ? 0 : 1))
        }

        if settings.sideHalves {
            if left { return ZoneResolution(zone: zone(LayoutCatalog.halves, 0)) }
            if right { return ZoneResolution(zone: zone(LayoutCatalog.halves, 1)) }
        }

        if settings.topFill, top {
            return ZoneResolution(zone: zone(LayoutCatalog.fill, 0))
        }

        return nil
    }
}
