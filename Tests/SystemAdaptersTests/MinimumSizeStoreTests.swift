import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import SnapCore
@testable import SystemAdapters

/// Finder is the one regular application every Mac is running, which makes it the one pid a test
/// can ask a bundle identifier of — and it has a built-in row, so removing that row is how a test
/// reaches an application with none.
@Suite @MainActor struct MinimumSizeStoreTests {
    let finder: pid_t
    let finderRow = CGSize(width: 537, height: 316)

    init() throws {
        finder = try #require(NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first).processIdentifier
    }

    func freshDefaults() -> UserDefaults {
        let name = "MinimumSizeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The store never touches the element, so an application element stands in for a window's.
    func window(_ id: CGWindowID?) -> WindowHandle {
        WindowHandle(element: AXUIElementCreateApplication(finder), pid: finder, windowID: id)
    }

    /// A saved list that cannot be read is replaced by the built-in one, and the store says so: the Health
    /// page reports it. No saved list at all is not unreadable, it is the built-in list untouched.
    @Test func aSavedListThatCannotBeReadIsSaidToBe() {
        let defaults = freshDefaults()
        #expect(!MinimumSizeStore(defaults: defaults).storedListWasUnreadable)
        defaults.set(Data("not a list".utf8), forKey: MinimumSizeStore.defaultsKey)
        let store = MinimumSizeStore(defaults: defaults)
        #expect(store.storedListWasUnreadable)
        #expect(store.list.isBuiltIn)
    }

    @Test func aFreshStoreIsTheBuiltInListAndStoresNothing() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        #expect(store.list.isBuiltIn)
        #expect(defaults.data(forKey: MinimumSizeStore.defaultsKey) == nil)
        #expect(store.row(for: finder)?.size == finderRow)
        #expect(store.hasRow(for: finder))
        #expect(store.minimum(for: window(1)) == finderRow)
        #expect(store.minimum(forWindowID: 1, pid: finder) == finderRow)
        #expect(!store.wasProbed(window(1)))
    }

    /// Nothing is migrated: the three earlier shapes are deleted so the preferences file does not
    /// carry formats nothing understands.
    @Test func theRetiredKeysAreDeletedUnread() {
        let defaults = freshDefaults()
        defaults.set(Data("{}".utf8), forKey: "minimumSizes.v2")
        defaults.set(Data("{}".utf8), forKey: "minimumSizes.v1")
        defaults.set(Data("[]".utf8), forKey: "knownMinimums.v1")
        let store = MinimumSizeStore(defaults: defaults)
        #expect(store.list.isBuiltIn)
        for key in ["minimumSizes.v2", "minimumSizes.v1", "knownMinimums.v1"] {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived")
        }
    }

    /// **A refusal never raises the row.** It raises the window's own floor, per axis, in memory.
    @Test func aRefusalRaisesOnlyTheWindowsFloor() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        #expect(store.refused(CGSize(width: 600, height: 0), for: window(7)) == CGSize(width: 600, height: 0))
        #expect(store.minimum(for: window(7)) == CGSize(width: 600, height: 316))
        #expect(store.minimum(for: window(8)) == finderRow)
        #expect(store.row(for: finder)?.size == finderRow)
        #expect(store.list.isBuiltIn)
        #expect(defaults.data(forKey: MinimumSizeStore.defaultsKey) == nil)
        // Below the row on that axis: nothing to raise.
        #expect(store.refused(CGSize(width: 400, height: 0), for: window(8)) == CGSize(width: 400, height: 0))
        #expect(store.minimum(for: window(8)) == finderRow)
        #expect(store.refused(.zero, for: window(8)) == nil)
        // A window with no id has no floor of its own to raise.
        #expect(store.refused(CGSize(width: 600, height: 0), for: window(nil)) == nil)
        #expect(MinimumSizeStore(defaults: defaults).minimum(for: window(7)) == finderRow)
    }

    /// A free look at a smaller window lowers the row and the window's own floor, per axis, and the
    /// lowered row reaches the file.
    @Test func anObservationLowersTheRowAndTheWindowsFloorAndIsPersisted() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        store.refused(CGSize(width: 700, height: 0), for: window(7))
        let seen = store.observe(window(7), size: CGSize(width: 500, height: 320))
        #expect(seen.bundleID == "com.apple.finder")
        #expect(seen.row?.from == finderRow)
        #expect(seen.row?.to == CGSize(width: 500, height: 316))
        #expect(seen.windowFloor?.from == CGSize(width: 700, height: 0))
        #expect(seen.windowFloor?.to == CGSize(width: 500, height: 0))
        #expect(seen.loweredSomething)
        let row = store.row(for: finder)
        #expect(row?.size == CGSize(width: 500, height: 316))
        #expect(row?.origin == .measured)
        #expect(store.minimum(for: window(7)) == CGSize(width: 500, height: 316))
        #expect(!store.observe(window(7), size: CGSize(width: 600, height: 400)).loweredSomething)
        #expect(MinimumSizeStore(defaults: defaults).row(for: finder)?.size == CGSize(width: 500, height: 316))
    }

    /// The sweep sees every window on screen and may lower a row only from one the app has held.
    @Test func theSweepLowersOnlyAHeldWindow() {
        let store = MinimumSizeStore(defaults: freshDefaults())
        #expect(store.observe(windowID: 99, pid: finder, size: CGSize(width: 300, height: 200)) == nil)
        #expect(store.row(for: finder)?.size == finderRow)
        store.observe(window(99), size: finderRow)
        let seen = store.observe(windowID: 99, pid: finder, size: CGSize(width: 300, height: 200))
        #expect(seen?.row?.to == CGSize(width: 300, height: 200))
        #expect(store.row(for: finder)?.size == CGSize(width: 300, height: 200))
        // The same id under another pid is another window.
        #expect(store.observe(windowID: 99, pid: finder + 1, size: CGSize(width: 100, height: 100)) == nil)
    }

    /// A probe of an application with a row: lower moves the row, higher moves only the window.
    @Test func aProbeOfARowedApplicationLowersTheRowOrRaisesOnlyTheWindow() {
        let store = MinimumSizeStore(defaults: freshDefaults())
        let higher = store.recordProbe(CGSize(width: 700, height: 400), for: window(1))
        #expect(higher == .windowFloor(CGSize(width: 700, height: 400)))
        #expect(store.row(for: finder)?.size == finderRow)
        #expect(store.minimum(for: window(1)) == CGSize(width: 700, height: 400))
        #expect(store.wasProbed(window(1)))
        #expect(!store.wasProbed(window(2)))
        let lower = store.recordProbe(CGSize(width: 400, height: 250), for: window(2))
        #expect(lower == .nothing)
        #expect(store.row(for: finder)?.size == CGSize(width: 400, height: 250))
        #expect(store.row(for: finder)?.origin == .measured)
        #expect(store.minimum(for: window(2)) == CGSize(width: 400, height: 250))
        #expect(store.recordProbe(.zero, for: window(3)) == .nothing)
        #expect(store.wasProbed(window(3)))
    }

    /// A probe of an application with no row makes its row when both axes were believed, and only
    /// the window's floor when one was.
    @Test func aProbeOfARowlessApplicationMakesItsRowOrHalfOfAFloor() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        store.remove("com.apple.finder")
        #expect(!store.hasRow(for: finder))
        #expect(store.minimum(for: window(1)) == nil)
        let half = store.recordProbe(CGSize(width: 500, height: 0), for: window(1))
        #expect(half == .windowFloor(CGSize(width: 500, height: 0)))
        #expect(!store.hasRow(for: finder))
        #expect(store.minimum(for: window(1)) == CGSize(width: 500, height: 0))
        let whole = store.recordProbe(CGSize(width: 480, height: 300), for: window(2))
        guard case .row(let row) = whole else {
            Issue.record("expected a row, got \(whole)")
            return
        }
        #expect(row.bundleID == "com.apple.finder")
        #expect(row.name == NSRunningApplication(processIdentifier: finder)?.localizedName)
        #expect(row.size == CGSize(width: 480, height: 300))
        #expect(row.origin == .measured)
        #expect(store.list.removed.isEmpty)
        #expect(store.minimum(for: window(1)) == CGSize(width: 500, height: 300))
        #expect(MinimumSizeStore(defaults: defaults).row(for: finder)?.size == CGSize(width: 480, height: 300))
        // The measurement is the row and only the row: a smaller window seen later lowers it for the
        // probed window too, which a floor pinned at the measurement would have prevented.
        store.observe(window(3), size: CGSize(width: 400, height: 250))
        #expect(store.minimum(for: window(2)) == CGSize(width: 400, height: 250))
    }

    /// Remove means measure again — for the windows already probed this session too, or the next
    /// press would clamp at a floor the removed row left behind instead of probing.
    @Test func removingARowForgetsItsWindowsFloorsAndProbes() {
        let store = MinimumSizeStore(defaults: freshDefaults())
        store.recordProbe(CGSize(width: 700, height: 400), for: window(1))
        store.refused(CGSize(width: 800, height: 0), for: window(2))
        store.remove("com.apple.finder")
        #expect(!store.wasProbed(window(1)))
        #expect(store.minimum(for: window(1)) == nil)
        #expect(store.minimum(for: window(2)) == nil)
        #expect(store.heldWindowCount == 0)
    }

    /// Reset covers the rest: every window's own floor and every probe go with the list, so the tab
    /// and the handles agree.
    @Test func resetForgetsEveryWindowsFloorAndProbe() {
        let store = MinimumSizeStore(defaults: freshDefaults())
        store.refused(CGSize(width: 900, height: 0), for: window(1))
        store.recordProbe(.zero, for: window(2))
        store.reset()
        #expect(store.minimum(for: window(1)) == finderRow)
        #expect(!store.wasProbed(window(2)))
        #expect(store.heldWindowCount == 0)
    }

    @Test func removeIsMeasureAgainAndResetPutsTheBuiltInListBack() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        store.remove("com.apple.finder")
        #expect(store.list.removed == ["com.apple.finder"])
        #expect(defaults.data(forKey: MinimumSizeStore.defaultsKey) != nil)
        #expect(!MinimumSizeStore(defaults: defaults).hasRow(for: finder))
        store.reset()
        #expect(store.list.isBuiltIn)
        #expect(store.hasRow(for: finder))
        #expect(defaults.data(forKey: MinimumSizeStore.defaultsKey) == nil)
    }

    @Test func theUsersEditAndAddAreStoredAndAListBackAtBuiltInStoresNothing() {
        let defaults = freshDefaults()
        let store = MinimumSizeStore(defaults: defaults)
        store.edit("com.apple.finder", width: 600)
        #expect(store.row(for: finder)?.size == CGSize(width: 600, height: 316))
        #expect(store.row(for: finder)?.origin == .edited)
        store.add(bundleID: "com.example.a", name: "A", size: CGSize(width: 300, height: 200))
        #expect(store.list.row(for: "com.example.a")?.origin == .edited)
        #expect(MinimumSizeStore(defaults: defaults).list == store.list)
        store.remove("com.example.a")
        store.edit("com.apple.finder", width: 537)
        // Edited back to the built-in numbers is still an edited row, so the list is not built-in.
        #expect(!store.list.isBuiltIn)
        store.reset()
        #expect(defaults.data(forKey: MinimumSizeStore.defaultsKey) == nil)
    }

    /// The table is bounded, least recently touched first.
    @Test func theWindowTableIsCapped() {
        let store = MinimumSizeStore(defaults: freshDefaults())
        for id in 1...(MinimumSizeStore.windowCeiling + 40) {
            store.observe(window(CGWindowID(id)), size: finderRow)
        }
        #expect(store.heldWindowCount == MinimumSizeStore.windowCeiling)
        #expect(store.observe(windowID: 1, pid: finder, size: CGSize(width: 10, height: 10)) == nil)
        #expect(store.observe(windowID: CGWindowID(MinimumSizeStore.windowCeiling + 40), pid: finder,
                              size: finderRow) != nil)
    }
}
