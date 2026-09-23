import CoreGraphics
import Foundation

/// The custom zones a user writes as JSON, held under Command during a window drag.
///
/// The stored text is an **array of areas**; each area is an object whose keys are screen selectors and
/// whose values say where the area sits on that screen. **Key order is not significant** — for a given
/// display an area takes its most specific matching key (exact name, then `built-in`, then resolution,
/// then `*`) wherever it is written. The text is read by a parser of our own, which is what lets it
/// accept comments, and what lets a failure name the key or the array index that caused it, with the
/// line and column for a syntax error.
///
/// An area may also carry `app` and `window`, which say whose window it is for. A window that some area
/// targets is offered those areas and no others; every other window is offered the areas that target
/// nobody.
///
/// Pure logic over plain values: a display arrives as a `DisplayInfo` (name, frame, working area), never
/// as an `NSScreen`. Every coordinate is CG space, measured from the top-left of the working area with y
/// increasing downward, and nothing here rounds.
public struct CustomZones: Sendable {
    /// One key of one area: the selector as written, and where the area sits on a display it matches.
    /// A nil placement is a written `null`: the area does not exist on those displays.
    struct Entry: Sendable {
        let key: String
        let selector: Selector
        let placement: Placement?
    }

    /// One element of the array: its screen keys, and the windows it is for — nil for every window
    /// that no other area targets.
    struct Element: Sendable {
        let entries: [Entry]
        let target: Target?
    }

    let elements: [Element]

    /// How many areas the array defines, whether or not any of them resolves on a given display.
    public var areaCount: Int { elements.count }

    /// Whether any area names a window by its title, which is the one fact about a dragged window that
    /// costs an Accessibility read to learn.
    public var readsWindowTitles: Bool { elements.contains { $0.target?.windows != nil } }

    /// Reads the stored text. A failure is a sentence that names what is wrong.
    public static func parse(_ json: String) -> CustomZonesParse {
        do {
            var parser = ConfigJSONParser(json)
            let document = try parser.parseDocument()
            return .valid(CustomZones(elements: try decode(document)))
        } catch {
            return .invalid(error.message)
        }
    }

    /// Every area that exists on `display` for `window`, in array order, each already inset by the gap.
    ///
    /// The areas are those that target `window` when at least one does — whether or not any of them
    /// resolves on this display — and otherwise those that target nobody. A window nothing is known
    /// about is targeted by no area.
    ///
    /// An element contributes an area when its most specific key that matches the display holds a
    /// placement — an exact `screenName:` before `screenName:built-in` before `screenResolution:` before
    /// `*`, whatever order they are written in. A `null` there — or no key matching at all — means it
    /// has none on this display; less specific keys are not tried after a match, and other elements are
    /// unaffected.
    ///
    /// The inset reproduces what the app's other zones do: a whole `gap` on a side that lies on the
    /// working area's own edge, half a gap on every other side, so two areas written flush end exactly
    /// one gap apart. With no gap nothing is inset.
    public func areas(on display: DisplayInfo, gap: Double,
                      for window: CustomAreaWindow = CustomAreaWindow()) -> CustomAreas {
        let workingArea = display.visibleFrame
        let targeted = elements.filter { $0.target?.matches(window) == true }
        let offered = targeted.isEmpty ? elements.filter { $0.target == nil } : targeted
        var rects: [CGRect] = []
        for element in offered {
            guard let entry = Self.entry(of: element.entries, on: display), let placement = entry.placement else { continue }
            let inset = Self.inset(placement.rect(in: workingArea), within: workingArea, gap: gap)
            // An area the gap swallows has nothing to contain a pointer, and a negative extent would
            // make `CGRect.contains` standardize it into a rectangle that is not where it was written.
            // Asked of `size`, never of `width`/`height`: those standardize too, and report a swallowed
            // area as a healthy one.
            guard inset.size.width > 0, inset.size.height > 0 else { continue }
            rects.append(inset)
        }
        return CustomAreas(rects: rects)
    }

    /// The key an element uses on `display`: the first written among the most specific kind that matches.
    static func entry(of element: [Entry], on display: DisplayInfo) -> Entry? {
        for specificity in 0...3 {
            if let entry = element.first(where: { $0.selector.specificity == specificity && $0.selector.matches(display) }) {
                return entry
            }
        }
        return nil
    }

    static func inset(_ rect: CGRect, within area: CGRect, gap: Double) -> CGRect {
        guard gap > 0 else { return rect }
        func amount(_ distance: Double) -> Double {
            abs(distance) <= Settings.Fixed.customAreaEdgeTolerance ? gap : gap / 2
        }
        let left = amount(rect.minX - area.minX)
        let right = amount(rect.maxX - area.maxX)
        let top = amount(rect.minY - area.minY)
        let bottom = amount(rect.maxY - area.maxY)
        return CGRect(x: rect.minX + left, y: rect.minY + top,
                      width: rect.width - left - right, height: rect.height - top - bottom)
    }

    /// What a user who has never edited the configuration has: one almost-maximized area, sized for the
    /// display it lands on. This is the stored text until the user changes it, not a fallback read when
    /// the text is empty — an empty configuration is a configuration, and it offers no areas.
    public static let defaultConfiguration = #"""
    [
      {
        // Almost maximized window
        "screenName:built-in": {
          "anchor": "center",
          "size": { "widthPercent": 0.9, "heightPercent": 0.9 }
        },
        "screenResolution:2560x1440": {
          "anchor": "center",
          "size": { "width": 1728, "height": 1080 }
        },
        "screenResolution:1920x1080": {
          "anchor": "center",
          "size": { "width": 1440, "height": 900 }
        },
        "*": {
          "anchor": "center",
          "size": { "widthPercent": 0.8, "heightPercent": 0.8 }
        }
      }
    ]
    """#

    /// Shown on the Settings page as a reference rather than stored: it is the one place every way of
    /// writing an area appears at once — `bounds`, an `anchor` with an `offset`, a percentage size, a
    /// `null` that takes the area off one display, and an area kept for one application's windows.
    public static let example = #"""
    [
      {
        "screenName:built-in": {
          "anchor": "top-left",
          "offset": { "x": 20, "y": 40 },
          "size": { "width": 800, "height": 600 }
        },
        "screenResolution:1920x1080": {
          "bounds": { "x": 100, "y": 100, "width": 960, "height": 900 }
        },
        "screenResolution:2560x1440": {
          "anchor": "center",
          "size": { "widthPercent": 0.6, "heightPercent": 0.7 }
        },
        "screenName:Y27qf-30": {
          "bounds": { "x": 100, "y": 100, "width": 960, "height": 900 }
        },
        "screenName:Y27qf-30 (1)": null,
        "*": {
          "anchor": "top-left",
          "offset": { "x": 20, "y": 40 },
          "size": { "width": 800, "height": 600 }
        }
      },
      {
        "app": "com.apple.TextEdit",
        "*": {
          "anchor": "right",
          "size": { "widthPercent": 0.4, "heightPercent": 1 }
        }
      }
    ]
    """#
}

/// The dragged window as an area's `app` and `window` keys see it. Any of the three may be unknown; an
/// unknown one matches nothing.
public struct CustomAreaWindow: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var title: String?

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil, title: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
    }
}

/// What reading the stored text produced: the zones, or the sentence that says what is wrong with it.
public enum CustomZonesParse: Sendable {
    case valid(CustomZones)
    case invalid(String)

    public var zones: CustomZones? {
        if case .valid(let zones) = self { return zones }
        return nil
    }

    public var problem: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// The areas of one display, in priority order: the first that contains the pointer is the one it is in.
public struct CustomAreas: Sendable, Equatable {
    public let rects: [CGRect]

    public init(rects: [CGRect]) { self.rects = rects }

    public func index(at point: CGPoint) -> Int? {
        rects.firstIndex { $0.contains(point) }
    }

    public func area(at point: CGPoint) -> CGRect? {
        index(at: point).map { rects[$0] }
    }
}

public struct CustomZonesError: Error, Hashable, Sendable {
    public let message: String
}

// MARK: - The format

extension CustomZones {
    enum Selector: Sendable {
        case name(String)
        /// The reserved word `screenName:built-in` (or `builtin`): the display macOS reports as built in.
        case builtIn
        case resolution(width: Double, height: Double)
        case any

        /// Lower is more specific and wins.
        var specificity: Int {
            switch self {
            case .name: 0
            case .builtIn: 1
            case .resolution: 2
            case .any: 3
            }
        }

        /// `screenName:` compares the display's name exactly, ignoring case and surrounding whitespace;
        /// the reserved word `built-in` instead reads the display's built-in flag.
        /// `screenResolution:` compares the display's **frame** in points, each side within
        /// `Settings.Fixed.customAreaResolutionTolerance`.
        func matches(_ display: DisplayInfo) -> Bool {
            switch self {
            case .any:
                true
            case .name(let name):
                Self.normalized(display.name) == name
            case .builtIn:
                display.isBuiltIn
            case .resolution(let width, let height):
                abs(display.frame.width - width) <= Settings.Fixed.customAreaResolutionTolerance
                    && abs(display.frame.height - height) <= Settings.Fixed.customAreaResolutionTolerance
            }
        }

        static func normalized(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        static func parse(_ key: String) -> Selector? {
            if key == "*" { return .any }
            if key.hasPrefix("screenName:") {
                let name = normalized(String(key.dropFirst("screenName:".count)))
                if name == "built-in" || name == "builtin" { return .builtIn }
                return name.isEmpty ? nil : .name(name)
            }
            if key.hasPrefix("screenResolution:") {
                let text = key.dropFirst("screenResolution:".count)
                let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                      let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                      width > 0, height > 0 else { return nil }
                return .resolution(width: width, height: height)
            }
            return nil
        }
    }

    /// Whose window an area is for. `apps` holds bundle identifiers or application names, `windows`
    /// titles, all normalized like a screen name. A nil list asks nothing; when both are written a
    /// window has to answer both.
    struct Target: Sendable {
        let apps: [String]?
        let windows: [String]?

        func matches(_ window: CustomAreaWindow) -> Bool {
            if let apps {
                let known = [window.bundleIdentifier, window.applicationName].compactMap { $0 }.map(Selector.normalized)
                guard apps.contains(where: known.contains) else { return false }
            }
            if let windows {
                guard let title = window.title.map(Selector.normalized), windows.contains(title) else { return false }
            }
            return true
        }
    }

    /// The keys of an area that are not screen selectors.
    static let targetKeys = ["app", "window"]

    enum Anchor: String, CaseIterable, Sendable {
        case topLeft = "top-left", top, topRight = "top-right"
        case left, center, right
        case bottomLeft = "bottom-left", bottom, bottomRight = "bottom-right"

        /// Where the anchor point sits on a rectangle, as a fraction of its width and height.
        var fractions: (x: Double, y: Double) {
            switch self {
            case .topLeft: (0, 0)
            case .top: (0.5, 0)
            case .topRight: (1, 0)
            case .left: (0, 0.5)
            case .center: (0.5, 0.5)
            case .right: (1, 0.5)
            case .bottomLeft: (0, 1)
            case .bottom: (0.5, 1)
            case .bottomRight: (1, 1)
            }
        }
    }

    enum Length: Sendable {
        case points(Double)
        /// A fraction (0…1) of the working area's extent on that axis.
        case fraction(Double)

        func resolved(against total: Double) -> Double {
            switch self {
            case .points(let value): value
            case .fraction(let value): value * total
            }
        }
    }

    enum Placement: Sendable {
        case bounds(CGRect)
        case anchored(Anchor, offset: CGPoint, width: Length, height: Length)

        /// In CG space, measured from the working area's top-left. Not inset, not rounded.
        func rect(in area: CGRect) -> CGRect {
            switch self {
            case .bounds(let rect):
                return CGRect(x: area.minX + rect.minX, y: area.minY + rect.minY,
                              width: rect.width, height: rect.height)
            case .anchored(let anchor, let offset, let width, let height):
                let w = width.resolved(against: area.width)
                let h = height.resolved(against: area.height)
                let f = anchor.fractions
                // The area's own anchor point lands on the working area's, then it is displaced.
                return CGRect(x: area.minX + f.x * (area.width - w) + offset.x,
                              y: area.minY + f.y * (area.height - h) + offset.y,
                              width: w, height: h)
            }
        }
    }

    // MARK: - Reading the parsed tree

    /// A place in the document, spelled for the sentence that reports a failure there.
    private struct Path {
        var parts: [String]
        func appending(_ part: String) -> Path { Path(parts: parts + [part]) }
        func fail(_ message: String) -> CustomZonesError {
            CustomZonesError(message: "\(parts.joined(separator: " › ")): \(message)")
        }
    }

    private static func decode(_ document: ConfigJSON) throws(CustomZonesError) -> [Element] {
        guard case .array(let items) = document else {
            throw CustomZonesError(message: L("the top level must be an array of areas, but it is \(document.kind)"))
        }
        var elements: [Element] = []
        for (index, item) in items.enumerated() {
            let path = Path(parts: ["[\(index)]"])
            guard case .object(let members) = item else {
                throw path.fail(L("an area must be an object of screen selectors, but it is \(item.kind)"))
            }
            var entries: [Entry] = []
            var apps: [String]?
            var windows: [String]?
            for member in members {
                let keyPath = path.appending("\"\(member.key)\"")
                // A key written twice resolves to the first of the two, as a selector does.
                if member.key == "app" {
                    let names = try decodeNames(member.value, at: keyPath)
                    if apps == nil { apps = names }
                    continue
                }
                if member.key == "window" {
                    let names = try decodeNames(member.value, at: keyPath)
                    if windows == nil { windows = names }
                    continue
                }
                guard let selector = Selector.parse(member.key) else {
                    throw keyPath.fail(L("not a screen selector; use \"screenName:<name>\", \"screenResolution:<W>x<H>\" or \"*\", or \"app\" and \"window\" to say whose window the area is for"))
                }
                if case .null = member.value {
                    entries.append(Entry(key: member.key, selector: selector, placement: nil))
                } else {
                    entries.append(Entry(key: member.key, selector: selector,
                                         placement: try decodePlacement(member.value, at: keyPath)))
                }
            }
            let target = apps == nil && windows == nil ? nil : Target(apps: apps, windows: windows)
            elements.append(Element(entries: entries, target: target))
        }
        return elements
    }

    /// `app` and `window` take one name or an array of them, none empty.
    private static func decodeNames(_ value: ConfigJSON, at path: Path) throws(CustomZonesError) -> [String] {
        let items: [ConfigJSON]
        let isArray: Bool
        switch value {
        case .string: (items, isArray) = ([value], false)
        case .array(let values): (items, isArray) = (values, true)
        default: throw path.fail(L("expected a name or an array of names, but it is \(value.kind)"))
        }
        guard !items.isEmpty else { throw path.fail(L("the array names no one")) }
        var names: [String] = []
        for (index, item) in items.enumerated() {
            let itemPath = isArray ? path.appending("[\(index)]") : path
            guard case .string(let text) = item else {
                throw itemPath.fail(L("expected a name, but it is \(item.kind)"))
            }
            let name = Selector.normalized(text)
            guard !name.isEmpty else { throw itemPath.fail(L("a name cannot be empty")) }
            names.append(name)
        }
        return names
    }

    private static func decodePlacement(_ value: ConfigJSON, at path: Path) throws(CustomZonesError) -> Placement {
        guard case .object(let members) = value else {
            throw path.fail(L("expected an object or null, but it is \(value.kind)"))
        }
        try rejectUnknownKeys(in: members, allowed: ["bounds", "anchor", "offset", "size"], at: path)
        if let bounds = members.first(where: { $0.key == "bounds" }) {
            if let other = members.first(where: { $0.key != "bounds" }) {
                throw path.appending(other.key).fail(L("\"bounds\" cannot be combined with \"\(other.key)\""))
            }
            return .bounds(try decodeBounds(bounds.value, at: path.appending("bounds")))
        }
        guard let anchorMember = members.first(where: { $0.key == "anchor" }) else {
            throw path.fail(L("needs either \"bounds\", or \"anchor\" with a \"size\""))
        }
        let anchorPath = path.appending("anchor")
        guard case .string(let name) = anchorMember.value else {
            throw anchorPath.fail(L("expected a string, but it is \(anchorMember.value.kind)"))
        }
        guard let anchor = Anchor(rawValue: name) else {
            throw anchorPath.fail(L("\"\(name)\" is not an anchor; use one of \(Anchor.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        var offset = CGPoint.zero
        if let member = members.first(where: { $0.key == "offset" }) {
            offset = try decodeOffset(member.value, at: path.appending("offset"))
        }
        guard let sizeMember = members.first(where: { $0.key == "size" }) else {
            throw path.fail(L("\"anchor\" needs a \"size\""))
        }
        let (width, height) = try decodeSize(sizeMember.value, at: path.appending("size"))
        return .anchored(anchor, offset: offset, width: width, height: height)
    }

    private static func decodeBounds(_ value: ConfigJSON, at path: Path) throws(CustomZonesError) -> CGRect {
        let members = try object(value, at: path, allowed: ["x", "y", "width", "height"])
        let x = try number(members, "x", at: path)
        let y = try number(members, "y", at: path)
        let width = try number(members, "width", at: path)
        let height = try number(members, "height", at: path)
        guard width > 0 else { throw path.appending("width").fail(L("must be greater than 0, but it is \(format(width))")) }
        guard height > 0 else { throw path.appending("height").fail(L("must be greater than 0, but it is \(format(height))")) }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func decodeOffset(_ value: ConfigJSON, at path: Path) throws(CustomZonesError) -> CGPoint {
        let members = try object(value, at: path, allowed: ["x", "y"])
        let x = members.contains { $0.key == "x" } ? try number(members, "x", at: path) : 0
        let y = members.contains { $0.key == "y" } ? try number(members, "y", at: path) : 0
        return CGPoint(x: x, y: y)
    }

    private static func decodeSize(_ value: ConfigJSON, at path: Path) throws(CustomZonesError) -> (Length, Length) {
        let members = try object(value, at: path,
                                 allowed: ["width", "widthPercent", "height", "heightPercent"])
        return (try length(members, points: "width", fraction: "widthPercent", at: path),
                try length(members, points: "height", fraction: "heightPercent", at: path))
    }

    private static func length(_ members: [ConfigJSON.Member], points: String, fraction: String,
                               at path: Path) throws(CustomZonesError) -> Length {
        let hasPoints = members.contains { $0.key == points }
        let hasFraction = members.contains { $0.key == fraction }
        switch (hasPoints, hasFraction) {
        case (true, true):
            throw path.fail(L("give either \"\(points)\" or \"\(fraction)\", not both"))
        case (false, false):
            throw path.fail(L("needs \"\(points)\" (points) or \"\(fraction)\" (a fraction of the working area)"))
        case (true, false):
            let value = try number(members, points, at: path)
            guard value > 0 else { throw path.appending(points).fail(L("must be greater than 0, but it is \(format(value))")) }
            return .points(value)
        case (false, true):
            let value = try number(members, fraction, at: path)
            guard value > 0, value <= 1 else {
                throw path.appending(fraction).fail(L("must be a fraction between 0 and 1, but it is \(format(value))"))
            }
            return .fraction(value)
        }
    }

    private static func object(_ value: ConfigJSON, at path: Path,
                               allowed: Set<String>) throws(CustomZonesError) -> [ConfigJSON.Member] {
        guard case .object(let members) = value else {
            throw path.fail(L("expected an object, but it is \(value.kind)"))
        }
        try rejectUnknownKeys(in: members, allowed: allowed, at: path)
        return members
    }

    private static func rejectUnknownKeys(in members: [ConfigJSON.Member], allowed: Set<String>,
                                          at path: Path) throws(CustomZonesError) {
        if let unknown = members.first(where: { !allowed.contains($0.key) }) {
            throw path.fail(L("unknown key \"\(unknown.key)\"; expected \(allowed.sorted().joined(separator: ", "))"))
        }
    }

    private static func number(_ members: [ConfigJSON.Member], _ key: String,
                               at path: Path) throws(CustomZonesError) -> Double {
        guard let member = members.first(where: { $0.key == key }) else {
            throw path.fail(L("missing \"\(key)\""))
        }
        guard case .number(let value) = member.value else {
            throw path.appending(key).fail(L("expected a number, but it is \(member.value.kind)"))
        }
        return value
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

// MARK: - The configuration's JSON parser

/// A JSON value read from the configuration text.
///
/// Objects keep their members as a list rather than a dictionary for two reasons: a failure can name
/// the key that caused it, and a key written twice resolves to the first of the two rather than to
/// whichever one a dictionary happened to keep. Which selector claims a display does **not** depend on
/// this order — that is decided by specificity, in `CustomZones.entry(of:on:)`.
indirect enum ConfigJSON: Sendable {
    struct Member: Sendable {
        let key: String
        let value: ConfigJSON
    }

    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConfigJSON])
    case object([Member])

    /// How a value is named inside the sentence that reports a mistake, so "but it is a number" reads
    /// as one sentence in either language. `null` is what the user writes and is never translated.
    var kind: String {
        switch self {
        case .null: "null"
        case .bool: L("a boolean")
        case .number: L("a number")
        case .string: L("a string")
        case .array: L("an array")
        case .object: L("an object")
        }
    }
}

struct ConfigJSONParser {
    private let bytes: [UInt8]
    private var position = 0
    /// The array index and object key the parser is inside, so a syntax error can say where it is.
    private var trail: [String] = []
    private static let maximumDepth = 64

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parseDocument() throws(CustomZonesError) -> ConfigJSON {
        try skipTrivia()
        guard position < bytes.count else { throw fail(L("the text is empty")) }
        let value = try parseValue(depth: 0)
        try skipTrivia()
        if position < bytes.count { throw fail(L("unexpected \(describeCurrent()) after the end of the value")) }
        return value
    }

    // MARK: Errors

    /// Line and column are 1-based; the column counts characters, not the continuation bytes of one.
    private func fail(_ message: String, at offset: Int? = nil) -> CustomZonesError {
        let end = min(offset ?? position, bytes.count)
        var line = 1
        var column = 1
        for byte in bytes[0..<end] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        let inside = trail.isEmpty ? "" : L(" (in \(trail.joined(separator: " › ")))")
        return CustomZonesError(message: L("not valid JSON, line \(line) column \(column)\(inside): \(message)"))
    }

    private func describeCurrent() -> String {
        guard position < bytes.count else { return L("end of the text") }
        let byte = bytes[position]
        // The character itself, in quotes: there is nothing in it to translate.
        if byte >= 0x20, byte < 0x7F { return "\"\(Character(Unicode.Scalar(byte)))\"" }
        return L("character 0x\(String(byte, radix: 16))")
    }

    // MARK: Values

    /// Whitespace and comments — `//` to the end of the line, `/* … */` across any number of lines, not
    /// nested — wherever the format allows whitespace. Never inside a string: `parseString` reads those.
    /// A `/` that opens neither kind of comment is left where it is, for the caller to report.
    private mutating func skipTrivia() throws(CustomZonesError) {
        while position < bytes.count {
            let byte = bytes[position]
            if [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
                position += 1
            } else if byte == UInt8(ascii: "/"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "/") {
                while position < bytes.count, bytes[position] != 0x0A { position += 1 }
            } else if byte == UInt8(ascii: "/"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "*") {
                let start = position
                position += 2
                while true {
                    guard position + 1 < bytes.count else {
                        position = bytes.count
                        throw fail(L("this comment is never closed"), at: start)
                    }
                    if bytes[position] == UInt8(ascii: "*"), bytes[position + 1] == UInt8(ascii: "/") {
                        position += 2
                        break
                    }
                    position += 1
                }
            } else {
                return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws(CustomZonesError) -> ConfigJSON {
        guard depth <= Self.maximumDepth else { throw fail(L("nested more than \(Self.maximumDepth) levels deep")) }
        guard position < bytes.count else { throw fail(L("the text ends where a value was expected")) }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw fail(L("unexpected \(describeCurrent()) where a value was expected"))
        }
    }

    private mutating func expect(_ word: String) throws(CustomZonesError) {
        let expected = Array(word.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected else {
            throw fail(L("expected \(word)"))
        }
        position += expected.count
    }

    private mutating func parseObject(depth: Int) throws(CustomZonesError) -> ConfigJSON {
        position += 1
        var members: [ConfigJSON.Member] = []
        try skipTrivia()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(members)
        }
        while true {
            try skipTrivia()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                throw fail(L("expected a key in double quotes, found \(describeCurrent())"))
            }
            let key = try parseString()
            try skipTrivia()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else {
                throw fail(L("expected \":\" after the key \"\(key)\", found \(describeCurrent())"))
            }
            position += 1
            try skipTrivia()
            trail.append("\"\(key)\"")
            members.append(ConfigJSON.Member(key: key, value: try parseValue(depth: depth + 1)))
            trail.removeLast()
            try skipTrivia()
            guard position < bytes.count else { throw fail(L("the text ends inside an object")) }
            if bytes[position] == UInt8(ascii: ",") {
                position += 1
            } else if bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(members)
            } else {
                throw fail(L("expected \",\" or \"}\", found \(describeCurrent())"))
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(CustomZonesError) -> ConfigJSON {
        position += 1
        var items: [ConfigJSON] = []
        try skipTrivia()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            try skipTrivia()
            trail.append("[\(items.count)]")
            items.append(try parseValue(depth: depth + 1))
            trail.removeLast()
            try skipTrivia()
            guard position < bytes.count else { throw fail(L("the text ends inside an array")) }
            if bytes[position] == UInt8(ascii: ",") {
                position += 1
            } else if bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            } else {
                throw fail(L("expected \",\" or \"]\", found \(describeCurrent())"))
            }
        }
    }

    private mutating func parseString() throws(CustomZonesError) -> String {
        let start = position
        position += 1
        var out: [UInt8] = []
        while true {
            guard position < bytes.count else { throw fail(L("this string is never closed"), at: start) }
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                position += 1
                guard position < bytes.count else { throw fail(L("this string is never closed"), at: start) }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): out.append(contentsOf: try parseUnicodeEscape())
                default:
                    position -= 1
                    let written = String(Character(Unicode.Scalar(escape)))
                    throw fail(L("\"\\\(written)\" is not a valid escape"))
                }
            case 0..<0x20:
                throw fail(L("a line break or control character inside a string"))
            default:
                out.append(byte)
                position += 1
            }
        }
    }

    /// The four hex digits after `\u`, and — for a high surrogate — the `\uXXXX` that must follow it.
    private mutating func parseUnicodeEscape() throws(CustomZonesError) -> [UInt8] {
        let first = try hex4()
        var value = first
        if (0xD800...0xDBFF).contains(first) {
            guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                  bytes[position + 1] == UInt8(ascii: "u") else {
                throw fail(L("a high surrogate escape must be followed by a low one"))
            }
            position += 2
            let second = try hex4()
            guard (0xDC00...0xDFFF).contains(second) else { throw fail(L("a high surrogate escape must be followed by a low one")) }
            value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        } else if (0xDC00...0xDFFF).contains(first) {
            throw fail(L("a low surrogate escape with no high one before it"))
        }
        guard let scalar = Unicode.Scalar(value) else { throw fail(L("not a valid unicode escape")) }
        return Array(String(Character(scalar)).utf8)
    }

    private mutating func hex4() throws(CustomZonesError) -> UInt32 {
        guard position + 4 <= bytes.count else { throw fail(L("a \\u escape needs four hex digits")) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = Character(Unicode.Scalar(bytes[position])).hexDigitValue else {
                throw fail(L("a \\u escape needs four hex digits"))
            }
            value = value * 16 + UInt32(digit)
            position += 1
        }
        return value
    }

    private mutating func parseNumber() throws(CustomZonesError) -> ConfigJSON {
        let start = position
        func digits() -> Bool {
            let before = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
            return position > before
        }
        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) else {
            throw fail(L("a number needs a digit here"), at: position)
        }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else {
            _ = digits()
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            guard digits() else { throw fail(L("a number needs a digit after the decimal point")) }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") { position += 1 }
            guard digits() else { throw fail(L("a number needs a digit in its exponent")) }
        }
        guard let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)), value.isFinite else {
            throw fail(L("this number is out of range"), at: start)
        }
        return .number(value)
    }
}
