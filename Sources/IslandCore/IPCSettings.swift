import Foundation

/// Where the inbound channel listens, resolved once at startup.
///
/// Behaviour switches stay in `ISLAND_*` environment variables (CONTEXT.md
/// § Conventions): `ISLAND_IPC=off` disables the channel, `ISLAND_IPC_PATH`
/// moves the socket (tests and probes use a scratch path).
public struct IPCSettings: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case enabled(URL)
        case disabled
    }

    public static let environmentKey = "ISLAND_IPC"
    public static let pathEnvironmentKey = "ISLAND_IPC_PATH"
    /// The default lives next to the VS Code handshake directory, under the
    /// same `island` root.
    public static let relativePath = "Library/Application Support/island/ipc/island.sock"

    public let state: State

    public init(state: State) {
        self.state = state
    }

    public var isEnabled: Bool {
        if case .enabled = state { return true }
        return false
    }

    public var socketURL: URL? {
        if case .enabled(let url) = state { return url }
        return nil
    }

    public static func resolve(
        environment: [String: String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> IPCSettings {
        let switchValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let switchValue, ["off", "0", "false", "no"].contains(switchValue) {
            return IPCSettings(state: .disabled)
        }
        let override = environment[pathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return IPCSettings(state: .enabled(URL(fileURLWithPath: expanded)))
        }
        return IPCSettings(
            state: .enabled(
                home.appendingPathComponent(relativePath, isDirectory: false)))
    }
}
