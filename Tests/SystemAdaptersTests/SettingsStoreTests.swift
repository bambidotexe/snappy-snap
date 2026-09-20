import Testing
import Foundation
@testable import SystemAdapters
import SnapCore

@Suite @MainActor struct SettingsStoreTests {
    func freshDefaults() -> UserDefaults {
        let name = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsWithDefaultsWhenEmpty() {
        #expect(SettingsStore(defaults: freshDefaults()).settings == Settings())
    }

    /// Loading rewrites nothing: what was stored is what comes back, field for field. No migration
    /// belongs here — `didSet` does not fire in `init`, so one would re-run on every launch.
    @Test func noStoredValueIsRewrittenOnLoad() throws {
        let defaults = freshDefaults()
        var stored = Settings()
        stored.gapEnabled = false
        stored.smoothness = .smooth
        defaults.set(try JSONEncoder().encode(stored), forKey: SettingsStore.defaultsKey)
        let first = SettingsStore(defaults: defaults)
        #expect(first.settings == stored, "loading changes nothing at all")

        // And it survives being written back: changing a different setting re-encodes the whole struct.
        first.settings.corners = false
        let second = SettingsStore(defaults: defaults)
        #expect(second.settings.gapEnabled == false)
        #expect(second.settings.smoothness == .smooth)
        #expect(second.settings.corners == false)
    }

    @Test func persistsChanges() {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.settings.gapEnabled = false
        first.settings.handleBar = false
        let second = SettingsStore(defaults: defaults)
        #expect(second.settings.gapEnabled == false)
        #expect(second.settings.handleBar == false)
    }

    /// A file from a version where the gap was a number loads as the switch it means.
    @Test func aLegacyGapNumberLoadsAsTheSwitch() {
        let defaults = freshDefaults()
        defaults.set(Data(#"{"gap": 0}"#.utf8), forKey: SettingsStore.defaultsKey)
        #expect(SettingsStore(defaults: defaults).settings.gapEnabled == false)
    }

    @Test func ignoresCorruptData() {
        let defaults = freshDefaults()
        defaults.set("garbage".data(using: .utf8), forKey: SettingsStore.defaultsKey)
        #expect(SettingsStore(defaults: defaults).settings == Settings())
    }
}
