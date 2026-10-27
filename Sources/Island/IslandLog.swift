import Foundation

/// The one place island's diagnostics also land on disk. A copy started by
/// launchd has nowhere for stderr to go, so "clicking the row did nothing" used
/// to leave no evidence at all (issue terminal-reopen-stops-working). Every line
/// still goes to stderr, so a foreground run keeps printing as before.
enum IslandLog {
    /// Start the file over once it would grow past this, so a long-running app
    /// cannot fill the disk.
    static let maxBytes = 1_048_576

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/island.log")
    }

    /// Serializes the read-modify-append on the file: callers log from the main
    /// thread, the reopen queue and IPC callbacks.
    private static let lock = NSLock()

    static func write(_ message: String) {
        let line = Data("[island] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        lock.lock()
        defer { lock.unlock() }
        append(line)
    }

    /// Appends `line`, truncating the file first when that would cross
    /// `maxBytes`. Failures are silent: logging must never break the caller.
    private static func append(_ line: Data) {
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url),
            let size = try? handle.seekToEnd()
        else { return }
        defer { try? handle.close() }
        if size + UInt64(line.count) > maxBytes {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
        }
        try? handle.write(contentsOf: line)
    }
}
