import Foundation

/// A chat agent the overlay can hand a typed sentence to: the site it lives on
/// and the query parameter that site reads a question from.
public struct LauncherTarget: Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let queryItem: String

    public init(id: String, name: String, baseURL: URL, queryItem: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.queryItem = queryItem
    }
}

/// The launcher (PLAN § Scope / 扩展机制 #3): open a chat site with the
/// sentence the user typed into the overlay.
///
/// The question only prefills the site's input box — `autosend` is deliberately
/// never set (decision D9), so a stray Enter in island cannot send a message.
public enum Launcher {
    /// The only built-in target for now: Kimi waits until `?q=` is measured.
    public static let deepSeek = LauncherTarget(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: URL(string: "https://chat.deepseek.com/")!,
        queryItem: "q")

    public static let builtIn: [LauncherTarget] = [deepSeek]

    /// A blank question opens the site itself, so the launcher still works as a
    /// plain bookmark.
    public static func url(for target: LauncherTarget, query: String) -> URL? {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return target.baseURL }
        var components = URLComponents()
        components.scheme = target.baseURL.scheme
        components.host = target.baseURL.host
        components.path = target.baseURL.path
        components.queryItems = [URLQueryItem(name: target.queryItem, value: question)]
        // shortcut: URLComponents leaves `+` literal, which the site may read
        // as a space; encode by hand if a question ever needs a literal plus.
        return components.url
    }
}

/// Whether the overlay offers the launcher at all, resolved once at startup.
/// Behaviour switches stay in `ISLAND_*` environment variables (CONTEXT.md
/// § Conventions): `ISLAND_LAUNCHER=off` hides it.
public struct LauncherSettings: Equatable, Sendable {
    public static let environmentKey = "ISLAND_LAUNCHER"

    /// `nil` means switched off.
    public let target: LauncherTarget?

    public init(target: LauncherTarget?) {
        self.target = target
    }

    public var isEnabled: Bool { target != nil }

    public static func resolve(environment: [String: String]) -> LauncherSettings {
        let switchValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let switchValue, ["off", "0", "false", "no"].contains(switchValue) {
            return LauncherSettings(target: nil)
        }
        return LauncherSettings(target: Launcher.builtIn.first)
    }
}
