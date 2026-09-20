import Testing
import Foundation
@testable import SnapCore

@Suite struct LayoutCatalogTests {
    @Test func snapBarHasFourLayoutsInSpecOrder() {
        #expect(LayoutCatalog.snapBar.map(\.id) == [
            "halves", "two-thirds-one-third", "left-half-right-quarters", "grid-2x2",
        ])
    }

    @Test func everyLayoutTilesTheUnitSquareWithoutOverlap() {
        for layout in LayoutCatalog.snapBar + [LayoutCatalog.fill] {
            let area = layout.cells.reduce(0.0) { $0 + $1.width * $1.height }
            #expect(abs(area - 1) < 1e-6, "\(layout.id) covers \(area)")
            for (i, a) in layout.cells.enumerated() {
                for b in layout.cells[(i + 1)...] {
                    #expect(!a.overlaps(b), "\(layout.id) has overlapping cells")
                }
            }
        }
    }

    @Test func unitRectCodesAsFourNumberArray() throws {
        let data = try JSONEncoder().encode(UnitRect(0, 0.5, 0.5, 0.5))
        #expect(String(decoding: data, as: UTF8.self) == "[0,0.5,0.5,0.5]")
        #expect(try JSONDecoder().decode(UnitRect.self, from: data) == UnitRect(0, 0.5, 0.5, 0.5))
    }

    @Test func decodeSnapBarFromJSON() throws {
        let json = #"[{"id":"halves","cells":[[0,0,0.5,1],[0.5,0,0.5,1]]}]"#.data(using: .utf8)!
        #expect(try LayoutCatalog.decodeSnapBar(from: json) == [LayoutCatalog.halves])
    }

    @Test func decodeRejectsCellsOutsideUnitSquare() {
        let json = #"[{"id":"bad","cells":[[0,0,1.5,1]]}]"#.data(using: .utf8)!
        #expect(throws: LayoutCatalog.DecodingError.cellOutOfBounds(layoutID: "bad")) {
            try LayoutCatalog.decodeSnapBar(from: json)
        }
    }

    @Test func decodeRejectsEmptyListAndEmptyLayout() {
        #expect(throws: LayoutCatalog.DecodingError.empty) {
            try LayoutCatalog.decodeSnapBar(from: "[]".data(using: .utf8)!)
        }
        #expect(throws: LayoutCatalog.DecodingError.noCells(layoutID: "x")) {
            try LayoutCatalog.decodeSnapBar(from: #"[{"id":"x","cells":[]}]"#.data(using: .utf8)!)
        }
    }
}

private extension UnitRect {
    func overlaps(_ other: UnitRect) -> Bool {
        let w = min(maxX, other.maxX) - max(x, other.x)
        let h = min(maxY, other.maxY) - max(y, other.y)
        return w > 1e-9 && h > 1e-9
    }
}
