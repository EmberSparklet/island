import Foundation

/// The wire protocol (version 1): one JSON object per line, UTF-8, `\n`-ended.
/// Requests are `v/id/method/params`, replies `v/id/ok/error/result`, events
/// `v/event/seq/data`. P0 serves `hello`, `notify`, and `query`; events and
/// subscriptions arrive in P1.
public enum IPCProtocol {
    public static let version = 1
    public static let serverName = "island"
    public static let maxFrameBytes = 64 * 1024
    public static let methods = ["hello", "notify", "query"]
    public static let events: [String] = []
    /// What a `notify` may claim to be. Unknown kinds are refused rather than
    /// stored, so a typo cannot create a row that nothing understands.
    public static let notifyKinds = ["notice", "task.finished"]
    public static let maxSubscriptions = 0
    public static let idleTimeoutSeconds = 0
    public static let maxClientLength = 64
    public static let maxTitleLength = 200
}

/// The `query` methods P0 answers. All of them are read-only.
public enum IPCQuery: String, Equatable, Sendable {
    case status
    case unread
    case tasks
    case capabilities
}

public enum IPCErrorCode: String, Equatable, Sendable {
    case badVersion = "bad_version"
    case unauthorized = "unauthorized"
    case unknownMethod = "unknown_method"
    case badParams = "bad_params"
    case tooLarge = "too_large"
    case rateLimited = "rate_limited"
    case notSubscribed = "not_subscribed"
    case internalError = "internal"
}

/// A parsed request. Parsing is strict: anything the server does not understand
/// is refused with an error frame instead of being ignored.
public struct IPCRequest: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        case hello(client: String, protocolVersion: Int, pid: Int32?)
        case notify(kind: String, title: String?, clientEventID: String)
        case query(what: IPCQuery, limit: Int?)
    }

    public let id: String?
    public let method: Method

    public init(id: String?, method: Method) {
        self.id = id
        self.method = method
    }
}

public enum IPCParseError: Error, Equatable, Sendable {
    case malformed(String)
    case tooLarge
    case badVersion(Int)
    case unknownMethod(String)
    case badParams(String)

    public var code: IPCErrorCode {
        switch self {
        case .malformed, .badParams: return .badParams
        case .tooLarge: return .tooLarge
        case .badVersion: return .badVersion
        case .unknownMethod: return .unknownMethod
        }
    }

    public var detail: String {
        switch self {
        case .malformed(let detail): return detail
        case .tooLarge: return "frame exceeds \(IPCProtocol.maxFrameBytes) bytes"
        case .badVersion(let version): return "unsupported protocol version \(version)"
        case .unknownMethod(let method): return "unknown method \(method)"
        case .badParams(let detail): return detail
        }
    }

    /// A bad version or an oversized frame is not recoverable on this
    /// connection; other errors let the client correct itself and retry.
    public var closesConnection: Bool {
        switch self {
        case .badVersion, .tooLarge: return true
        case .malformed, .unknownMethod, .badParams: return false
        }
    }
}

public enum IPCParser {
    public static func parse(_ line: Data) -> Result<IPCRequest, IPCParseError> {
        guard line.count <= IPCProtocol.maxFrameBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: line),
            let frame = object as? [String: Any]
        else { return .failure(.malformed("frame is not a JSON object")) }
        guard let version = integer(frame["v"]) else {
            return .failure(.malformed("missing v"))
        }
        guard version == IPCProtocol.version else { return .failure(.badVersion(version)) }
        guard let method = frame["method"] as? String, !method.isEmpty else {
            return .failure(.malformed("missing method"))
        }
        let id = frame["id"] as? String
        let params = frame["params"] as? [String: Any] ?? [:]
        switch method {
        case "hello": return parseHello(id: id, params: params)
        case "notify": return parseNotify(id: id, params: params)
        case "query": return parseQuery(id: id, params: params)
        default: return .failure(.unknownMethod(method))
        }
    }

    private static func parseHello(
        id: String?, params: [String: Any]
    ) -> Result<IPCRequest, IPCParseError> {
        guard let client = params["client"] as? String else {
            return .failure(.badParams("hello needs params.client"))
        }
        let name = client.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...IPCProtocol.maxClientLength).contains(name.count) else {
            return .failure(
                .badParams("params.client must be 1-\(IPCProtocol.maxClientLength) characters"))
        }
        guard let protocolVersion = integer(params["protocol"]) else {
            return .failure(.badParams("hello needs params.protocol"))
        }
        guard protocolVersion == IPCProtocol.version else {
            return .failure(.badVersion(protocolVersion))
        }
        let pid = integer(params["pid"]).map { Int32(clamping: $0) }
        return .success(
            IPCRequest(
                id: id,
                method: .hello(client: name, protocolVersion: protocolVersion, pid: pid)))
    }

    private static func parseNotify(
        id: String?, params: [String: Any]
    ) -> Result<IPCRequest, IPCParseError> {
        guard let kind = params["kind"] as? String,
            IPCProtocol.notifyKinds.contains(kind)
        else {
            return .failure(.badParams("params.kind must be one of \(IPCProtocol.notifyKinds)"))
        }
        let eventID = (params["client_event_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eventID, !eventID.isEmpty else {
            return .failure(.badParams("notify needs params.client_event_id"))
        }
        let title: String?
        switch optionalTitle(params["title"]) {
        case .success(let value): title = value
        case .failure(let error): return .failure(error)
        }
        return .success(
            IPCRequest(
                id: id,
                method: .notify(
                    kind: kind, title: title, clientEventID: eventID)))
    }

    private static func parseQuery(
        id: String?, params: [String: Any]
    ) -> Result<IPCRequest, IPCParseError> {
        guard let raw = params["what"] as? String, let what = IPCQuery(rawValue: raw) else {
            return .failure(
                .badParams("params.what must be status, unread, tasks, or capabilities"))
        }
        let limit = integer(params["limit"]).map { max(1, $0) }
        return .success(IPCRequest(id: id, method: .query(what: what, limit: limit)))
    }

    /// `title` is optional; when present it must be a non-empty string within
    /// the limit. Empty means "no title" rather than an error.
    private static func optionalTitle(_ value: Any?) -> Result<String?, IPCParseError> {
        guard let value else { return .success(nil) }
        guard let text = value as? String else {
            return .failure(.badParams("params.title must be a string"))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        guard trimmed.count <= IPCProtocol.maxTitleLength else {
            return .failure(.badParams("params.title is longer than \(IPCProtocol.maxTitleLength)"))
        }
        return .success(trimmed)
    }

    /// JSON numbers arrive as `NSNumber`; booleans must not pass for integers.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}

/// Encodes reply and error frames. The trailing newline is part of the frame.
public enum IPCFrame {
    public static func success(id: String?, result: [String: Any]) -> Data {
        var frame: [String: Any] = ["v": IPCProtocol.version, "ok": true, "result": result]
        if let id { frame["id"] = id }
        return encode(frame)
    }

    public static func failure(id: String?, code: IPCErrorCode, detail: String) -> Data {
        var frame: [String: Any] = [
            "v": IPCProtocol.version,
            "ok": false,
            "error": ["code": code.rawValue, "detail": detail],
        ]
        if let id { frame["id"] = id }
        return encode(frame)
    }

    private static func encode(_ frame: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(frame) else {
            // Not reachable from island's own frames, but a malformed payload
            // must still produce a frame the peer can parse.
            let fallback =
                #"{"error":{"code":"internal","detail":"frame encoding failed"},"ok":false,"v":1}"#
            return Data(fallback.utf8) + Data([0x0A])
        }
        // Safe: the guard above is exactly what `data(withJSONObject:)` checks.
        let body = try! JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        return body + Data([0x0A])
    }
}
