import AppKit
import SnapCore
import SwiftUI
import SystemAdapters

/// The JSON behind the areas held under ⌘ Command, written by hand and stored on every change. The
/// status row reports the last **Verify**, pressed or run when the page appears, and never follows the
/// typing: a verdict that changed at every key would spend most of its life saying Invalid.
///
/// The switch at the top governs the whole feature. With it off the editor and Verify are disabled
/// rather than hidden: the text is still the user's, and it is still there when the feature comes back.
struct CustomAreasPage: View {
    @ObservedObject var store: SettingsStore
    @State private var verdict: CustomZonesParse?
    @State private var screens: [ScreenLine] = ScreenLine.attached()

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Custom areas"),
                          hint: L("Define your own snap areas below, then hold ⌘ Command during a drag to see them and drop a window into one."),
                          notes: [L("While ⌘ Command is held, only your areas are offered. Edges, corners and the snap bar are off.")]) {
                ToggleRow(L("Hold ⌘ Command while dragging to use your own areas"),
                          isOn: $store.settings.customAreas)
            }
            SettingsGroup(title: L("Areas"),
                          hint: L("Areas are written as JSON. Verify checks your text and says what to fix."),
                          notes: [L("Text with a mistake is kept, but no areas are offered until it is valid.")]) {
                TextEditor(text: $store.customZonesJSON)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .background(PlainTextTraits())
                    // Clear, so the group's card shows through instead of a second box inside it.
                    .scrollContentBackground(.hidden)
                    .frame(height: 240)
                    .padding(6)
                switch verdict {
                case .valid(let zones):
                    // Two keys rather than one with a plural inside it, so each language writes its
                    // own singular and its own plural.
                    StatusRow(zones.areaCount == 1 ? L("1 area") : L("\(zones.areaCount) areas"),
                              mark: .good(L("Valid")))
                case .invalid(let message):
                    StatusRow(message, mark: .failure(L("Invalid")))
                case nil:
                    EmptyView()
                }
                ButtonRow {
                    Button(L("Verify"), action: verify)
                }
            }
            .disabled(!store.settings.customAreas)
            SettingsGroup(title: L("Your displays"),
                          hint: L("Copy a name or a size from here to aim an area at one display.")) {
                ForEach(screens) { line in
                    SettingsRowFrame {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: SettingsMetrics.rowSpacing) {
                                Text(line.isBuiltIn ? L("\(line.name), built in") : line.name)
                                Spacer(minLength: SettingsMetrics.rowSpacing)
                                Text(line.size).foregroundStyle(.secondary)
                            }
                            .font(.body)
                            // The two selectors exactly as the JSON takes them, so they are copied
                            // rather than retyped.
                            Text("screenName:\(line.name)   screenResolution:\(line.resolution)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            SettingsGroup(title: L("Example")) {
                Text(CustomZones.example)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .onAppear(perform: verify)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenLine.attached()
        }
    }

    private func verify() {
        verdict = CustomZones.parse(store.customZonesJSON)
    }
}

/// A display as the user writes it in a selector: its exact `localizedName` and its frame in points.
private struct ScreenLine: Identifiable {
    let id: UInt32
    let name: String
    let size: String
    let resolution: String
    let isBuiltIn: Bool

    @MainActor static func attached() -> [ScreenLine] {
        NSScreen.screens.map { screen in
            let size = screen.frame.size
            return ScreenLine(id: screen.displayID, name: screen.localizedName,
                              size: "\(number(size.width)) × \(number(size.height))",
                              resolution: "\(number(size.width))x\(number(size.height))",
                              isBuiltIn: screen.isBuiltIn)
        }
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}

/// `TextEditor` is an `NSTextView`, which by default turns `"` into curly quotes, and the JSON in it is
/// code. Finds that text view and switches the substitutions that would corrupt it off.
private struct PlainTextTraits: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let text = Self.textView(in: view) {
                    text.isAutomaticQuoteSubstitutionEnabled = false
                    text.isAutomaticDashSubstitutionEnabled = false
                    text.isAutomaticTextReplacementEnabled = false
                    text.isAutomaticSpellingCorrectionEnabled = false
                    return
                }
                ancestor = view.superview
            }
        }

        private static func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            for child in view.subviews {
                if let text = textView(in: child) { return text }
            }
            return nil
        }
    }
}
