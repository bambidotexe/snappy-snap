import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// What SnappySnap needs from macOS and the controls that give it: the permission and the button to its
/// pane, macOS's own tiling and the button to Desktop & Dock, the switch over the hidden parts of macOS
/// with what each of them buys on this Mac, and the way back to the welcome window.
///
/// A state here is always the context of a control beside it. A button to a pane and the warning naming
/// the switch show only while the state is wrong; once it is right they go and the row stays, so the link
/// stays visible. Every state takes its colour from `SnapCore.HealthRules` and its fix from
/// `SnapCore.HealthWords`, like the Health page, so the two pages read the same.
///
/// The permission and the tiling switches follow the system while the window is open, so granting
/// Accessibility or flipping a switch in System Settings shows up here without closing it. The reading
/// is `SystemStatus`'s job, not this view's.
struct SystemPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: SystemStatus

    var body: some View {
        let words = HealthWords.self
        SettingsPage {
            SettingsGroup(title: L("Accessibility"),
                          hint: L("The only permission SnappySnap needs. It lets SnappySnap see the window you drag and move windows for you."),
                          warnings: status.accessibilityGranted ? [] : [words.accessibilityFix],
                          notes: [L("Nothing about your windows ever leaves your Mac.")]) {
                StatusRow(words.accessibilityLabel,
                          mark: StatusMark(HealthRules.grant(held: status.accessibilityGranted, required: true),
                                           status.accessibilityGranted ? words.granted : words.denied))
                if !status.accessibilityGranted {
                    ButtonRow {
                        Button(L("Open Accessibility Settings")) { Permissions.openAccessibilitySettings() }
                    }
                }
            }
            SettingsGroup(title: words.tilingTitle,
                          hint: L("macOS has its own window tiling. With it on, macOS and SnappySnap both grab the same drag. Margins should match your gap setting, so windows tiled by macOS line up with the ones SnappySnap places."),
                          warnings: tilingWarnings) {
                StatusRow(words.edgeTilingLabel,
                          mark: StatusMark(edgeTiling, status.tiling.conflicts ? words.enabled : words.disabled))
                // Green when the system agrees with the gap the user asked for, whichever way round
                // that is: no margins and no gap is as consistent as margins and a gap.
                StatusRow(words.marginsLabel,
                          mark: StatusMark(margins, status.tiling.margins ? words.enabled : words.disabled))
                // Only a fight while the halves held under ⌥ Option are on.
                StatusRow(words.optionTilingLabel,
                          mark: StatusMark(optionTiling, status.tiling.optionTiling ? words.enabled : words.disabled))
                if [edgeTiling, margins, optionTiling].contains(where: { $0 >= .warning }) {
                    ButtonRow {
                        Button(L("Open Desktop & Dock Settings")) { Permissions.openDesktopAndDockSettings() }
                    }
                }
            }
            // One switch over every private macOS symbol the app uses, and a line per thing they buy
            // saying whether this Mac has it: what the switch gives on this Mac, beside it. A line reports
            // the machine, not the switch and not whether the feature is on screen. Asking resolves every
            // symbol, switch or no switch, which for some means mapping SkyLight: a line that read Missing
            // because the switch was off would be reporting the switch back to the user. `PrivateAPI` keeps
            // each answer, which cannot change until the next boot, so asking again costs a lookup.
            SettingsGroup(title: words.compatibilityTitle,
                          hint: L("On, SnappySnap is smoother and more precise. Off, everything still works, a little less precisely."),
                          notes: [L("These are parts of macOS that Apple does not document, so a macOS update can break them.")]) {
                ToggleRow(words.hiddenFeaturesLabel, isOn: $store.settings.usePrivateAPIs)
                ForEach(PrivateFeature.allCases, id: \.self) { feature in
                    let available = PrivateAPI.shared.isAvailable(feature)
                    StatusRow(feature.title,
                              mark: StatusMark(HealthRules.hiddenFeature(available: available),
                                               available ? words.available : words.missing))
                        // The symbols and their frameworks are what a bug report needs and what nobody
                        // else does, so they are the row's tooltip rather than on the row.
                        .help(PrivateAPI.shared.report(for: feature))
                }
            }
            SettingsGroup(title: L("Start over"),
                          hint: L("Walks through the welcome pages again: what SnappySnap does, the permission it needs, and the two macOS settings it works best with.")) {
                ButtonRow {
                    Button(L("Show Onboarding Again")) { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
                }
            }
        }
    }

    private var edgeTiling: HealthLevel { HealthRules.edgeTiling(conflicts: status.tiling.conflicts) }

    private var margins: HealthLevel {
        HealthRules.margins(on: status.tiling.margins, gapOn: store.settings.gapEnabled)
    }

    private var optionTiling: HealthLevel {
        HealthRules.optionTiling(on: status.tiling.optionTiling, optionHalvesOn: store.settings.optionHalves)
    }

    /// One instruction for each row that is orange, and none for a row that is green.
    private var tilingWarnings: [String] {
        let words = HealthWords.self
        var warnings: [String] = []
        if edgeTiling >= .warning { warnings.append(words.edgeTilingFix) }
        if margins >= .warning { warnings.append(words.marginsFix(gapOn: store.settings.gapEnabled)) }
        if optionTiling >= .warning { warnings.append(words.optionTilingFix) }
        return warnings
    }
}
