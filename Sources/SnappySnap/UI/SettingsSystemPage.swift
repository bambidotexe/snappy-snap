import SnapCore
import SwiftUI
import SystemAdapters

/// What SnappySnap needs from macOS, what macOS does that gets in its way, and which of the hidden
/// parts of macOS this Mac has.
///
/// The permission and the tiling switches follow the system while the window is open, so granting
/// Accessibility or flipping a switch in System Settings shows up here without closing it. The reading
/// is `SystemStatus`'s job, not this view's.
struct SystemPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: SystemStatus

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Accessibility"),
                          hint: L("The only permission SnappySnap needs. It lets SnappySnap see the window you drag and move windows for you."),
                          notes: [L("Nothing about your windows ever leaves your Mac.")]) {
                StatusRow(L("Accessibility permission"),
                          mark: status.accessibilityGranted ? .good(L("Granted")) : .failure(L("Denied")))
                ButtonRow {
                    Button(L("Open Accessibility Settings")) { Permissions.openAccessibilitySettings() }
                }
            }
            SettingsGroup(title: L("macOS tiling"),
                          hint: L("macOS has its own window tiling. With it on, macOS and SnappySnap both grab the same drag. Margins should match your gap setting, so windows tiled by macOS line up with the ones SnappySnap places."),
                          warnings: tilingWarnings) {
                StatusRow(L("macOS edge tiling"),
                          mark: status.tiling.conflicts ? .warning(L("Enabled")) : .good(L("Disabled")))
                // Green when the system agrees with the gap the user asked for, whichever way round
                // that is: no margins and no gap is as consistent as margins and a gap.
                StatusRow(L("Margins around tiled windows"), mark: marginsMark)
                ButtonRow {
                    Button(L("Open Desktop & Dock Settings")) { Permissions.openDesktopAndDockSettings() }
                }
            }
            // One switch over every private macOS symbol the app uses, and a line per thing they buy
            // saying whether this Mac has it. A line reports the machine, not the switch and not
            // whether the feature is on screen. Asking resolves every symbol, switch or no switch,
            // which for some means mapping SkyLight: a line that read Missing because the switch was
            // off would be reporting the switch back to the user. `PrivateAPI` keeps each answer, which
            // cannot change until the next boot, so asking again costs a lookup.
            SettingsGroup(title: L("Compatibility"),
                          hint: L("On, SnappySnap is smoother and more precise. Off, everything still works, a little less precisely."),
                          notes: [L("These are parts of macOS that Apple does not document, so a macOS update can break them.")]) {
                ToggleRow(L("Use hidden macOS features"), isOn: $store.settings.usePrivateAPIs)
                ForEach(PrivateFeature.allCases, id: \.self) { feature in
                    StatusRow(feature.title,
                              mark: PrivateAPI.shared.isAvailable(feature) ? .good(L("Available")) : .warning(L("Missing")))
                        // The symbols and their frameworks are what a bug report needs and what nobody
                        // else does, so they are the row's tooltip rather than on the row.
                        .help(Self.tooltip(for: feature))
                }
            }
        }
    }

    private var marginsAgree: Bool { status.tiling.marginsAgree(withGap: store.settings.gapEnabled) }

    private var marginsMark: StatusMark {
        let word = status.tiling.margins ? L("Enabled") : L("Disabled")
        return marginsAgree ? .good(word) : .warning(word)
    }

    /// One instruction for each row that is orange, and none for a row that is green.
    ///
    /// The margins line carries its verb as a value rather than as two whole sentences: English turns
    /// a switch "on" or "off" around one verb, and a language that needs one verb per direction gets
    /// them from the two short keys instead of from a sentence written twice.
    private var tilingWarnings: [String] {
        var warnings: [String] = []
        if status.tiling.conflicts {
            warnings.append(L("In Desktop & Dock, turn off “Drag windows to screen edges to tile” and “Drag windows to menu bar to fill screen”."))
        }
        if !marginsAgree {
            let verb = store.settings.gapEnabled ? L("turn on") : L("turn off")
            warnings.append(L("In Desktop & Dock, \(verb) “Tiled windows have margins”."))
        }
        return warnings
    }

    /// The feature's symbols, one per line, each with its framework and whether this macOS has it.
    private static func tooltip(for feature: PrivateFeature) -> String {
        feature.symbols
            .map { "\($0.rawValue) (\($0.framework)): \(PrivateAPI.shared.isAvailable($0) ? "found" : "not found")" }
            .joined(separator: "\n")
    }
}
