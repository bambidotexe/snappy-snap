import Foundation

/// A rectangle in the unit square of a working area. Encoded as `[x, y, width, height]`.
public struct UnitRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = UnitRect(0, 0, 1, 1)
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(width); try c.encode(height)
    }
}

/// An arrangement of cells. Cell order is the Snap Assist order.
public struct Layout: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var cells: [UnitRect]

    public init(id: String, cells: [UnitRect]) {
        self.id = id
        self.cells = cells
    }
}

/// The built-in layouts, measured from the Windows 11 flyout: it offers these four arrangements and
/// neither three equal columns nor quarter/half/quarter.
/// `Layouts.json` in the app resources may override `snapBar`.
public enum LayoutCatalog {
    public enum DecodingError: Error, Hashable {
        case empty
        case noCells(layoutID: String)
        case cellOutOfBounds(layoutID: String)
    }

    public static let fill = Layout(id: "fill", cells: [.full])
    public static let halves = Layout(id: "halves", cells: [UnitRect(0, 0, 0.5, 1), UnitRect(0.5, 0, 0.5, 1)])
    public static let twoThirdsOneThird = Layout(id: "two-thirds-one-third", cells: [UnitRect(0, 0, 2.0 / 3, 1), UnitRect(2.0 / 3, 0, 1.0 / 3, 1)])
    public static let leftHalfRightQuarters = Layout(id: "left-half-right-quarters", cells: [UnitRect(0, 0, 0.5, 1), UnitRect(0.5, 0, 0.5, 0.5), UnitRect(0.5, 0.5, 0.5, 0.5)])
    public static let grid2x2 = Layout(id: "grid-2x2", cells: [UnitRect(0, 0, 0.5, 0.5), UnitRect(0.5, 0, 0.5, 0.5), UnitRect(0, 0.5, 0.5, 0.5), UnitRect(0.5, 0.5, 0.5, 0.5)])

    public static let snapBar: [Layout] = [halves, twoThirdsOneThird, leftHalfRightQuarters, grid2x2]

    public static func decodeSnapBar(from data: Data) throws -> [Layout] {
        let layouts = try JSONDecoder().decode([Layout].self, from: data)
        guard !layouts.isEmpty else { throw DecodingError.empty }
        for layout in layouts {
            guard !layout.cells.isEmpty else { throw DecodingError.noCells(layoutID: layout.id) }
            for cell in layout.cells {
                guard cell.x >= 0, cell.y >= 0, cell.width > 0, cell.height > 0,
                      cell.maxX <= 1 + 1e-9, cell.maxY <= 1 + 1e-9 else {
                    throw DecodingError.cellOutOfBounds(layoutID: layout.id)
                }
            }
        }
        return layouts
    }
}
