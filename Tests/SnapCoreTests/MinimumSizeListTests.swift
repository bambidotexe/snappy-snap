import CoreGraphics
import Foundation
import Testing
@testable import SnapCore

@Suite struct MinimumSizeListTests {
    /// The four applications on the list that are not Apple's. Everything else built in is native.
    static let others: Set<String> = ["com.google.Chrome", "org.mozilla.firefox",
                                      "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp"]

    @Test func theBuiltInListIsNativeApplicationsAndFourOthersEachOnceWithARealSize() {
        let ids = MinimumSizeList.builtIn.map(\.bundleID)
        #expect(Set(ids).count == ids.count)
        #expect(!MinimumSizeList.builtIn.isEmpty)
        for row in MinimumSizeList.builtIn {
            #expect(!row.bundleID.isEmpty && !row.name.isEmpty)
            #expect(row.width >= 1 && row.height >= 1)
            #expect(row.origin == .builtIn)
            #expect(row.bundleID.hasPrefix("com.apple.") || Self.others.contains(row.bundleID),
                    "\(row.bundleID) is neither native nor one of the four")
        }
        for gone in ["com.microsoft.VSCode", "com.canva.affinity", "ru.keepcoder.Telegram",
                     "com.postmanlabs.mac", "com.bitwarden.desktop", "ch.sudo.cyberduck"] {
            #expect(!ids.contains(gone), "\(gone) is not on the list")
        }
    }

    @Test func aFreshListIsTheBuiltInOneSortedByNameAndStoresNothing() {
        let list = MinimumSizeList()
        #expect(list.isBuiltIn)
        #expect(list.stored.isEmpty)
        #expect(Set(list.rows) == Set(MinimumSizeList.builtIn))
        let names = list.rows.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(list.row(for: "com.apple.finder")?.size == CGSize(width: 537, height: 316))
        #expect(list.row(for: "com.example.nobody") == nil)
    }

    /// Per axis, past the 1 pt slack, and the mark says the numbers are now a measurement.
    @Test func aSmallerWindowLowersTheRowOnThatAxisOnlyAndMarksItMeasured() {
        var list = MinimumSizeList()
        let lowered = list.lower("com.apple.finder", seeing: CGSize(width: 500, height: 320))
        #expect(lowered?.from == CGSize(width: 537, height: 316))
        #expect(lowered?.to == CGSize(width: 500, height: 316))
        let row = list.row(for: "com.apple.finder")
        #expect(row?.size == CGSize(width: 500, height: 316))
        #expect(row?.origin == .measured)
        #expect(row?.name == "Finder")
        #expect(!list.isBuiltIn)
        #expect(list.stored.own.map(\.bundleID) == ["com.apple.finder"])
    }

    @Test func aWindowWithinThePointOrNotReadLowersNothing() {
        var list = MinimumSizeList()
        let r1 = list.lower("com.apple.finder", seeing: CGSize(width: 536.5, height: 316))
        #expect(r1 == nil)
        let r2 = list.lower("com.apple.finder", seeing: CGSize(width: 0, height: 0))
        #expect(r2 == nil)
        let r3 = list.lower("com.apple.finder", seeing: CGSize(width: 600, height: 400))
        #expect(r3 == nil)
        let r4 = list.lower("com.example.nobody", seeing: CGSize(width: 10, height: 10))
        #expect(r4 == nil)
        #expect(list.isBuiltIn)
    }

    /// An axis that was not read says nothing; the other one may still lower.
    @Test func anUnreadAxisSaysNothingWhileTheOtherLowers() {
        var list = MinimumSizeList()
        let lowered = list.lower("com.apple.finder", seeing: CGSize(width: 0, height: 100))
        #expect(lowered?.to == CGSize(width: 537, height: 100))
    }

    @Test func aRowlessApplicationMeasuredGetsAMeasuredRowAndARowedOneDoesNot() {
        var list = MinimumSizeList()
        let row = list.measured(CGSize(width: 480, height: 300), bundleID: "com.example.a", name: "A")
        #expect(row == MinimumRow(bundleID: "com.example.a", name: "A", width: 480, height: 300, origin: .measured))
        #expect(list.row(for: "com.example.a") == row)
        let r5 = list.measured(CGSize(width: 100, height: 100), bundleID: "com.example.a", name: "A")
        #expect(r5 == nil)
        #expect(list.row(for: "com.example.a")?.size == CGSize(width: 480, height: 300))
        let r6 = list.measured(CGSize(width: 0, height: 300), bundleID: "com.example.b", name: "B")
        #expect(r6 == nil)
        let r7 = list.measured(CGSize(width: 300, height: 300), bundleID: "", name: "blank")
        #expect(r7 == nil)
    }

    @Test func editingSetsTheSizeMarksTheRowEditedAndRefusesUnderOnePoint() {
        var list = MinimumSizeList()
        let r8 = list.edit("com.apple.finder", width: 600)
        #expect(r8)
        let row = list.row(for: "com.apple.finder")
        #expect(row?.size == CGSize(width: 600, height: 316))
        #expect(row?.origin == .edited)
        let r9 = list.edit("com.apple.finder", width: 0.5)
        #expect(!r9)
        let r10 = list.edit("com.apple.finder", height: 0)
        #expect(!r10)
        #expect(list.row(for: "com.apple.finder")?.size == CGSize(width: 600, height: 316))
        let r11 = list.edit("com.apple.finder")
        #expect(!r11)
        let r12 = list.edit("com.example.nobody", width: 300)
        #expect(!r12)
    }

    /// The user's edit is a statement about the application; the window is the evidence.
    @Test func anEditedRowIsStillLoweredByASmallerWindow() {
        var list = MinimumSizeList()
        list.edit("com.apple.finder", width: 600)
        let lowered = list.lower("com.apple.finder", seeing: CGSize(width: 537, height: 316))
        #expect(lowered?.to == CGSize(width: 537, height: 316))
        #expect(list.row(for: "com.apple.finder")?.origin == .measured)
    }

    @Test func addingMakesAnEditedRowOnceAndOnlyAValidOne() {
        var list = MinimumSizeList()
        let r13 = list.add(bundleID: " com.example.a ", name: "A", size: CGSize(width: 300, height: 200))
        #expect(r13)
        #expect(list.row(for: "com.example.a") == MinimumRow(bundleID: "com.example.a", name: "A",
                                                             width: 300, height: 200, origin: .edited))
        let r14 = list.add(bundleID: "com.example.a", name: "A again", size: CGSize(width: 1, height: 1))
        #expect(!r14)
        let r15 = list.add(bundleID: "com.apple.finder", name: "Finder", size: CGSize(width: 1, height: 1))
        #expect(!r15)
        let r16 = list.add(bundleID: "com.example.b", name: "B", size: CGSize(width: 0, height: 200))
        #expect(!r16)
        let r17 = list.add(bundleID: "  ", name: "blank", size: CGSize(width: 300, height: 200))
        #expect(!r17)
        let r18 = list.add(bundleID: "com.example.c", name: "", size: CGSize(width: 300, height: 200))
        #expect(r18)
        #expect(list.row(for: "com.example.c")?.name == "com.example.c")
    }

    /// Removing is "measure this application again": a built-in row is remembered as removed so the
    /// next launch does not bring it back, and the next measurement takes the removal with it.
    @Test func removingABuiltInRowLeavesARemovalThatTheNextMeasurementClears() {
        var list = MinimumSizeList()
        let r19 = list.remove("com.apple.finder")
        #expect(r19)
        #expect(list.row(for: "com.apple.finder") == nil)
        #expect(list.removed == ["com.apple.finder"])
        #expect(!list.rows.contains { $0.bundleID == "com.apple.finder" })
        #expect(!list.isBuiltIn)
        let r20 = list.remove("com.apple.finder")
        #expect(!r20)
        let r21 = list.measured(CGSize(width: 500, height: 300), bundleID: "com.apple.finder", name: "Finder")
        #expect(r21 != nil)
        #expect(list.removed.isEmpty)
        #expect(list.row(for: "com.apple.finder")?.origin == .measured)
    }

    @Test func removingAnOwnRowDeletesItOutright() {
        var list = MinimumSizeList()
        list.add(bundleID: "com.example.a", name: "A", size: CGSize(width: 300, height: 200))
        let r22 = list.remove("com.example.a")
        #expect(r22)
        #expect(list.row(for: "com.example.a") == nil)
        #expect(list.removed.isEmpty)
        #expect(list.isBuiltIn)
        let r23 = list.remove("com.example.nobody")
        #expect(!r23)
    }

    @Test func resetPutsTheBuiltInListBack() {
        var list = MinimumSizeList()
        list.remove("com.apple.finder")
        list.add(bundleID: "com.example.a", name: "A", size: CGSize(width: 300, height: 200))
        list.lower("com.apple.Safari", seeing: CGSize(width: 400, height: 200))
        list.reset()
        #expect(list.isBuiltIn)
        #expect(list == MinimumSizeList())
    }

    /// What is stored comes back as the same list, in a deterministic order, and a stored removal
    /// shadowed by a stored own row is dropped on the way in.
    @Test func theStoredPartRoundTripsAndRebuildsTheSameList() throws {
        var list = MinimumSizeList()
        list.remove("com.apple.finder")
        list.add(bundleID: "com.example.a", name: "A", size: CGSize(width: 300, height: 200))
        list.lower("com.apple.Safari", seeing: CGSize(width: 400, height: 200))
        let data = try JSONEncoder().encode(list.stored)
        let back = try JSONDecoder().decode(MinimumSizeList.Stored.self, from: data)
        #expect(back == list.stored)
        #expect(MinimumSizeList(stored: back) == list)
        #expect(back.own.map(\.bundleID) == ["com.apple.Safari", "com.example.a"])
        let shadowed = MinimumSizeList.Stored(
            own: [MinimumRow(bundleID: "com.apple.finder", name: "Finder", width: 500, height: 300, origin: .measured)],
            removed: ["com.apple.finder"])
        #expect(MinimumSizeList(stored: shadowed).removed.isEmpty)
        let invalid = MinimumSizeList.Stored(
            own: [MinimumRow(bundleID: "com.example.z", name: "Z", width: 0, height: 300, origin: .edited)])
        #expect(MinimumSizeList(stored: invalid).isBuiltIn)
    }

    @Test func anOwnRowOverridesABuiltInOneWithTheSameIdentifier() {
        let list = MinimumSizeList(stored: MinimumSizeList.Stored(
            own: [MinimumRow(bundleID: "com.apple.finder", name: "Finder", width: 500, height: 300, origin: .edited)]))
        #expect(list.row(for: "com.apple.finder")?.size == CGSize(width: 500, height: 300))
        #expect(list.rows.filter { $0.bundleID == "com.apple.finder" }.count == 1)
        #expect(list.rows.count == MinimumSizeList.builtIn.count)
    }
}
