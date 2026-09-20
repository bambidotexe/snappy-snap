import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// The handles between windows, the switch over the press probe, and the one list of how small each
/// app's windows go. The rules are `MinimumSizeStore`'s; this page shows the list and takes the user's
/// three actions: add a row, remove one (which means *measure this app again*), and reset the list.
///
/// The page observes the store, so a row a window lowers while the page is open changes as the user
/// watches. Width and height commit on Return or when the field loses focus, never per keystroke, and
/// a value under 1 pt is refused by the store, so the field falls back to the row's number.
struct HandlesPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var minimums: MinimumSizeStore
    /// The selected row, by bundle identifier: a row's identity, which the user cannot edit.
    @State private var selection: String?
    @State private var adding = false

    var body: some View {
        SettingsPage {
            // The note is where the app says what holding ⌘ Command does to the handles. It is text and
            // not a control: the behaviour is always on, and there is nothing to switch.
            SettingsGroup(title: L("Handles"),
                          hint: L("A small pill appears between two windows that sit side by side. Drag it to resize both at once. Where three or four windows meet, a round knob moves them all."),
                          notes: [L("Hold ⌘ Command to hide the handles and resize a window by its own edge.")]) {
                ToggleRow(L("Show handles between windows"), isOn: $store.settings.handleBar)
            }
            SettingsGroup(title: L("Smallest window sizes"),
                          hint: L("Every app has a smallest size its windows accept, and macOS does not say what it is. On, an unknown app's window blinks once while SnappySnap measures it, and handles then stop exactly where the window stops. Off, nothing blinks, but a handle can be dragged further than a window can shrink, and the windows settle after you let go."),
                          notes: [L("Apps already in the list below are never measured.")]) {
                ToggleRow(L("Measure an app the first time you use a handle next to it"),
                          isOn: $store.settings.probeMinimumSizes)
            }
            SettingsGroup(title: L("Apps"),
                          hint: L("The smallest size of each app's windows, in points. SnappySnap fills this in as it measures apps, and lowers a size whenever it sees a smaller window. Edit a size if a handle stops too early or too late."),
                          notes: [L("Remove an app to have it measured again.")]) {
                list
                actions
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(minimums.list.rows) { row in
                HStack(spacing: 8) {
                    Text(row.name)
                    Spacer()
                    TextField(L("Width"), value: width(of: row), format: .number.precision(.fractionLength(0)))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("×").foregroundStyle(.secondary)
                    TextField(L("Height"), value: height(of: row), format: .number.precision(.fractionLength(0)))
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text(L("pt")).foregroundStyle(.secondary)
                    Text(Self.label(row.origin))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.body)
                .tag(row.bundleID)
                // The bundle identifier is what a bug report needs and what nobody else does, so it is
                // the row's tooltip rather than a second line on it.
                .help(row.bundleID)
            }
        }
        .listStyle(.inset)
        // Clear, so the group's card shows through instead of a second box inside it.
        .scrollContentBackground(.hidden)
        .frame(height: 240)
    }

    private var actions: some View {
        SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Button(L("Add…")) { adding = true }
                    .sheet(isPresented: $adding) { AddAppSheet(minimums: minimums) }
                Button(L("Remove")) {
                    if let selection { minimums.remove(selection) }
                    selection = nil
                }
                .disabled(selection == nil)
                Spacer(minLength: SettingsMetrics.rowSpacing)
                Button(L("Reset")) {
                    minimums.reset()
                    selection = nil
                }
                .disabled(minimums.list.isBuiltIn)
            }
        }
    }

    /// The field reads the row as it is now and writes through the store, which refuses a value under
    /// 1 pt, so a refused edit reads back the row's own number.
    private func width(of row: MinimumRow) -> Binding<Double> {
        Binding(get: { minimums.list.row(for: row.bundleID)?.width ?? row.width },
                set: { minimums.edit(row.bundleID, width: $0) })
    }

    private func height(of row: MinimumRow) -> Binding<Double> {
        Binding(get: { minimums.list.row(for: row.bundleID)?.height ?? row.height },
                set: { minimums.edit(row.bundleID, height: $0) })
    }

    /// Where the row's numbers came from, as the last column shows it.
    static func label(_ origin: MinimumRow.Origin) -> String {
        switch origin {
        case .builtIn: L("Built in")
        case .measured: L("Measured")
        case .edited: L("Edited")
        }
    }
}

/// The sheet behind **Add…**: a running app that has no row, or a bundle identifier and a name typed by
/// hand, and the two sizes. Add is enabled only for a complete, unlisted row, so a row with an unknown
/// axis can never exist.
private struct AddAppSheet: View {
    @ObservedObject var minimums: MinimumSizeStore
    @Environment(\.dismiss) private var dismiss
    /// The picked running app's pid, or nil for a row typed by hand.
    @State private var picked: pid_t?
    @State private var bundleID = ""
    @State private var name = ""
    @State private var width: Double?
    @State private var height: Double?

    /// The running apps that could take a row: regular ones, not this app, not listed yet.
    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                return id != Bundle.main.bundleIdentifier && minimums.list.row(for: id) == nil
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var identifier: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        guard let width, let height, width >= 1, height >= 1 else { return false }
        return !identifier.isEmpty && minimums.list.row(for: identifier) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Add an app")).font(.headline)
            Form {
                Picker(L("App"), selection: Binding(get: { picked }, set: select)) {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?").tag(Optional(app.processIdentifier))
                    }
                    Divider()
                    Text(L("Other…")).tag(pid_t?.none)
                }
                // Only for a row typed by hand: a picked app's identifier and name are its own, and a
                // field nobody may edit is one nobody needs to read.
                if picked == nil {
                    TextField(L("Bundle identifier"), text: $bundleID)
                        .font(.system(.body, design: .monospaced))
                    TextField(L("Name"), text: $name)
                }
                TextField(L("Width"), value: $width, format: .number.precision(.fractionLength(0)))
                TextField(L("Height"), value: $height, format: .number.precision(.fractionLength(0)))
            }
            .font(.body)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) {
                    minimums.add(bundleID: identifier, name: name,
                                 size: CGSize(width: width ?? 0, height: height ?? 0))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { select(candidates.first?.processIdentifier) }
    }

    /// A picked app fills the identifier and the name from itself; *Other…* leaves them to the user.
    private func select(_ pid: pid_t?) {
        picked = pid
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        bundleID = app.bundleIdentifier ?? ""
        name = app.localizedName ?? bundleID
    }
}
