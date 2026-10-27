import Foundation
import IslandCore

/// Runs a command and returns its stdout, or nil when it cannot be started.
/// Shared by everything in island that shells out (`ps`, `tmux`, `osascript`, …).
enum Subprocess {
    /// How long a child may run before island gives up on it. The reopen queue is
    /// serial and osascript waits for the user's automation answer, so a single
    /// stuck child used to block every later click without leaving a log line
    /// (issue terminal-reopen-stops-working).
    static let defaultTimeout: TimeInterval = 10

    /// Exit status reported for a child island had to kill at the timeout, the
    /// same convention `timeout(1)` uses. Every caller treats non-zero as failure.
    static let timedOutStatus: Int32 = 124

    /// How long a killed child gets to actually die before it is SIGKILLed.
    private static let terminationGrace: TimeInterval = 2

    static func run(_ arguments: [String]) -> String? {
        guard let result = runWithStatus(arguments) else { return nil }
        return result.output
    }

    /// Like `run`, but also keeps the exit status and stderr.
    static func runWithStatus(
        _ arguments: [String], timeout: TimeInterval = defaultTimeout
    ) -> (
        status: Int32, output: String, error: String
    )? {
        guard let executable = arguments.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        // Named `outputPipe` / `errorPipe`: inside `catch` the bare name `error`
        // is the caught error, not the pipe.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes while the child runs: waiting for the exit first would
        // deadlock as soon as the child fills a pipe buffer.
        let collector = PipeCollector()
        collector.drain(outputPipe, isStdout: true)
        collector.drain(errorPipe, isStdout: false)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            collector.stop(outputPipe, errorPipe)
            return nil
        }

        let status: Int32
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
            status = timedOutStatus
        } else {
            status = process.terminationStatus
        }
        let (stdout, stderr) = collector.finish()
        collector.stop(outputPipe, errorPipe)
        return (status, stdout, stderr)
    }

    /// Runs AppleScript through `osascript`; the first run against an app shows
    /// macOS's automation consent prompt (NSAppleEventsUsageDescription), and
    /// blocks until the user answers — never call this on the main thread.
    static func appleScript(_ source: String) -> AppleScriptOutcome {
        guard let result = runWithStatus(["/usr/bin/osascript", "-e", source]) else {
            return .failed
        }
        return AppleScriptOutcome.classify(
            status: result.status, output: result.output, error: result.error)
    }
}

/// Collects a child's piped output on the queues `FileHandle` calls back on, so
/// `runWithStatus` can wait for the child without blocking on a pipe.
private final class PipeCollector: @unchecked Sendable {
    /// EOF arrives right after the child exits, but a descendant can inherit a
    /// pipe and hold it open — so `finish` gives up instead of waiting forever.
    private static let drainTimeout: TimeInterval = 1

    private let lock = NSLock()
    private let eof = DispatchGroup()
    private var stdout = Data()
    private var stderr = Data()

    func drain(_ pipe: Pipe, isStdout: Bool) {
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.eof.leave()
                return
            }
            self?.append(data, isStdout: isStdout)
        }
    }

    /// Waits briefly for both pipes to reach EOF, then returns what was read.
    func finish() -> (String, String) {
        _ = eof.wait(timeout: .now() + Self.drainTimeout)
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }

    func stop(_ first: Pipe, _ second: Pipe) {
        for pipe in [first, second] {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
        }
    }
}
