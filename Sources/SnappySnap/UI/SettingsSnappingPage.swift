import SnapCore
import SwiftUI
import SystemAdapters

/// What a drag to an edge, a corner or the top does, the halves held under ⌥ Option, what dragging a
/// snapped window away does, and the gap around everything that lands.
struct SnappingPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: SystemStatus

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Edges and corners"),
                          hint: L("Drag a window until the pointer reaches the edge of the screen. A preview shows where it will land before you let go.")) {
                ToggleRow(L("Drag to the left or right edge for a half"), isOn: $store.settings.sideHalves)
                ToggleRow(L("Drag to the top edge to fill the screen"), isOn: $store.settings.topFill)
                ToggleRow(L("Drag to a corner for a quarter"), isOn: $store.settings.corners)
            }
            SettingsGroup(title: L("⌥ Option key"),
                          hint: L("While you drag with ⌥ Option held, the whole left side of the screen snaps left and the whole right side snaps right, so you never have to reach the edge. Corners and the top edge still work."),
                          notes: [L("The snap bar stays hidden while ⌥ Option is held.")]) {
                ToggleRow(L("Hold ⌥ Option to snap to halves from anywhere"), isOn: $store.settings.optionHalves)
            }
            SettingsGroup(title: L("Unsnapping"),
                          hint: L("On, a window you pull out of its snapped place goes back to the size it had before. Off, it keeps its snapped size."),
                          notes: [L("Only applies while the window is still exactly where the snap left it.")]) {
                ToggleRow(L("Restore a window's size when you drag it away"),
                          isOn: $store.settings.restoreOnDragAway)
            }
            SettingsGroup(title: L("Gap"), hint: gapHint, warnings: gapWarnings) {
                ToggleRow(L("Leave a gap around snapped windows"), isOn: $store.settings.gapEnabled)
                // Under the gap and disabled with it: it is a rule *about* the gap, and offered while
                // there is no gap it would be a switch that does nothing.
                ToggleRow(L("Keep every window inside the gap"), isOn: $store.settings.correctOversizedWindows,
                          enabled: store.settings.gapEnabled)
                // macOS applies its own margins to the placements this app does not own, a title bar
                // double-clicked or the green button's tiling menu, so with them off those leave a
                // window flush against the screen edge while ours leaves the gap. The row stays, green,
                // once they are on, so the link between the two settings can always be seen.
                if store.settings.gapEnabled {
                    StatusRow(HealthWords.marginsLabel,
                              mark: StatusMark(HealthRules.margins(on: status.tiling.margins, gapOn: true),
                                               status.tiling.margins ? HealthWords.enabled : HealthWords.disabled))
                    if !marginsAgree {
                        ButtonRow {
                            Button(L("Open Desktop & Dock Settings")) { Permissions.openDesktopAndDockSettings() }
                        }
                    }
                }
            }
        }
    }

    private var marginsAgree: Bool { status.tiling.marginsAgree(withGap: store.settings.gapEnabled) }

    private var gapHint: String {
        L("Snapped windows keep \(Unit.points(SnapCore.Settings.Fixed.gap)) from the screen edges and from each other. Off, they touch. With the second switch on, a window that macOS zooms or tiles flush against the screen edge is nudged back inside the gap a moment later.")
    }

    /// The one thing to fix, and only while the gap is on and macOS is tiling without margins.
    private var gapWarnings: [String] {
        guard store.settings.gapEnabled, !marginsAgree else { return [] }
        return [L("Also turn on “Tiled windows have margins” in Desktop & Dock. macOS then leaves the same gap when it places a window itself, like a double click on a title bar.")]
    }
}
