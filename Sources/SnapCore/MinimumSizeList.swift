import CoreGraphics
import Foundation

/// One application's smallest window size — one row of the list in Settings.
///
/// `name` is what the list shows and decides nothing. `origin` says where the current numbers came
/// from: the built-in list, a probe or a smaller window seen since, or the user. Width and height are
/// at least 1 pt, and a row never has an unknown axis.
public struct MinimumRow: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Hashable, Sendable {
        case builtIn, measured, edited
    }

    public var bundleID: String
    public var name: String
    public var width: Double
    public var height: Double
    public var origin: Origin

    public var id: String { bundleID }
    public var size: CGSize { CGSize(width: width, height: height) }

    public init(bundleID: String, name: String, width: Double, height: Double, origin: Origin) {
        self.bundleID = bundleID
        self.name = name
        self.width = width
        self.height = height
        self.origin = origin
    }
}

/// Everything SnappySnap knows about how small windows go: **one row per application**.
///
/// The list is the built-in rows, minus the ones the user removed, overridden by the rows this Mac
/// produced — measured and edited. Only the Mac's own part (`Stored`) is persisted, so a built-in row
/// follows the built-in list from build to build, and Reset is "forget the stored part".
///
/// **A row only ever comes down by itself.** `lower` is the one mutation an observation may make: a
/// window of the application seen smaller than its row, per axis, past
/// `MinimumSizePolicy.observationTolerance`. A probe of an application with no row makes its row
/// (`measured`). The user may set a row to anything (`edit`, `add`), remove one, or reset the list.
/// Nothing else writes a row: a refusal raises a `WindowFloor`, never a row.
public struct MinimumSizeList: Hashable, Sendable {
    /// The part that is stored: this Mac's own rows and the built-in identifiers the user removed.
    /// Arrays rather than a dictionary and a set, so the file is deterministic and readable.
    public struct Stored: Codable, Hashable, Sendable {
        public var own: [MinimumRow]
        public var removed: [String]

        public init(own: [MinimumRow] = [], removed: [String] = []) {
            self.own = own
            self.removed = removed
        }

        public var isEmpty: Bool { own.isEmpty && removed.isEmpty }
    }

    /// The list before the user or a probe has touched it, and what Reset puts back: native macOS
    /// applications plus Chrome, Firefox, Slack and WhatsApp, and nothing else.
    ///
    /// **Every row is a measurement**, taken with `swift run axprobe floor <bundle id>` — a 1 × 1 write
    /// to a standard window, the smaller of two reads 150 ms apart — on macOS 27.0 (26A428), on a
    /// real, signed-in main window. An application that was not measured is not on the list.
    /// Terminal's height is the smaller of two measurements (138 and 174 pt, two windows of one
    /// build): a row that is too small corrects itself at the first landing, one that is too large
    /// holds every window above it. Music's and Preview's rows were read from a window enlarged
    /// first, because a window already standing at its minimum reads as one that did not move.
    public static let builtIn: [MinimumRow] = [
        row("com.apple.finder", "Finder", 537, 316),
        row("com.apple.Safari", "Safari", 574, 220),
        row("com.apple.Terminal", "Terminal", 180, 138),
        row("com.apple.TextEdit", "TextEdit", 182, 46),
        row("com.apple.Notes", "Notes", 701, 320),
        row("com.apple.reminders", "Reminders", 768, 500),
        row("com.apple.AddressBook", "Contacts", 644, 350),
        row("com.apple.Maps", "Maps", 660, 360),
        row("com.apple.TV", "TV", 980, 580),
        row("com.apple.podcasts", "Podcasts", 1000, 512),
        row("com.apple.iBooksX", "Books", 1001, 530),
        row("com.apple.stocks", "Stocks", 860, 670),
        row("com.apple.weather", "Weather", 1048, 640),
        row("com.apple.Home", "Home", 289, 409),
        row("com.apple.findmy", "Find My", 500, 310),
        row("com.apple.freeform", "Freeform", 780, 496),
        row("com.apple.shortcuts", "Shortcuts", 840, 400),
        row("com.apple.AppStore", "App Store", 1000, 492),
        row("com.apple.Photos", "Photos", 750, 615),
        row("com.apple.Dictionary", "Dictionary", 400, 300),
        row("com.apple.FontBook", "Font Book", 546, 532),
        row("com.apple.clock", "Clock", 690, 640),
        row("com.apple.VoiceMemos", "Voice Memos", 770, 470),
        row("com.apple.Passwords", "Passwords", 320, 360),
        row("com.apple.journal", "Journal", 728, 520),
        row("com.apple.ActivityMonitor", "Activity Monitor", 740, 384),
        row("com.apple.Console", "Console", 600, 400),
        row("com.apple.DiskUtility", "Disk Utility", 776, 485),
        row("com.apple.SystemProfiler", "System Information", 600, 400),
        row("com.apple.systempreferences", "System Settings", 865, 470),
        row("com.apple.Music", "Music", 980, 600),
        row("com.apple.mail", "Mail", 751, 200),
        row("com.apple.iCal", "Calendar", 900, 503),
        row("com.apple.MobileSMS", "Messages", 660, 320),
        row("com.apple.Preview", "Preview", 708, 224),
        row("com.apple.QuickTimePlayerX", "QuickTime Player", 325, 183),
        row("com.apple.Pages", "Pages", 640, 480),
        row("com.apple.Numbers", "Numbers", 540, 228),
        row("com.apple.iWork.Keynote", "Keynote", 540, 428),
        row("org.mozilla.firefox", "Firefox", 500, 120),
        row("com.google.Chrome", "Google Chrome", 500, 375),
        row("com.tinyspeck.slackmacgap", "Slack", 668, 400),
        row("net.whatsapp.WhatsApp", "WhatsApp", 970, 600),
    ]

    private static func row(_ bundleID: String, _ name: String, _ width: Double, _ height: Double) -> MinimumRow {
        MinimumRow(bundleID: bundleID, name: name, width: width, height: height, origin: .builtIn)
    }

    private static let builtInByID: [String: MinimumRow] =
        Dictionary(uniqueKeysWithValues: builtIn.map { ($0.bundleID, $0) })

    /// The rows this Mac produced, measured or edited, by bundle identifier. One overrides the
    /// built-in row of the same identifier.
    public private(set) var own: [String: MinimumRow]
    /// Built-in rows the user removed. A removal means "measure this application again", so a
    /// measurement takes it away.
    public private(set) var removed: Set<String>

    /// `stored` as it was read: a row with an empty identifier or an axis under 1 pt is not a row and
    /// is left out; a removal shadowed by an own row means nothing and is dropped.
    public init(stored: Stored = Stored()) {
        var own: [String: MinimumRow] = [:]
        for row in stored.own where !row.bundleID.isEmpty && Self.isValid(row.size) {
            own[row.bundleID] = row
        }
        self.own = own
        self.removed = Set(stored.removed).subtracting(own.keys)
    }

    /// The part to persist, in a deterministic order.
    public var stored: Stored {
        Stored(own: own.values.sorted { $0.bundleID < $1.bundleID }, removed: removed.sorted())
    }

    /// Whether the list is exactly the built-in one — when nothing at all is stored.
    public var isBuiltIn: Bool { own.isEmpty && removed.isEmpty }

    /// The effective list, sorted by name and then by identifier: the Mac's own rows, and every
    /// built-in row not removed and not overridden.
    public var rows: [MinimumRow] {
        var result = Array(own.values)
        for row in Self.builtIn where own[row.bundleID] == nil && !removed.contains(row.bundleID) {
            result.append(row)
        }
        return result.sorted { a, b in
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.bundleID < b.bundleID
            }
        }
    }

    /// The row for an application, or nil when it has none — never had one, or the user removed it.
    public func row(for bundleID: String) -> MinimumRow? {
        if let row = own[bundleID] { return row }
        guard !removed.contains(bundleID) else { return nil }
        return Self.builtInByID[bundleID]
    }

    static func isValid(_ size: CGSize) -> Bool { size.width >= 1 && size.height >= 1 }

    // MARK: - What writes a row

    /// A window of the application seen at `observed`: the row is lowered to it per axis where it was
    /// larger by more than the tolerance, and marked measured — the numbers are now a measurement.
    /// Returns the row's size before and after, or nil when nothing moved. **Never raises.**
    @discardableResult
    public mutating func lower(_ bundleID: String, seeing observed: CGSize) -> (from: CGSize, to: CGSize)? {
        guard let row = row(for: bundleID),
              let lowered = MinimumSizePolicy.lowered(row.size, seeing: observed) else { return nil }
        own[bundleID] = MinimumRow(bundleID: bundleID, name: row.name, width: Double(lowered.width),
                                   height: Double(lowered.height), origin: .measured)
        removed.remove(bundleID)
        return (row.size, lowered)
    }

    /// A probe of an application with no row, believed on both axes: its row, marked measured.
    /// Nil when the application already has a row, or the measurement is not a row.
    @discardableResult
    public mutating func measured(_ size: CGSize, bundleID: String, name: String) -> MinimumRow? {
        guard !bundleID.isEmpty, Self.isValid(size), row(for: bundleID) == nil else { return nil }
        let row = MinimumRow(bundleID: bundleID, name: name, width: Double(size.width),
                             height: Double(size.height), origin: .measured)
        own[bundleID] = row
        removed.remove(bundleID)
        return row
    }

    /// The user's edit of one or both sizes, marked edited. A value under 1 pt is refused; an axis
    /// not given is left alone. True when the row changed.
    @discardableResult
    public mutating func edit(_ bundleID: String, width: Double? = nil, height: Double? = nil) -> Bool {
        guard var row = row(for: bundleID) else { return false }
        var changed = false
        if let width, width >= 1, width != row.width {
            row.width = width
            changed = true
        }
        if let height, height >= 1, height != row.height {
            row.height = height
            changed = true
        }
        guard changed else { return false }
        row.origin = .edited
        own[bundleID] = row
        removed.remove(bundleID)
        return true
    }

    /// The user's new row, marked edited: an identifier not yet listed and both sizes at least 1 pt.
    /// A blank name reads as the identifier.
    @discardableResult
    public mutating func add(bundleID: String, name: String, size: CGSize) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, Self.isValid(size), row(for: id) == nil else { return false }
        own[id] = MinimumRow(bundleID: id, name: name.isEmpty ? id : name, width: Double(size.width),
                             height: Double(size.height), origin: .edited)
        removed.remove(id)
        return true
    }

    /// Removing a row means "measure this application again". An own row goes; a built-in row is
    /// remembered as removed so it does not come back at the next launch. False when there is no row.
    @discardableResult
    public mutating func remove(_ bundleID: String) -> Bool {
        guard row(for: bundleID) != nil else { return false }
        own[bundleID] = nil
        if Self.builtInByID[bundleID] != nil { removed.insert(bundleID) }
        return true
    }

    /// The built-in list, exactly.
    public mutating func reset() {
        own = [:]
        removed = []
    }
}
