import Foundation
import SnapCore

/// The crash reports macOS wrote for this app. They are the user's own files, readable without any
/// permission, and the one record of a crash the app itself cannot keep: it was not running to write it.
public enum CrashReports {
    /// Where macOS writes a user process's crash reports, and the folder it moves them to once they have
    /// been read or sent.
    public static var folders: [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// When each crash report of `process` written after `since` was written, newest first. A folder that
    /// cannot be read counts nothing: the Health page then says there was no crash, which is what the only
    /// evidence says.
    public static func recent(process: String, since: Date, in folders: [URL] = folders) -> [Date] {
        var dates: [Date] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where HealthRules.isCrashReport(fileName: file.lastPathComponent, process: process) {
                guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, date > since else { continue }
                dates.append(date)
            }
        }
        return dates.sorted(by: >)
    }
}
