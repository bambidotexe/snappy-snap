import SnapCore
import SwiftUI

/// Whether SnappySnap works, at a glance: two tables and nothing else. **Health** holds the checks, each
/// green, orange or red, with Check Again under them and, while a line is orange or red, the sentence that
/// says where to put it right. **Information** holds two readings, blue. The page reports and changes
/// nothing: a state is put right on the page that owns it.
///
/// What is a check, what is a reading, what goes on neither (a preference, the version, updates) and how
/// long each table may be are the `macos-building-settings-pages` skill's *The Health page*. The lines are
/// built in `SnapCore.HealthReport`, where they are tested; this view only draws them.
struct HealthPage: View {
    @ObservedObject var status: SystemStatus
    @ObservedObject var health: HealthCheck

    var body: some View {
        let words = HealthWords.self
        let facts = health.facts(status)
        let checks = HealthReport.checks(for: facts)
        let readings = HealthReport.readings(for: facts)
        SettingsPage {
            SettingsGroup(title: words.healthTitle, warnings: checks.warnings) {
                ForEach(checks) { row in
                    StatusRow(row.label, mark: StatusMark(row.level, row.word)).help(row.detail ?? "")
                }
                ButtonRow {
                    if health.isChecking { ProgressView().controlSize(.small) }
                    Button(words.checkAgainButton) { health.checkAgain(status) }
                        .disabled(health.isChecking)
                }
            }

            SettingsGroup(title: words.informationTitle) {
                ForEach(readings) { row in
                    StatusRow(row.label, mark: .info(row.value)).help(row.detail ?? "")
                }
            }
        }
    }
}
