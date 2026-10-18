import Foundation

/// One optional query parameter a target may carry, e.g. `autosend=1`.
///
/// `label` is the name the user gave that switch ("Automatic send"); it is shown
/// in Settings and never reaches the URL.
public struct LauncherOption: Codable, Equatable, Sendable {
    public var key: String
    public var value: String
    public var label: String
    public var isEnabled: Bool

    public init(key: String, value: String, label: String, isEnabled: Bool = false) {
        self.key = key
        self.value = value
        self.label = label
        self.isEnabled = isEnabled
    }
}

/// A chat site the overlay can hand a typed sentence to: where it lives, which
/// query parameter carries the question, and any extra switches the site reads.
public struct LauncherTarget: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var queryItem: String
    public var options: [LauncherOption]

    public init(
        id: String, name: String, baseURL: URL, queryItem: String,
        options: [LauncherOption] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.queryItem = queryItem
        self.options = options
    }
}

/// One stop of the overlay's mode ring. `⇥` walks the ring; the first entry is
/// the mode the overlay opens in.
public enum LauncherMode: Equatable, Sendable {
    /// Filter the task list — island's own function.
    case searchTasks
    case target(LauncherTarget)

    public var target: LauncherTarget? {
        guard case .target(let target) = self else { return nil }
        return target
    }

    public var isSearchTasks: Bool { target == nil }

    /// What the overlay shows in the mode capsule. The task filter reuses the
    /// search field's own name, so capsule and placeholder agree.
    public var name: String {
        target?.name ?? L10n.current.text(.searchTasks)
    }
}

/// The ring is persisted, so its on-disk shape is spelled out instead of being
/// left to the synthesised enum coding (`{"target":{"_0":…}}`), which would
/// change the moment a case grows a second payload.
extension LauncherMode: Codable {
    private enum Kind: String, Codable {
        case searchTasks
        case target
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .searchTasks:
            self = .searchTasks
        case .target:
            self = .target(try container.decode(LauncherTarget.self, forKey: .target))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .searchTasks:
            try container.encode(Kind.searchTasks, forKey: .kind)
        case .target(let target):
            try container.encode(Kind.target, forKey: .kind)
            try container.encode(target, forKey: .target)
        }
    }
}

/// The launcher (PLAN § Scope / 扩展机制 #3): open a chat site with the sentence
/// the user typed into the overlay.
///
/// A question only prefills the site's input box unless the user explicitly
/// ticked an option that sends it (decision D9, revised by D14) — a stray Enter
/// in island must never send a message on its own.
public enum Launcher {
    /// DeepSeek is the one target measured end to end: its own bundle reads `q`,
    /// and `autosend=1` sends a question of at most 800 characters, on the root
    /// path of a logged-in session. Anything else is the user's to add.
    ///
    /// Computed rather than stored, so the option's label follows a language
    /// change, and `autosend` stays unticked until the user says otherwise.
    public static var deepSeek: LauncherTarget {
        LauncherTarget(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: URL(string: "https://chat.deepseek.com/")!,
            queryItem: "q",
            options: [
                LauncherOption(
                    key: "autosend", value: "1",
                    label: L10n.current.text(.launcherOptionAutoSend), isEnabled: false)
            ])
    }

    /// The built-in ring: the task filter, then DeepSeek. Kimi is absent on
    /// purpose — its old `_prefill_chat` deep link now redirects to the site
    /// root with the parameters dropped.
    public static var builtIn: [LauncherMode] { [.searchTasks, .target(deepSeek)] }

    /// The environment override lives in one variable (decision D13): entries
    /// are `id|name|baseURL|queryItem`, separated by `;`. Extra options are a
    /// Settings feature; this channel keeps the four fields it always had.
    public static let targetsEnvironmentKey = "ISLAND_LAUNCHER_TARGETS"

    /// A blank question opens the site itself, so the launcher still works as a
    /// plain bookmark. A target the user configured is honoured as written: its
    /// port and any query it already carries survive (the fragment does not —
    /// nothing downstream reads it). Ticked options are appended in order.
    public static func url(for target: LauncherTarget, query: String) -> URL? {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return target.baseURL }
        var components = URLComponents()
        components.scheme = target.baseURL.scheme
        components.host = target.baseURL.host
        components.port = target.baseURL.port
        components.path = target.baseURL.path
        let ticked = target.options.filter(\.isEnabled)
        // Ours win over what the base URL already carries. A base pasted out of
        // the browser's address bar often still holds its own `?q=`, and two
        // parameters with the same name let the site pick the wrong one.
        let ours = Set([target.queryItem] + ticked.map(\.key))
        let existing =
            (URLComponents(url: target.baseURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { !ours.contains($0.name) }
        components.queryItems =
            existing + [URLQueryItem(name: target.queryItem, value: question)]
            + ticked.map { URLQueryItem(name: $0.key, value: $0.value) }
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

    public static func isUsableID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    public static func isUsableQueryItem(_ item: String) -> Bool {
        !item.isEmpty && !item.contains { $0.isWhitespace || "&=?#".contains($0) }
    }

    // MARK: - The mode ring

    /// `⇥` in the overlay's keyboard mode: the next stop of the ring, wrapping at
    /// both ends. `nil` when the ring holds nothing to switch to, so the key
    /// keeps its default meaning.
    ///
    /// `esc` is deliberately *not* this function: while any mode but the task
    /// filter is showing it cancels the question and returns to the filter.
    public static func nextModeIndex(from index: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        guard index >= 0, index < count else { return 0 }
        return (index + 1) % count
    }

    /// Exactly one `searchTasks` mode, added in front when missing, and one mode
    /// per target id. Both are invariants the rest of the code leans on: `esc`
    /// needs a single task filter to fall back to, and every row action finds its
    /// mode by id, so a duplicated id would make two rows act on the same target.
    /// A corrupt or hand-edited list cannot break either.
    public static func sanitized(_ modes: [LauncherMode]) -> [LauncherMode] {
        var result: [LauncherMode] = []
        var seenSearchTasks = false
        var seenIDs: Set<String> = []
        for mode in modes {
            if mode.isSearchTasks {
                guard !seenSearchTasks else { continue }
                seenSearchTasks = true
            } else if let id = mode.target?.id {
                guard seenIDs.insert(id).inserted else { continue }
            }
            result.append(mode)
        }
        if !seenSearchTasks { result.insert(.searchTasks, at: 0) }
        return result
    }

    /// Moves one mode, `NSTableView` semantics: `row` is the insertion index in
    /// the list *before* the moved entry is taken out.
    public static func moving(_ modes: [LauncherMode], from: Int, to row: Int) -> [LauncherMode] {
        guard modes.indices.contains(from), row >= 0, row <= modes.count else { return modes }
        var result = modes
        let mode = result.remove(at: from)
        let destination = row > from ? row - 1 : row
        result.insert(mode, at: min(destination, result.count))
        return result
    }

    /// Removing the task filter is refused: `esc` needs somewhere to go back to.
    public static func removing(_ modes: [LauncherMode], at index: Int) -> [LauncherMode] {
        guard modes.indices.contains(index), !modes[index].isSearchTasks else { return modes }
        var result = modes
        result.remove(at: index)
        return result
    }

    /// Overwriting the task filter with a site is refused for the same reason.
    public static func replacing(
        _ modes: [LauncherMode], at index: Int, with mode: LauncherMode
    ) -> [LauncherMode] {
        guard modes.indices.contains(index), !modes[index].isSearchTasks else { return modes }
        var result = modes
        result[index] = mode
        return result
    }

    /// Inserting a second task filter is refused, like removing or replacing the
    /// first: `sanitized` would drop it anyway, and a silent no-op is easier to
    /// reason about than a list that briefly held two.
    public static func inserting(
        _ modes: [LauncherMode], _ mode: LauncherMode, at index: Int
    ) -> [LauncherMode] {
        guard !(mode.isSearchTasks && modes.contains(where: \.isSearchTasks)) else { return modes }
        var result = modes
        result.insert(mode, at: min(max(index, 0), result.count))
        return result
    }

    // MARK: - Editing a target

    /// What the Settings sheet edits. `id` is carried over when an existing mode
    /// is edited and generated from the name for a new one.
    public struct Draft: Equatable, Sendable {
        public var name: String
        public var baseURLText: String
        public var queryItem: String
        public var options: [LauncherOption]

        public init(
            name: String = "", baseURLText: String = "", queryItem: String = "",
            options: [LauncherOption] = []
        ) {
            self.name = name
            self.baseURLText = baseURLText
            self.queryItem = queryItem
            self.options = options
        }

        public init(_ target: LauncherTarget) {
            self.name = target.name
            self.baseURLText = target.baseURL.absoluteString
            self.queryItem = target.queryItem
            self.options = target.options
        }
    }

    /// Why a draft cannot be saved. The view renders all of them at once; nothing
    /// is dropped silently.
    public enum DraftIssue: Equatable, Sendable {
        case emptyName
        case unusableBaseURL
        case unusableQueryItem
        case optionKeyEmpty(index: Int)
        case optionKeyUnusable(index: Int)
        case optionKeyDuplicated(index: Int)

        public var textKey: TextKey {
            switch self {
            case .emptyName: return .launcherIssueName
            case .unusableBaseURL: return .launcherIssueBaseURL
            case .unusableQueryItem: return .launcherIssueQueryItem
            case .optionKeyEmpty: return .launcherIssueOptionKeyEmpty
            case .optionKeyUnusable: return .launcherIssueOptionKeyUnusable
            case .optionKeyDuplicated: return .launcherIssueOptionKeyDuplicated
            }
        }
    }

    /// The order is fixed so the sheet's error list does not jump around.
    ///
    /// Everything is judged after trimming: a stray space in a settings text
    /// field is innocent, and `target(from:keepingID:taken:)` trims the same way.
    public static func issues(in draft: Draft) -> [DraftIssue] {
        var issues: [DraftIssue] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if usableBaseURL(draft.baseURLText) == nil { issues.append(.unusableBaseURL) }
        let question = draft.queryItem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isUsableQueryItem(question) { issues.append(.unusableQueryItem) }
        var seen: Set<String> = []
        for (index, option) in draft.options.enumerated() {
            let key = option.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                issues.append(.optionKeyEmpty(index: index))
            } else if !isUsableQueryItem(key) || key == question {
                issues.append(.optionKeyUnusable(index: index))
            } else if !seen.insert(key).inserted {
                issues.append(.optionKeyDuplicated(index: index))
            }
        }
        return issues
    }

    /// `nil` when the draft has any issue; otherwise the target to store. The id
    /// is derived from the name unless `keepingID` says this is an edit.
    ///
    /// Every text field is trimmed on the way in. Validation already judges the
    /// trimmed key and value, so storing the padded originals would let a stray
    /// space slip into the URL as `%20autosend%20=1` and quietly break the site.
    public static func target(
        from draft: Draft, keepingID id: String?, taken: Set<String>
    ) -> LauncherTarget? {
        guard issues(in: draft).isEmpty, let baseURL = usableBaseURL(draft.baseURLText) else {
            return nil
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return LauncherTarget(
            id: id ?? uniqueID(from: name, taken: taken),
            name: name,
            baseURL: baseURL,
            queryItem: draft.queryItem.trimmingCharacters(in: .whitespacesAndNewlines),
            options: draft.options.map(trimmed))
    }

    private static func trimmed(_ option: LauncherOption) -> LauncherOption {
        var result = option
        result.key = option.key.trimmingCharacters(in: .whitespacesAndNewlines)
        result.value = option.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private static func usableBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// A stable, readable id derived from the display name, made unique against
    /// the ids already in use. The user never sees it.
    public static func uniqueID(from name: String, taken: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            guard scalar.isASCII, allowed.contains(scalar) else {
                pendingDash = true
                continue
            }
            if pendingDash, !slug.isEmpty { slug.unicodeScalars.append("-") }
            pendingDash = false
            slug.unicodeScalars.append(scalar)
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "mode" }
        if slug.count > 48 { slug = String(slug.prefix(48)) }
        guard taken.contains(slug) else { return slug }
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }
}

/// Whether the overlay offers the launcher at all, which mode ring it walks, and
/// where that ring came from.
///
/// Precedence (CONTEXT.md § Conventions, "app setting > environment > built-in"):
/// `ISLAND_LAUNCHER=off` wins outright, then what the user saved in Settings,
/// then `ISLAND_LAUNCHER_TARGETS`, then the built-in ring.
public struct LauncherSettings: Equatable, Sendable {
    public static let environmentKey = "ISLAND_LAUNCHER"

    public enum Source: Equatable, Sendable {
        case off
        case settings
        case environment
        case builtIn
    }

    /// Empty means switched off.
    public let modes: [LauncherMode]
    /// True when the list was set but at least one entry had to be discarded.
    public let ignoredInvalidEntries: Bool
    public let source: Source

    public init(
        modes: [LauncherMode], ignoredInvalidEntries: Bool = false, source: Source = .builtIn
    ) {
        self.modes = modes
        self.ignoredInvalidEntries = ignoredInvalidEntries
        self.source = source
    }

    public var isEnabled: Bool { !modes.isEmpty }

    /// The site modes only, in ring order.
    public var targets: [LauncherTarget] { modes.compactMap(\.target) }

    /// Every mode's display name, in ring order.
    public var names: [String] { modes.map(\.name) }

    public static func resolve(
        environment: [String: String], stored: [LauncherMode]? = nil
    ) -> LauncherSettings {
        let switchValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let switchValue, ["off", "0", "false", "no"].contains(switchValue) {
            return LauncherSettings(modes: [], source: .off)
        }
        if let stored, !stored.isEmpty {
            return LauncherSettings(modes: Launcher.sanitized(stored), source: .settings)
        }
        let list = environment[Launcher.targetsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list, !list.isEmpty else {
            return LauncherSettings(modes: Launcher.builtIn, source: .builtIn)
        }

        let parsed = Launcher.parseTargets(list)
        guard !parsed.targets.isEmpty else {
            // A list of separators only holds no entry at all, so it reads as
            // "unset"; anything else present was a mistake worth reporting.
            return LauncherSettings(
                modes: Launcher.builtIn, ignoredInvalidEntries: parsed.skipped > 0,
                source: .builtIn)
        }
        return LauncherSettings(
            modes: [.searchTasks] + parsed.targets.map(LauncherMode.target),
            ignoredInvalidEntries: parsed.skipped > 0, source: .environment)
    }
}
