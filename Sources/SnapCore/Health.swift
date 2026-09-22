import Foundation

/// How a line of the Health table reads. The table answers one question at a glance, whether SnappySnap is
/// working, so it has three colours and no fourth: a reading is not a check, and goes in the Information
/// table (`InfoRow`), never here. The System and Snapping pages colour the states they share with it by
/// the same levels, so a state never reads green in one place and orange in another.
public enum HealthLevel: Int, Comparable, Sendable {
    /// Working. Green.
    case good
    /// Not working as it should, and windows still snap: the optional notification permission denied, a
    /// macOS switch that fights a drag, a pause of the drag detection, a window Snap Assist could not put
    /// back, a crash this week. The experience is degraded, the core is not. Orange.
    case warning
    /// Not working, and because of it windows do not snap: the Accessibility permission denied, the drag
    /// detection down. Red, with the stop sign.
    case failure

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of the Health table: what is checked on the left, one word at the trailing edge in its level's
/// colour, and while the line is orange or red the sentence that says how to put it right, which the page
/// shows as a warning under the table.
public struct HealthRow: Equatable, Identifiable, Sendable {
    /// Stable and never translated: the line's identity, whatever its label says in either language.
    public let id: String
    public let label: String
    public let level: HealthLevel
    /// One word from the window's vocabulary: Granted, Denied, Enabled, Failed, Invalid, or a count.
    public let word: String
    /// What only a bug report needs (a date, how a count splits): the row's tooltip, never on the row.
    public let detail: String?
    /// What to do, and where, while the row is orange or red. Ignored while green, so a row can carry its
    /// sentence whatever its level.
    public let fix: String?

    public init(id: String, label: String, level: HealthLevel, word: String, detail: String? = nil,
                fix: String? = nil) {
        self.id = id
        self.label = label
        self.level = level
        self.word = word
        self.detail = detail
        self.fix = fix
    }
}

/// One line of the Information table: a reading worth having beside the checks (when a window last
/// snapped, how many still sit where a snap left them), blue, with nothing to judge and nothing to fix.
public struct InfoRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    /// A short value: "3 min ago", "2".
    public let value: String
    /// The row's tooltip, never on the row.
    public let detail: String?

    public init(id: String, label: String, value: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
    }
}

/// How long the two tables may grow. The page is read at a glance or it is useless: a check the user would
/// not act on, a preference, a reading nobody asked for, each costs the ones that matter a look.
/// `HealthTests` builds the worst case the app can report and holds it to these.
public enum HealthLimits {
    /// Lines of the Health table with everything that can go wrong gone wrong at once. Five is usual.
    public static let checks = 10
    /// Lines of the Information table with every reading there.
    public static let readings = 5
}

extension Array where Element == HealthRow {
    /// One sentence per line that is orange or red and says how to fix it, in the order of the lines, each
    /// once. None while every line is green: a warning is shown only while something is wrong.
    public var warnings: [String] {
        var seen = Set<String>()
        return filter { $0.level >= .warning }.compactMap(\.fix).filter { seen.insert($0).inserted }
    }
}
