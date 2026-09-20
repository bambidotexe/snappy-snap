import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct PairCellTests {
    /// An **odd** working width (1441) and a working area that starts below the menu bar, so a half
    /// that came out of its own arithmetic rather than `Geometry`'s would land on a different number.
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1441, height: 900),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1441, height: 800))
    /// A second display to the right and 200 pt higher, so every display-relative term differs.
    let secondary = DisplayInfo(id: 2, frame: CGRect(x: 1441, y: -200, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 1441, y: -175, width: 1920, height: 1055))
    let gap = 8.0

    var cell: PairCell { PairCell(display: display, gap: gap) }

    /// With no partner, the cell is absent and the bar begins at the halves layout.
    @Test func noPartnerMeansNoCell() {
        #expect(PairCell(hasPartner: false, display: display, gap: gap) == nil)
    }

    @Test func aPartnerMeansACellWithTwoHalves() {
        let shown = PairCell(hasPartner: true, display: display, gap: gap)
        #expect(shown != nil)
        #expect(shown == cell)
        #expect(PairCell.layout.cells.count == 2)
        #expect(cell.displayID == display.id)
    }

    /// The property the whole type exists for: a pair drop and a drop on the bar's halves cell place
    /// the windows in the *same* zones — same frames, same layout id, same cell index — so a window
    /// paired into a half is indistinguishable afterwards from one snapped there by hand, to the
    /// registry, the drag-away restore and the handle bar alike.
    @Test func itsZonesAreTheHalvesLayoutsOwnZones() {
        #expect(cell.dragged == Geometry.zone(display: display, layout: LayoutCatalog.halves,
                                              cellIndex: PairCell.draggedCellIndex, gap: gap))
        #expect(cell.partner == Geometry.zone(display: display, layout: LayoutCatalog.halves,
                                              cellIndex: PairCell.partnerCellIndex, gap: gap))
        #expect(cell.dragged.layout.id == "halves")
        #expect(cell.partner.layout.id == "halves")
    }

    /// Derived from the gap rule rather than from `Geometry` — the same formula written out, so a
    /// change in either has to be a deliberate change in both: outer inset exactly `gap`, and exactly
    /// `gap` between the two halves.
    @Test(arguments: [0.0, 8.0, 24.0])
    func theTwoHalvesFillTheWorkingAreaWithOneGapBetweenThem(gap: Double) {
        let cell = PairCell(display: display, gap: gap)
        let (left, right) = (cell.dragged.frame, cell.partner.frame)
        let area = display.visibleFrame
        #expect(abs(left.minX - (area.minX + gap)) < 1e-9)
        #expect(abs(right.maxX - (area.maxX - gap)) < 1e-9)
        #expect(abs(right.minX - left.maxX - gap) < 1e-9)
        #expect(abs(left.width - right.width) < 1e-9)
        #expect(abs(left.width - (area.width - 3 * gap) / 2) < 1e-9)
        #expect(abs(left.minY - (area.minY + gap)) < 1e-9)
        #expect(abs(left.height - (area.height - 2 * gap)) < 1e-9)
        // Disjoint at every gap, including 0 where they merely touch.
        #expect(!left.insetBy(dx: 1e-9, dy: 0).intersects(right))
    }

    /// The sides are fixed: dragged left, partner right, wherever in the cell
    /// the drop lands. There is nothing to pass in that could change it — this is the assertion that
    /// fails the day a side argument comes back.
    @Test func theDraggedWindowAlwaysGoesLeftAndThePartnerAlwaysRight() {
        #expect(PairCell.draggedCellIndex == 0)
        #expect(PairCell.partnerCellIndex == 1)
        #expect(cell.dragged == Geometry.zone(display: display, layout: LayoutCatalog.halves,
                                              cellIndex: PairCell.draggedCellIndex, gap: gap))
        #expect(cell.partner == Geometry.zone(display: display, layout: LayoutCatalog.halves,
                                              cellIndex: PairCell.partnerCellIndex, gap: gap))
        #expect(cell.dragged != cell.partner)
        // Left really is left: the dragged half starts at the working area's left edge and the partner's
        // does not, so the two cannot have been swapped without this failing.
        #expect(cell.dragged.frame.minX < cell.partner.frame.minX)
        #expect(abs(cell.dragged.frame.minX - (display.visibleFrame.minX + gap)) < 1e-9)
        // And the cell is one value per display and gap, so two hovers of it are the same drop.
        #expect(PairCell(display: display, gap: gap) == cell)
    }

    /// The cell is built for the display the bar is on, not for the primary one.
    @Test func itFollowsTheDisplayItWasBuiltFor() {
        let other = PairCell(display: secondary, gap: gap)
        #expect(other.displayID == secondary.id)
        // Differences, not `==`: `#expect` compares a CGFloat against a Double through `AnyHashable`,
        // which is false whatever the numbers.
        #expect(abs(other.dragged.frame.minX - (secondary.visibleFrame.minX + gap)) < 1e-9)
        #expect(abs(other.dragged.frame.minY - (secondary.visibleFrame.minY + gap)) < 1e-9)
        #expect(other.dragged.displayID == secondary.id)
        #expect(other.partner.displayID == secondary.id)
        #expect(other != cell)
    }
}
