import Foundation

/// What a `query` may report about island. Captured on the main thread and read
/// from an IPC queue, so it is an immutable value.
public struct IPCSnapshot: Equatable, Sendable {
    public struct Task: Equatable, Sendable {
        public let id: String
        public let agent: String
        public let title: String
        public let cwd: String?
        public let completedAt: Date
        public let host: String

        public init(
            id: String, agent: String, title: String, cwd: String?, completedAt: Date, host: String
        ) {
            self.id = id
            self.agent = agent
            self.title = title
            self.cwd = cwd
            self.completedAt = completedAt
            self.host = host
        }
    }

    public let appVersion: String
    public let unreadTasks: Int
    public let tasks: [Task]

    public init(appVersion: String, unreadTasks: Int, tasks: [Task]) {
        self.appVersion = appVersion
        self.unreadTasks = unreadTasks
        self.tasks = tasks
    }

    public static let empty = IPCSnapshot(appVersion: "0.0.0", unreadTasks: 0, tasks: [])
}

/// The latest snapshot, readable from the IPC queue while the main thread
/// replaces it on every UI refresh.
public final class IPCSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IPCSnapshot

    public init(_ value: IPCSnapshot = .empty) {
        self.value = value
    }

    public func update(_ snapshot: IPCSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    public func read() -> IPCSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// One client connection's state machine. `hello` must be the first method;
/// after that every request is answered, exactly once, with the same `id`.
public struct IPCSession: Sendable {
    public enum State: Equatable, Sendable {
        case awaitingHello
        case ready(client: String)
    }

    public struct Reply: Equatable, Sendable {
        public let data: Data
        public let close: Bool
        /// The row a `notify` just created; nil for every other reply.
        public let notification: ExternalInbox.Entry?

        public init(data: Data, close: Bool, notification: ExternalInbox.Entry? = nil) {
            self.data = data
            self.close = close
            self.notification = notification
        }
    }

    public let sessionID: String
    public private(set) var state: State = .awaitingHello

    public init(sessionID: String = UUID().uuidString) {
        self.sessionID = sessionID
    }

    public mutating func handle(
        _ request: IPCRequest,
        inbox: ExternalInbox,
        snapshot: IPCSnapshot,
        now: Date = Date()
    ) -> Reply {
        switch request.method {
        case .hello(let client, _, _):
            state = .ready(client: client)
            return Reply(
                data: IPCFrame.success(id: request.id, result: helloResult(snapshot: snapshot)),
                close: false)
        case .notify(let kind, let title, let eventID):
            guard case .ready(let client) = state else { return unauthorized(request.id) }
            let added = inbox.add(
                client: client, title: title ?? kind, eventID: eventID, at: now)
            return Reply(
                data: IPCFrame.success(
                    id: request.id,
                    result: ["accepted": true, "duplicate": added == nil]),
                close: false,
                notification: added)
        case .query(let what, let limit):
            guard case .ready = state else { return unauthorized(request.id) }
            return Reply(
                data: IPCFrame.success(
                    id: request.id,
                    result: queryResult(what, limit: limit, inbox: inbox, snapshot: snapshot)),
                close: false)
        }
    }

    /// A frame that could not be parsed still gets an error reply; only bad
    /// versions and oversized frames end the connection.
    public static func reject(_ error: IPCParseError) -> Reply {
        Reply(
            data: IPCFrame.failure(id: nil, code: error.code, detail: error.detail),
            close: error.closesConnection)
    }

    private func unauthorized(_ id: String?) -> Reply {
        Reply(
            data: IPCFrame.failure(
                id: id, code: .unauthorized, detail: "send hello first"),
            close: false)
    }

    private func helloResult(snapshot: IPCSnapshot) -> [String: Any] {
        [
            "server": IPCProtocol.serverName,
            "version": snapshot.appVersion,
            "protocol": IPCProtocol.version,
            "methods": IPCProtocol.methods,
            "events": IPCProtocol.events,
            "session": sessionID,
            "limits": limits,
        ]
    }

    private func queryResult(
        _ what: IPCQuery, limit: Int?, inbox: ExternalInbox, snapshot: IPCSnapshot
    ) -> [String: Any] {
        switch what {
        case .status:
            return [
                "query": "status",
                "server": IPCProtocol.serverName,
                "version": snapshot.appVersion,
                "protocol": IPCProtocol.version,
                "methods": IPCProtocol.methods,
                "events": IPCProtocol.events,
                "limits": limits,
                "unread": ["tasks": snapshot.unreadTasks, "notifications": inbox.unreadCount],
            ]
        case .unread:
            return [
                "query": "unread",
                "tasks": snapshot.unreadTasks,
                "notifications": inbox.unreadCount,
            ]
        case .tasks:
            let items = Array(snapshot.tasks.prefix(limit ?? snapshot.tasks.count))
            let formatter = ISO8601DateFormatter()
            let rows: [[String: Any]] = items.map { task in
                var row: [String: Any] = [
                    "id": task.id,
                    "agent": task.agent,
                    "title": task.title,
                    "completed_at": formatter.string(from: task.completedAt),
                    "host": task.host,
                ]
                if let cwd = task.cwd { row["cwd"] = cwd }
                return row
            }
            return [
                "query": "tasks", "items": rows, "truncated": rows.count < snapshot.tasks.count,
            ]
        case .capabilities:
            return [
                "query": "capabilities",
                "methods": IPCProtocol.methods,
                "events": IPCProtocol.events,
                "limits": limits,
            ]
        }
    }

    private var limits: [String: Any] {
        [
            "max_frame_bytes": IPCProtocol.maxFrameBytes,
            "max_subscriptions": IPCProtocol.maxSubscriptions,
            "idle_timeout_seconds": IPCProtocol.idleTimeoutSeconds,
        ]
    }
}
