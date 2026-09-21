import Foundation

/// How one line of the Settings window's Health page reads. The page answers one question at a glance,
/// whether SnappySnap is doing its job, and these four levels are the whole of its answer. The same four
/// colours mean the same thing on every page of the Settings window, so a state never reads green in one
/// place and orange in another.
public enum HealthLevel: Int, Comparable, Sendable {
    /// A reading: a time, a count, a size, a value. Nothing to judge, nothing to fix. Blue. An app's own
    /// switch that the user turned off is one too: it is the state they asked for.
    case info
    /// As it should be. Green.
    case good
    /// Not as it should be, and windows still snap: an optional permission denied, a macOS switch that
    /// fights a feature, a feature switched on that cannot work, something that did not work this time,
    /// a crash this week. The experience is degraded, the core is not. Orange.
    case warning
    /// Not as it should be, and because of it windows do not snap: the Accessibility permission denied,
    /// the drag detection down. Red, with the stop sign.
    case failure

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of the Health page: what is reported on the left, one word at the trailing edge in its level's
/// colour, and while the line is orange or red the sentence that says how to put it right, which the page
/// shows as a warning under the group.
public struct HealthRow: Equatable, Identifiable, Sendable {
    /// Stable and never translated: the line's identity, whatever its label says in either language.
    public let id: String
    public let label: String
    public let level: HealthLevel
    /// One word from the window's vocabulary, or a short value for a reading ("3 min ago", "48 MB").
    public let word: String
    /// What only a bug report needs (a path, a date, the symbols behind a feature): the row's tooltip, and
    /// a line of the copied report. Never on the row itself.
    public let detail: String?
    /// What to do, and where, while the row is orange or red. Shown under the group; ignored while green or
    /// blue, so a row can carry its sentence whatever its level.
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

/// One group of the Health page: a subject the user thinks in, its lines, and under the card the
/// sentences that say how to put right whichever of them is wrong.
public struct HealthGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let hint: String?
    public let rows: [HealthRow]

    public init(id: String, title: String, hint: String? = nil, rows: [HealthRow]) {
        self.id = id
        self.title = title
        self.hint = hint
        self.rows = rows
    }

    /// One sentence per line that is orange or red and says how to fix it, in the order of the lines, each
    /// once. None while every line is fine: a warning is shown only while something is wrong.
    public var warnings: [String] {
        var seen = Set<String>()
        return rows.filter { $0.level >= .warning }.compactMap(\.fix).filter { seen.insert($0).inserted }
    }
}

/// The page in one line: what the first row of the Health page says about everything under it.
public struct HealthSummary: Equatable, Sendable {
    /// Lines that are red: each one stops windows from snapping.
    public let blocking: Int
    /// Lines that are orange: each one degrades it.
    public let toLookAt: Int

    public init(groups: [HealthGroup]) {
        let rows = groups.flatMap(\.rows)
        blocking = rows.filter { $0.level == .failure }.count
        toLookAt = rows.filter { $0.level == .warning }.count
    }

    /// Red wins over orange: one line that stops the app is what the user must hear first.
    public var level: HealthLevel {
        if blocking > 0 { return .failure }
        return toLookAt > 0 ? .warning : .good
    }
}
