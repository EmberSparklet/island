import Foundation
import IslandCore

/// Runs `/usr/bin/sqlite3 -json`. Only SELECT/ATTACH statements are ever passed,
/// and `sqlite3` ships with macOS, so this adds no dependency.
///
/// Note: the Codex databases fail to open with sqlite3's `-readonly` flag on
/// this machine (the connection cannot recover the WAL), so the read-write
/// default is used with read-only queries.
struct ProcessSQLiteQuerying: SQLiteQuerying {
    private let executable = "/usr/bin/sqlite3"

    func query(database: URL, sql: String) -> String? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-json", database.path, sql]
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        do {
            try process.run()
        } catch {
            log("cannot run \(executable): \(error.localizedDescription)")
            return nil
        }
        // stderr stays tiny (sqlite3 prints one error and exits), so draining
        // stdout first cannot deadlock on a full stderr pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(data: errorData, encoding: .utf8) ?? ""
            log(
                "sqlite3 exited \(process.terminationStatus) on \(database.lastPathComponent):"
                    + " \(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func log(_ message: String) {
        IslandLog.write(message)
    }
}
