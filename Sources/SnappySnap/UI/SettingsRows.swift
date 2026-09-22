import SnapCore
import SwiftUI

/// The measurements every page of the Settings window shares. Written once so that a group's title,
/// its rows' text and its hint all stand on the same margin, and so that the window and the pages agree
/// on one content width. Spacing is small on purpose: this window is a list of switches.
enum SettingsMetrics {
    /// The width of the content. The window is not resizable and every page is laid out for this.
    static let contentWidth: CGFloat = 640
    /// Between the page's edge and its cards, on the left and on the right.
    static let pageMargin: CGFloat = 16
    static let pageTop: CGFloat = 10
    static let pageBottom: CGFloat = 14
    /// Between one group's last line and the next group's title.
    static let groupSpacing: CGFloat = 12
    /// How far a row's text sits from the card's edge. The group's title, its hint and its callouts
    /// take the same inset, so the four read as one column.
    static let inset: CGFloat = 10
    /// Between the title and the card, and between the card and whatever comes first under it.
    static let cardGap: CGFloat = 5
    /// Between the hint and the first callout under it.
    static let hintToCallout: CGFloat = 4
    /// Between one callout and the next.
    static let calloutSpacing: CGFloat = 3
    static let cardRadius: CGFloat = 10
    /// Above and below a row's content.
    static let rowPadding: CGFloat = 5
    /// No row is shorter, so a row holding the smallest switch and one holding a button line up.
    static let rowMinHeight: CGFloat = 30
    /// Between the things on one row.
    static let rowSpacing: CGFloat = 8
    /// The widest a status mark grows before its sentence wraps, which keeps the label on the left
    /// from being squeezed by it.
    static let markMaxWidth: CGFloat = 400
    /// The Tip page: the app icon beside the sentence that heads it, the tile the Ko-fi cup sits in, the
    /// cup inside that tile, and the air between a picture and the words beside it. Chosen by the agent
    /// that built the page rather than fitted by the owner, like the update window's numbers.
    static let tipAppIconSide: CGFloat = 44
    static let tipTileSide: CGFloat = 88
    static let tipMarkSide: CGFloat = 52
    static let tipPictureGap: CGFloat = 14
    /// Around the one-time-tip row's content, equal on every side, so the Ko-fi tile has as much air
    /// above and below it as beside it.
    static let tipOfferPadding: CGFloat = 16
    /// The Ko-fi tile's own corner, smaller than the card's so the two curves read as nested rather
    /// than as two unrelated corners that happen to share a radius.
    static let tipTileRadius: CGFloat = 8
}

/// One page: a column of groups inside the page's margins.
struct SettingsPage<Groups: View>: View {
    private let groups: Groups

    init(@ViewBuilder groups: () -> Groups) { self.groups = groups() }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            groups
        }
        .padding(.horizontal, SettingsMetrics.pageMargin)
        .padding(.top, SettingsMetrics.pageTop)
        .padding(.bottom, SettingsMetrics.pageBottom)
    }
}

/// One group, always the same parts in the same order: a title, a card of rows, and below and outside
/// the card a hint, then warnings, then notes. Nothing explanatory goes inside a card, so a row is only
/// ever a control and its label, and a setting's explanation is in exactly one place. The owner asked for
/// one exception: the two cards of the Tip page, which are pictures and words. A group with no title is a
/// card on its own, which only the Tip page's first card is.
///
/// A **hint** says what the group does, in grey. A **warning** asks the user to fix something, in orange
/// behind a triangle, and is there only while the thing is wrong. A **note** is the one thing the user
/// must not miss, in blue behind an info mark. A group with nothing to say has none of them.
///
/// The dividers are drawn here rather than by the caller: the rows are read as subviews and a line is
/// put between each pair, starting where the text starts.
struct SettingsGroup<Rows: View>: View {
    private let title: String?
    private let hint: String?
    private let warnings: [String]
    private let notes: [String]
    private let rows: Rows

    init(title: String? = nil, hint: String? = nil, warnings: [String] = [], notes: [String] = [],
         @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.hint = hint
        self.warnings = warnings
        self.notes = notes
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, SettingsMetrics.inset)
                    .padding(.bottom, SettingsMetrics.cardGap)
            }
            card
            if let hint {
                Text(hint)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SettingsMetrics.cardGap)
                    .padding(.horizontal, SettingsMetrics.inset)
            }
            if !warnings.isEmpty || !notes.isEmpty {
                VStack(alignment: .leading, spacing: SettingsMetrics.calloutSpacing) {
                    ForEach(warnings, id: \.self) { SettingsCallout($0, kind: .warning) }
                    ForEach(notes, id: \.self) { SettingsCallout($0, kind: .note) }
                }
                .padding(.top, hint == nil ? SettingsMetrics.cardGap : SettingsMetrics.hintToCallout)
                .padding(.horizontal, SettingsMetrics.inset)
            }
        }
    }

    private var card: some View {
        Group(subviews: rows) { collection in
            VStack(spacing: 0) {
                ForEach(collection.indices, id: \.self) { index in
                    if index > collection.startIndex {
                        Divider().padding(.leading, SettingsMetrics.inset)
                    }
                    collection[index]
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// One warning or one note under a card: a symbol and a sentence in the same colour. Both kinds are
/// this one view, so they cannot drift apart.
private struct SettingsCallout: View {
    enum Kind {
        case warning, note

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .note: "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .warning: .orange
            case .note: .blue
            }
        }
    }

    private let text: String
    private let kind: Kind

    init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        // The sentence is a column of its own, so a line that wraps continues under its first word
        // and not under the symbol.
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: kind.symbol)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .foregroundStyle(kind.color)
    }
}

/// The frame every row in a card shares.
struct SettingsRowFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
    }
}

/// A row with a label on the left and a control at the trailing edge. A disabled row dims its label
/// too: a greyed switch beside full-strength text reads as a control that is merely off.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let enabled: Bool
    private let control: Control

    init(_ title: String, enabled: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // A wide control, a status that wraps, takes what the label leaves and never the
                    // other way round.
                    .layoutPriority(1)
                Spacer(minLength: SettingsMetrics.rowSpacing)
                control
            }
        }
        .disabled(!enabled)
    }
}

/// A switch and its label. The switch is the size a grouped form draws, which keeps the row at its
/// minimum height.
struct ToggleRow: View {
    private let title: String
    private let isOn: Binding<Bool>
    private let enabled: Bool

    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.title = title
        self.isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        SettingsRow(title, enabled: enabled) {
            // The label is the row's own text, so the toggle's is hidden. It is written anyway so that
            // VoiceOver reads the switch by the name the user sees.
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// What stands on the right of a status row: a symbol and a word, or a short sentence, both in the
/// state's colour. There are five kinds and each owns its symbol and its colour, so a state looks the
/// same on every page.
struct StatusMark {
    enum Kind {
        /// As it should be: a green checkmark.
        case good
        /// Worth knowing and nothing to fix: a blue info mark.
        case info
        /// Something to fix, or something that did not work: an orange triangle.
        case warning
        /// Refused or wrong, and in the way of what the app is for: a red stop sign.
        case failure
        /// Still happening: a spinner where the symbol goes.
        case busy
    }

    let kind: Kind
    let text: String

    static func good(_ text: String) -> StatusMark { StatusMark(kind: .good, text: text) }
    static func info(_ text: String) -> StatusMark { StatusMark(kind: .info, text: text) }
    static func warning(_ text: String) -> StatusMark { StatusMark(kind: .warning, text: text) }
    static func failure(_ text: String) -> StatusMark { StatusMark(kind: .failure, text: text) }
    static func busy(_ text: String) -> StatusMark { StatusMark(kind: .busy, text: text) }

    fileprivate var symbol: String? {
        switch kind {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .busy: nil
        }
    }

    fileprivate var color: Color {
        switch kind {
        case .good: .green
        case .info: .blue
        case .warning: .orange
        case .failure: .red
        case .busy: .secondary
        }
    }
}

extension StatusMark {
    /// The mark for one of the Health rules' three levels (`SnapCore.HealthLevel`): green, orange, red.
    /// Every page that colours a state by those rules draws it through this, so a state reads the same
    /// colour on the page that owns it and on the Health page.
    init(_ level: HealthLevel, _ text: String) {
        switch level {
        case .good: self = .good(text)
        case .warning: self = .warning(text)
        case .failure: self = .failure(text)
        }
    }
}

/// A state, always one row: what is being reported on the left in ordinary text, and its mark at the
/// trailing edge, at the same size as everything else. A mark that is a sentence wraps, aligned to the
/// trailing edge, its symbol staying beside the first line. A row with no mark reports nothing yet.
struct StatusRow: View {
    private let text: String
    private let mark: StatusMark?

    init(_ text: String, mark: StatusMark?) {
        self.text = text
        self.mark = mark
    }

    var body: some View {
        SettingsRow(text) {
            if let mark {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let symbol = mark.symbol {
                        Image(systemName: symbol)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(mark.text)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
                .foregroundStyle(mark.color)
                .frame(maxWidth: SettingsMetrics.markMaxWidth, alignment: .trailing)
            }
        }
    }
}

/// A row that is only buttons, at the trailing edge.
struct ButtonRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Spacer(minLength: 0)
                content
            }
        }
    }
}

/// How a number is written in the copy. Every number the window shows is a constant it reports rather
/// than sets, read from the type that owns it: a literal copied into a sentence is a second source of
/// truth, and the two drift.
enum Unit {
    static func points(_ value: Double) -> String { L("\(Int(value.rounded())) pt") }
}
