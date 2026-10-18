import Foundation
import IslandCore

/// Everything the app reads from the environment and from what the user set in
/// the app, resolved once at startup.
struct ResolvedConfiguration {
    static let hotkeyEnvironmentKey = "ISLAND_HOTKEY"
    static let durationEnvironmentKey = "ISLAND_OVERLAY_SECONDS"
    static let taskLimitEnvironmentKey = "ISLAND_TASK_LIMIT"

    let hotkey: HotkeyConfiguration
    let hotkeyEnabled: Bool
    let duration: OverlayDuration
    let taskLimit: Int
    let agentHome: URL
    let ipc: IPCSettings
    let launcher: LauncherSettings
    /// Something is saved for the mode ring but it cannot be read, so the
    /// built-in ring took over. Reported rather than swallowed: otherwise
    /// "never saved" and "your saved ring is broken" look identical.
    let launcherStorageUnreadable: Bool

    init(
        environment: [String: String],
        store: HotkeyStoring = UserDefaultsHotkeyStore(),
        launcherStore: LauncherStoring = UserDefaultsLauncherStore()
    ) {
        hotkey = HotkeyConfiguration.resolve(
            environment[Self.hotkeyEnvironmentKey],
            stored: store.loadHotkeyText()
        )
        hotkeyEnabled = HotkeySettingsCoordinator.initialEnabled(stored: store.loadHotkeyEnabled())
        duration = OverlayDuration.resolve(environment[Self.durationEnvironmentKey])
        taskLimit = TaskLimit.resolve(environment[Self.taskLimitEnvironmentKey])
        agentHome = AgentHome.resolve(environment[AgentHome.environmentKey])
        ipc = IPCSettings.resolve(environment: environment)
        launcher = LauncherSettings.resolve(
            environment: environment, stored: launcherStore.load())
        launcherStorageUnreadable = launcherStore.hasUnreadableValue
    }

    var summary: String {
        var lines = [
            "hotkey            \(hotkey.spec.displayString)  (\(sourceNote)\(hotkeyEnabled ? "" : ", disabled"))",
            "overlay duration  \(Self.secondsText(duration.seconds))s",
            "task limit        \(taskLimit)",
            "agent home        \(agentHome.path)",
            "ipc socket        \(ipc.socketURL?.path ?? "off")",
            "launcher          \(launcherSummary)",
        ]
        if hotkey.usedFallback {
            lines.append(
                "warning           an unusable hotkey was ignored; using \(hotkey.spec.specText)"
            )
        }
        if duration.usedFallback {
            lines.append(
                "warning           \(Self.durationEnvironmentKey) unusable; using \(Self.secondsText(OverlayDuration.fallbackSeconds))s"
            )
        }
        if launcher.ignoredInvalidEntries {
            lines.append(
                "warning           \(Launcher.targetsEnvironmentKey) has unusable entries; they were skipped"
            )
        }
        if launcherStorageUnreadable {
            lines.append(
                "warning           \(UserDefaultsLauncherStore.key) in UserDefaults is unreadable; using the built-in ring"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// `off`, or every mode of the ring in order (`Search tasks, DeepSeek`) plus
    /// where the ring came from — the Settings tab shows the same source, so a
    /// stored ring the environment overrides is not a mystery.
    private var launcherSummary: String {
        guard launcher.isEnabled else { return "off" }
        return "\(launcher.names.joined(separator: ", "))  (\(launcherSourceNote))"
    }

    private var launcherSourceNote: String {
        switch launcher.source {
        case .off: return "off"
        case .settings: return "set in island"
        case .environment: return "from \(Launcher.targetsEnvironmentKey)"
        case .builtIn: return "default"
        }
    }

    private var sourceNote: String {
        switch hotkey.source {
        case .menu: return "set in island"
        case .environment: return "from \(Self.hotkeyEnvironmentKey)"
        case .builtInDefault: return "default"
        }
    }

    /// `5` instead of `5.0`; `2.5` stays `2.5`.
    static func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }
}
