import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// Whether SnappySnap is doing its job, at a glance: one overview row that sums the page up, then every
/// state that bears on it, grouped by subject, each a `StatusRow` in the colour of its level. It reports and
/// changes nothing: a state is put right on the page that owns it, and each orange or red row says where
/// in a warning under its group.
///
/// What goes here, what does not (the version and updates stay on General), and which colour a state takes
/// are the `macos-building-settings-pages` skill's *The Health page*. The rows themselves are built in
/// `SnapCore.HealthReport`, where they are tested; this view only draws them.
struct HealthPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: SystemStatus
    @ObservedObject var health: HealthCheck

    var body: some View {
        let words = HealthWords.self
        let groups = HealthReport.groups(for: health.facts(status))
        let summary = HealthSummary(groups: groups)
        SettingsPage {
            SettingsGroup(title: words.overviewTitle) {
                // The app's own name is never translated.
                StatusRow("SnappySnap",
                          mark: health.isChecking
                            ? .busy(words.checking)
                            : StatusMark(summary.level, HealthReport.summaryWord(summary)))
                ButtonRow {
                    Button(words.checkAgainButton) { health.checkAgain(status) }
                        .disabled(health.isChecking)
                }
            }

            ForEach(groups) { group in
                SettingsGroup(title: group.title, hint: group.hint, warnings: group.warnings) {
                    ForEach(group.rows) { row in
                        HealthRowView(row: row)
                    }
                }
            }

            SettingsGroup(title: words.reportTitle, hint: words.reportHint) {
                ButtonRow {
                    Button(words.copyReportButton) { copyReport(groups) }
                }
            }
        }
    }

    private func copyReport(_ groups: [HealthGroup]) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = HealthReport.text(appName: "SnappySnap", version: UpdateController.shared.appVersion,
                                     system: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                     groups: groups)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One row of the page: the kit's `StatusRow`, and what only a bug report needs as its tooltip.
private struct HealthRowView: View {
    let row: HealthRow

    var body: some View {
        if let detail = row.detail, !detail.isEmpty {
            StatusRow(row.label, mark: StatusMark(row.level, row.word)).help(detail)
        } else {
            StatusRow(row.label, mark: StatusMark(row.level, row.word))
        }
    }
}
