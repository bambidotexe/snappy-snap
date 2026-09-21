import Testing
import CoreGraphics
import Foundation
@testable import SystemAdapters

@Suite @MainActor struct ParkedWindowsStoreTests {
    func freshDefaults() -> UserDefaults {
        let name = "ParkedWindowsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    let entries = [
        ParkedWindowsStore.Entry(windowID: 42, pid: 900, frame: CGRect(x: 8, y: 41, width: 744, height: 433)),
        ParkedWindowsStore.Entry(windowID: 43, pid: 901, frame: CGRect(x: 760, y: 482, width: 744, height: 433)),
    ]

    @Test func nothingParkedIsAnEmptyList() {
        #expect(ParkedWindowsStore(defaults: freshDefaults()).load().isEmpty)
    }

    /// A record that is there and cannot be read names windows nothing can put back any more: the store
    /// says so, for the Health page. No record at all, and a readable one, are not unreadable.
    @Test func aRecordThatCannotBeReadIsSaidToBe() {
        let defaults = freshDefaults()
        let store = ParkedWindowsStore(defaults: defaults)
        #expect(store.load().isEmpty)
        #expect(!store.lastLoadWasUnreadable)
        defaults.set(Data("not a list".utf8), forKey: ParkedWindowsStore.defaultsKey)
        #expect(store.load().isEmpty)
        #expect(store.lastLoadWasUnreadable)
        store.save(entries)
        #expect(store.load() == entries)
        #expect(!store.lastLoadWasUnreadable)
    }

    @Test func framesSurviveTheProcess() {
        // The whole point: the next launch reads what this one wrote.
        let defaults = freshDefaults()
        ParkedWindowsStore(defaults: defaults).save(entries)
        #expect(ParkedWindowsStore(defaults: defaults).load() == entries)
    }

    @Test func savingAnEmptyListClearsTheRecord() {
        let defaults = freshDefaults()
        let store = ParkedWindowsStore(defaults: defaults)
        store.save(entries)
        store.save([])
        #expect(store.load().isEmpty)
        #expect(defaults.object(forKey: ParkedWindowsStore.defaultsKey) == nil)
    }

    @Test func clearRemovesTheKey() {
        let defaults = freshDefaults()
        let store = ParkedWindowsStore(defaults: defaults)
        store.save(entries)
        store.clear()
        #expect(store.load().isEmpty)
    }

    @Test func aPartialRestoreKeepsWhatIsStillParked() {
        // What `restorePass` does when one window refuses: the survivors stay on disk for the next launch.
        let defaults = freshDefaults()
        let store = ParkedWindowsStore(defaults: defaults)
        store.save(entries)
        store.save([entries[1]])
        #expect(store.load() == [entries[1]])
    }

    @Test func settingsAreLeftAlone() {
        // Crash-recovery state has its own key: reading it must never disturb the user's settings.
        #expect(ParkedWindowsStore.defaultsKey != SettingsStore.defaultsKey)
    }
}
