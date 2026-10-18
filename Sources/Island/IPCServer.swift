import Foundation
import IslandCore

/// The Unix domain socket server behind `island notify` (P0).
///
/// All socket work runs on a private serial queue; the rest of the app only
/// reads snapshots it publishes through the callbacks. The socket is claimed
/// with the flow proven in `hai/reference/extensions/ipc.md` § 3.1: bind first,
/// and only unlink a stale file when a probe connection is refused.
final class IPCServer: @unchecked Sendable {
    struct Callbacks {
        let snapshot: @Sendable () -> IPCSnapshot
        let onNotification: @Sendable (ExternalInbox.Entry) -> Void
        let log: @Sendable (String) -> Void
    }

    enum StartResult: Equatable {
        case running(String)
        case alreadyRunning
        case disabled
        case failed(String)
    }

    private let settings: IPCSettings
    private let inbox: ExternalInbox
    private let callbacks: Callbacks
    private let queue = DispatchQueue(label: "island.ipc", qos: .utility)
    private var listener: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var socketPath: String?

    init(settings: IPCSettings, inbox: ExternalInbox, callbacks: Callbacks) {
        self.settings = settings
        self.inbox = inbox
        self.callbacks = callbacks
    }

    func start() -> StartResult {
        var result = StartResult.disabled
        queue.sync {
            result = startLocked()
        }
        return result
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    // MARK: - Lifecycle (queue only)

    private func startLocked() -> StartResult {
        guard case .enabled(let url) = settings.state else { return .disabled }
        let path = url.path
        // `sun_path` holds 104 bytes including the trailing NUL; longer paths
        // are silently truncated by the kernel, so refuse them instead.
        guard path.utf8.count <= 103 else {
            return .failed("socket path is longer than 103 bytes: \(path)")
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("cannot create \(directory.path): \(error.localizedDescription)")
        }
        // The attributes above are only applied when the directory is created.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket() failed: \(errno)") }
        if bindUnix(fd, path) != 0 {
            let bindError = errno
            close(fd)
            guard bindError == EADDRINUSE else {
                return .failed("bind(\(path)) failed: \(bindError)")
            }
            if probe(path) {
                return .alreadyRunning
            }
            unlink(path)
            let retry = socket(AF_UNIX, SOCK_STREAM, 0)
            guard retry >= 0, bindUnix(retry, path) == 0 else {
                let failure = errno
                if retry >= 0 { close(retry) }
                return .failed("bind(\(path)) failed after unlinking a stale socket: \(failure)")
            }
            return startListening(on: retry, path: path)
        }
        return startListening(on: fd, path: path)
    }

    private func startListening(on fd: Int32, path: String) -> StartResult {
        // bind() creates the file with umask-derived permissions; tighten it.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let failure = errno
            close(fd)
            unlink(path)
            return .failed("listen(\(path)) failed: \(failure)")
        }
        // Non-blocking, so the accept loop can drain every pending connection
        // and then return to the queue instead of parking on accept().
        setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = fd
        listenerSource = source
        socketPath = path
        callbacks.log("ipc listening on \(path)")
        return .running(path)
    }

    private func stopLocked() {
        guard let source = listenerSource else { return }
        source.cancel()
        listenerSource = nil
        listener = -1
        for connection in Array(connections.values) {
            connection.closeConnection()
        }
        connections.removeAll()
        if let socketPath {
            unlink(socketPath)
            self.socketPath = nil
        }
        callbacks.log("ipc stopped")
    }

    private func acceptConnections() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            setNoSigPipe(fd)
            let connection = Connection(
                fd: fd, queue: queue, inbox: inbox, callbacks: callbacks,
                onClose: { [weak self] closed in
                    self?.connections.removeValue(forKey: closed)
                })
            connections[fd] = connection
            connection.start()
        }
    }

    // MARK: - Socket helpers

    private func bindUnix(_ fd: Int32, _ path: String) -> Int32 {
        var address = UnixSocket.address(path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// True when something is still listening on `path`.
    private func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = UnixSocket.address(path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// A broken peer must not take island down with SIGPIPE.
    private func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - One connection

    private final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let queue: DispatchQueue
        private let inbox: ExternalInbox
        private let callbacks: Callbacks
        private let onClose: @Sendable (Int32) -> Void
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private var session = IPCSession()
        private var closed = false

        init(
            fd: Int32, queue: DispatchQueue, inbox: ExternalInbox, callbacks: Callbacks,
            onClose: @escaping @Sendable (Int32) -> Void
        ) {
            self.fd = fd
            self.queue = queue
            self.inbox = inbox
            self.callbacks = callbacks
            self.onClose = onClose
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { close(self.fd) }
            source.resume()
            self.source = source
        }

        func closeConnection() {
            guard !closed else { return }
            closed = true
            source?.cancel()
            source = nil
            onClose(fd)
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                closeConnection()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line)
                if closed { return }
            }
            // A client that never sends a newline must not grow the buffer
            // without bound.
            if buffer.count > IPCProtocol.maxFrameBytes {
                send(IPCSession.reject(.tooLarge))
            }
        }

        private func handle(_ line: Data) {
            switch IPCParser.parse(line) {
            case .success(let request):
                let reply = session.handle(
                    request, inbox: inbox, snapshot: callbacks.snapshot())
                send(reply)
                if let entry = reply.notification {
                    callbacks.onNotification(entry)
                }
            case .failure(let error):
                send(IPCSession.reject(error))
            }
        }

        private func send(_ reply: IPCSession.Reply) {
            guard UnixSocket.writeAll(fd, reply.data) else {
                closeConnection()
                return
            }
            if reply.close { closeConnection() }
        }

    }
}
