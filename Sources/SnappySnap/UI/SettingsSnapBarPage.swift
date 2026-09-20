import SnapCore
import SwiftUI
import SystemAdapters

/// The bar of layouts at the top of the screen, what it is drawn as, and what follows a drop on it.
struct SnapBarPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Snap bar"),
                          hint: L("Drag a window to the top of the screen and a bar of layouts appears. Drop the window on a layout to place it there."),
                          notes: [L("Haptic feedback needs a Force Touch trackpad.")]) {
                ToggleRow(L("Show the snap bar when dragging to the top"), isOn: $store.settings.snapBar)
                ToggleRow(L("Haptic feedback when it appears"), isOn: $store.settings.hapticFeedback,
                          enabled: store.settings.snapBar)
            }
            // The hint follows the selection rather than describing all three: the pictures already
            // show all three.
            SettingsGroup(title: L("Style"), hint: store.settings.snapBarAppearance.detail) {
                SnapBarStyleRow(selection: $store.settings.snapBarAppearance,
                                enabled: store.settings.snapBar)
            }
            SettingsGroup(title: L("Snap Assist"),
                          hint: L("After you drop a window on a layout, your other windows line up as cards so you can pick one for each remaining space. Animation is how fluid the cards move: Smooth follows your display and uses the most energy, Battery uses the least."),
                          notes: [L("Snap Assist only starts from a snap bar layout, so it needs the snap bar.")]) {
                ToggleRow(L("Suggest windows for the remaining spaces"), isOn: $store.settings.snapAssist,
                          enabled: store.settings.snapBar)
                SettingsRow(L("Animation"), enabled: store.settings.snapBar && store.settings.snapAssist) {
                    Picker(L("Animation"), selection: $store.settings.smoothness) {
                        ForEach(Smoothness.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

/// The three appearances as pictures, the way Light, Dark and Auto are offered in System Settings: the
/// difference is something to look at rather than to read.
private struct SnapBarStyleRow: View {
    @Binding var selection: SnapBarAppearance
    let enabled: Bool

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: 8) {
                ForEach(SnapBarAppearance.allCases, id: \.self) { option in
                    Button { selection = option } label: {
                        SnapBarStyleTile(option: option, selected: option == selection)
                    }
                    // Plain, so the tile is the whole control, with a content shape so that a click
                    // anywhere inside it counts.
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// One appearance: what it comes to on a MacBook and on an external display, side by side, over its
/// title. Which surface each screen gets is `SnapBarAppearance.surface(withHousing:)`, the rule a real
/// display is given.
private struct SnapBarStyleTile: View {
    let option: SnapBarAppearance
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                MiniScreen(surface: option.surface(withHousing: true), hasHousing: true)
                MiniScreen(surface: option.surface(withHousing: false), hasHousing: false)
            }
            Text(option.title)
                .font(.body)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

/// One little screen, 52 × 34: a MacBook, which has a camera housing, or an external display, which
/// has none, with the snap bar drawn under its top edge as it would be on a screen of that kind. The
/// shapes are sketches sized to read at this scale, not the bar's own geometry.
private struct MiniScreen: View {
    let surface: SnapBarSurface
    let hasHousing: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.3), lineWidth: 1)
            }
            // The housing first, so that the notch shape drawn after it covers it.
            .overlay(alignment: .top) {
                if hasHousing {
                    UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                        .fill(.black)
                        .frame(width: 12, height: 4)
                }
            }
            .overlay(alignment: .top) { bar }
            .frame(width: 52, height: 34)
    }

    @ViewBuilder private var bar: some View {
        switch surface {
        case .notchShape:
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                .fill(.black)
                .frame(width: 30, height: 12)
        case .island:
            Capsule()
                .fill(.black)
                .frame(width: 16, height: 5)
                .padding(.top, 2)
        case .floatingBar:
            Capsule()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 28, height: 7)
                .padding(.top, 7)
        }
    }
}
