import Foundation

/// Where the user's mode ring lives between launches.
public protocol LauncherStoring {
    /// `nil` when nothing was ever saved, or when what was saved cannot be read.
    func load() -> [LauncherMode]?
    func save(_ modes: [LauncherMode])
    /// True when something is saved under our key but cannot be read back, so a
    /// caller can say so instead of quietly falling back to the built-in ring.
    var hasUnreadableValue: Bool { get }
}

/// Keeps the ring in `UserDefaults` as JSON — the same place the hotkey, the
/// popup duration and the agent scenarios live.
///
/// Behaviour switches stay in `ISLAND_*` variables and island has no config file
/// (CONTEXT.md § Conventions, README §4.8): this is the user's own preference,
/// which is exactly what `UserDefaults` is for.
public struct UserDefaultsLauncherStore: LauncherStoring {
    public static let key = "IslandLauncherModes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable saved data must not brick the launcher: it reads as "never
    /// saved", so the built-in ring is used and the next save overwrites it.
    /// `hasUnreadableValue` is how the caller tells that apart from a first run.
    public func load() -> [LauncherMode]? {
        guard let data = defaults.data(forKey: Self.key),
            let modes = try? JSONDecoder().decode([LauncherMode].self, from: data)
        else { return nil }
        return Launcher.sanitized(modes)
    }

    public var hasUnreadableValue: Bool {
        defaults.object(forKey: Self.key) != nil && load() == nil
    }

    public func save(_ modes: [LauncherMode]) {
        guard let data = try? JSONEncoder().encode(Launcher.sanitized(modes)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
