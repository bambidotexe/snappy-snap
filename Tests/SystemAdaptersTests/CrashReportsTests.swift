import Testing
import Foundation
@testable import SystemAdapters

/// The crash reports are read from real files: only this process's, only the recent ones, newest first.
@Suite struct CrashReportsTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ name: String, at date: Date, in folder: URL) throws {
        let file = folder.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    @Test func onlyRecentReportsOfThisProcessAreCountedNewestFirst() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        try write("SnappySnap-2026-09-20-101010.ips", at: now.addingTimeInterval(-3_600), in: folder)
        try write("SnappySnap-2026-09-21-101010.ips", at: now.addingTimeInterval(-60), in: folder)
        try write("SnappySnap-2026-09-01-101010.ips", at: now.addingTimeInterval(-20 * 86_400), in: folder)
        try write("ExcUserFault_SnappySnap-2026-09-21-101010.ips", at: now, in: folder)
        try write("Other-2026-09-21-101010.ips", at: now, in: folder)

        let dates = CrashReports.recent(process: "SnappySnap", since: now.addingTimeInterval(-7 * 86_400),
                                        in: [folder, folder.appendingPathComponent("Retired")])
        #expect(dates.count == 2)
        #expect(dates.first.map { $0 > dates[1] } == true)
    }

    @Test func aFolderThatCannotBeReadCountsNothing() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(CrashReports.recent(process: "SnappySnap", since: .distantPast,
                                    in: [folder.appendingPathComponent("missing")]).isEmpty)
    }
}
