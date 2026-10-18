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
    /// The built-in target list. Kimi waits until its `?q=` behaviour is
    /// measured; `ISLAND_LAUNCHER_TARGETS` can add it without a rebuild.
    public static let deepSeek = LauncherTarget(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: URL(string: "https://chat.deepseek.com/")!,
        queryItem: "q")

    public static let builtIn: [LauncherTarget] = [deepSeek]

    /// The target list lives in an environment variable (decision D13): the
    /// entries are `id|name|baseURL|queryItem`, separated by `;`.
    public static let targetsEnvironmentKey = "ISLAND_LAUNCHER_TARGETS"

    /// A blank question opens the site itself, so the launcher still works as a
    /// plain bookmark. A target the user configured is honoured as written: its
    /// port and any query it already carries survive (the fragment does not —
    /// nothing downstream reads it).
    public static func url(for target: LauncherTarget, query: String) -> URL? {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return target.baseURL }
        var components = URLComponents()
        components.scheme = target.baseURL.scheme
        components.host = target.baseURL.host
        components.port = target.baseURL.port
        components.path = target.baseURL.path
        let existing =
            URLComponents(url: target.baseURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        components.queryItems =
            existing + [URLQueryItem(name: target.queryItem, value: question)]
        // shortcut: URLComponents leaves `+` literal, which the site may read
        // as a space; encode by hand if a question ever needs a literal plus.
        return components.url
    }

    /// Parses `ISLAND_LAUNCHER_TARGETS`. Entries that are not `id|name|url|query`
    /// usable targets are skipped and counted, never guessed at: a typo must not
    /// silently point a question at the wrong site.
    public static func parseTargets(_ text: String) -> (targets: [LauncherTarget], skipped: Int) {
        var targets: [LauncherTarget] = []
        var skipped = 0
        var seen: Set<String> = []
        for piece in text.split(separator: ";", omittingEmptySubsequences: false) {
            let entry = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            guard let target = target(from: entry), seen.insert(target.id).inserted else {
                skipped += 1
                continue
            }
            targets.append(target)
        }
        return (targets, skipped)
    }

    private static func target(from entry: String) -> LauncherTarget? {
        let fields = entry.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 4 else { return nil }
        let id = fields[0]
        let name = fields[1]
        let queryItem = fields[3]
        guard isUsableID(id), !name.isEmpty, isUsableQueryItem(queryItem),
            let baseURL = URL(string: fields[2]),
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = baseURL.host, !host.isEmpty
        else { return nil }
        return LauncherTarget(id: id, name: name, baseURL: baseURL, queryItem: queryItem)
    }

    private static func isUsableID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isUsableQueryItem(_ item: String) -> Bool {
        !item.isEmpty && !item.contains { $0.isWhitespace || "&=?#".contains($0) }
    }

    /// What `⇥` does in the overlay's keyboard mode. Deciding this in `IslandCore`
    /// keeps the compose keys covered by tests — the view only renders the
    /// result, and it cannot quietly glue `esc` to this path.
    public enum ComposeTabAction: Equatable, Sendable {
        /// The launcher is off, so the key keeps its default meaning.
        case ignored
        /// Start composing, with the field emptied for a fresh question.
        case begin
        /// Move to that target, leaving the typed question alone.
        case moveToTarget(Int)
        /// Nothing left to switch to, so the key leaves compose.
        case end
    }

    /// `⇥` in keyboard mode: enter compose, then walk the target list and wrap.
    /// With a single target there is nothing to switch to, so the same key ends
    /// compose, exactly as it did before the target list became configurable.
    ///
    /// `esc` is deliberately *not* this function: while composing it always
    /// leaves compose, whatever the target count.
    public static func composeTabAction(
        composing: Bool, targetIndex: Int, targetCount: Int
    ) -> ComposeTabAction {
        guard targetCount > 0 else { return .ignored }
        guard composing else { return .begin }
        guard targetCount > 1 else { return .end }
        return .moveToTarget(nextTargetIndex(current: targetIndex, count: targetCount))
    }

    /// The next target, wrapping at both ends; an out-of-range index starts over.
    private static func nextTargetIndex(current: Int, count: Int) -> Int {
        guard current >= 0, current < count else { return 0 }
        return (current + 1) % count
    }
}

/// Whether the overlay offers the launcher at all, plus the target list it
/// offers, resolved once at startup.
///
/// Behaviour switches stay in `ISLAND_*` environment variables (CONTEXT.md
/// § Conventions): `ISLAND_LAUNCHER=off` hides the launcher and beats the list.
public struct LauncherSettings: Equatable, Sendable {
    public static let environmentKey = "ISLAND_LAUNCHER"

    /// Empty means switched off.
    public let targets: [LauncherTarget]
    /// True when the list was set but at least one entry had to be discarded.
    public let ignoredInvalidEntries: Bool

    public init(targets: [LauncherTarget], ignoredInvalidEntries: Bool = false) {
        self.targets = targets
        self.ignoredInvalidEntries = ignoredInvalidEntries
    }

    public var isEnabled: Bool { !targets.isEmpty }

    public static func resolve(environment: [String: String]) -> LauncherSettings {
        let switchValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let switchValue, ["off", "0", "false", "no"].contains(switchValue) {
            return LauncherSettings(targets: [])
        }
        let list = environment[Launcher.targetsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list, !list.isEmpty else { return LauncherSettings(targets: Launcher.builtIn) }

        let parsed = Launcher.parseTargets(list)
        guard !parsed.targets.isEmpty else {
            // A list of separators only holds no entry at all, so it reads as
            // "unset"; anything else present was a mistake worth reporting.
            return LauncherSettings(
                targets: Launcher.builtIn, ignoredInvalidEntries: parsed.skipped > 0)
        }
        return LauncherSettings(
            targets: parsed.targets, ignoredInvalidEntries: parsed.skipped > 0)
    }
}
