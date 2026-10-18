import Foundation

/// Which language the interface speaks. `system` follows macOS; the other two
/// pin it, which is what a user who reads English but runs a Chinese Mac wants.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english
    case simplifiedChinese

    public static let fallback = AppLanguage.system

    /// Turns the stored preference into a language that has a table.
    public static func resolved(_ stored: AppLanguage, preferred: [String]) -> AppLanguage {
        guard stored == .system else { return stored }
        let first = preferred.first?.lowercased() ?? ""
        // shortcut: Traditional Chinese also lands on the Simplified table;
        // split it off when a zh-Hant translation is actually written.
        return first.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// What the language picker shows; `English` and `中文` stay in their own
    /// language so the entry is readable whatever the current one is.
    public var label: String {
        switch self {
        case .system: return L10n.current.text(.languageSystem)
        case .english: return L10n.current.text(.languageEnglish)
        case .simplifiedChinese: return L10n.current.text(.languageChinese)
        }
    }
}

/// Every fixed piece of interface text. Cases are the table's keys, so a
/// missing translation is a compile-time-visible gap that the completeness test
/// catches rather than an English word that quietly ships.
public enum TextKey: String, CaseIterable, Sendable {
    // Overlay
    case allCaughtUp
    case newCount
    case noticeOne
    case noticeMany
    case noticeSource
    case noticeClear
    case nothingFinished
    case noMatches
    case searchTasks
    case searchOneTask
    case searchManyTasks
    case overlayHints
    case overlayHintsWithLauncher
    case launcherAsk
    case launcherHintsNextMode
    case launcherKindWeb
    case launcherDefault
    case tabLauncher
    case launcherSettingsFootnote
    case launcherAdd
    case launcherEdit
    case launcherDelete
    case launcherSheetAdd
    case launcherSheetEdit
    case launcherFieldName
    case launcherFieldBaseURL
    case launcherFieldQueryItem
    case launcherFieldOptionKey
    case launcherFieldOptionValue
    case launcherFieldOptionLabel
    case launcherOptionAdd
    case launcherOptionAutoSend
    case launcherFieldOptionEnabled
    case launcherSave
    case launcherCancel
    case launcherSource
    case launcherSourceSettings
    case launcherSourceEnvironment
    case launcherSourceBuiltIn
    case launcherSourceOff
    case launcherIssueName
    case launcherIssueBaseURL
    case launcherIssueQueryItem
    case launcherIssueOptionKeyEmpty
    case launcherIssueOptionKeyUnusable
    case launcherIssueOptionKeyDuplicated

    // Menu bar
    case summonOverlayWith
    case summonHotkey
    case hotkeyWithSource
    case hotkeyOffFree
    case popupOnFor
    case popupOffCountStill
    case updateAvailable
    case openSettings
    case launchAtLogin
    case lastAttemptFailed
    case quitIsland
    case tooltipSummon
    case tooltipHotkeyOff
    case automationLimited
    case hotkeySourceMenu
    case hotkeySourceEnvironment
    case hotkeySourceDefault

    // Settings window
    case settingsTitle
    case tabGeneral
    case tabAppearance
    case tabNotifications
    case tabAgents
    case tabUpdates
    case tabFeedback
    case updatesTabAttention
    case showKeyboardHints
    case popupOnFinish
    case enabled
    case summonHotkeyTitle
    case recordHelp
    case clearButton
    case resetToDefault
    case applyButton
    case overlayThemeTitle
    case themeHelp
    case languageTitle
    case languageHelp
    case popupTitle
    case stayOnScreenFor
    case secondsUnit
    case popupHelp
    case hintActive
    case hintHotkeyOffApply
    case hintPressApply
    case failNeedsModifier
    case failPressComboFirst
    case failRefusedKept
    case failRefusedStaysOff
    case hintSwitchedOffFree
    case hintSwitchedOff
    case hintSaved
    case errorEmpty
    case errorMissingModifier
    case errorUnknownModifier
    case errorUnknownKey
    case pressCombination
    case recorderNone

    // Language picker
    case languageSystem
    case languageEnglish
    case languageChinese

    // Themes
    case themeSystem
    case themeLagoon
    case themeCoral
    case themeSand
    case themeMidnight
    case themeLiquidGlass

    // Agents tab
    case agentsFootnote
    case clickAction

    // Feedback tab
    case sendFeedback
    case feedbackIntro
    case sendEmail
    case openGitHubIssue
    case copyButton
    case feedbackEmpty
    case feedbackNoMailApp
    case feedbackMailOpened
    case feedbackNoBrowser
    case feedbackGitHubOpened
    case feedbackCopied

    // Updates tab
    case checkNow
    case checkAutomatically
    case versionLabel
    case upgradeFailedLog
    case upgradeExplain
    case notHomebrew
    case updateChecking
    case updateFailed
    case updateUpToDate
    case updateAvailableDetail
    case updateDevBuild
    case updateActionBrew
    case updateActionDownload

    // Row age
    case ageNow
    case ageMinutes
    case ageHours
    case ageDays

    // Move to Applications
    case moveToApplications
    case notNow
    case movePromptMessage
    case moveWhyTranslocated
    case moveWhyDiskImage
    case movePromptSuffix
    case moveDragHint

    // Launch at login
    case loginAllowHint
    case loginMoveHint

    // Automation
    case automationMenuTitle
}

/// The three lines Settings → Agents shows for one scenario.
public struct ScenarioText: Equatable, Sendable {
    public let title: String
    public let detection: String
    public let jumpBack: String
}

/// The interface texts of one language, plus the current one for the whole
/// process. `IslandCore` starts in English so tests and CLI output stay
/// deterministic; the app switches it once at launch from the stored choice.
public struct Localizer: Equatable, Sendable {
    /// Never `.system`: resolve first, then build.
    public let language: AppLanguage

    private let texts: [TextKey: String]
    private let scenarios: [String: ScenarioText]

    public init(language: AppLanguage) {
        let resolved: AppLanguage = language == .system ? .english : language
        self.init(
            language: resolved, texts: Self.texts(for: resolved),
            scenarios: Self.scenarios(for: resolved))
    }

    /// Carries its own tables, so a test can hand it an empty one and reach the
    /// fallbacks below instead of trusting that they never run.
    init(language: AppLanguage, texts: [TextKey: String], scenarios: [String: ScenarioText]) {
        self.language = language
        self.texts = texts
        self.scenarios = scenarios
    }

    public static let english = Localizer(language: .english)
    public static let chinese = Localizer(language: .simplifiedChinese)

    public func text(_ key: TextKey) -> String {
        texts[key] ?? key.rawValue
    }

    /// `%d` / `%@` templates, so word order can differ per language.
    public func formatted(_ key: TextKey, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    public func scenario(_ id: String) -> ScenarioText? {
        scenarios[id]
    }

    static func texts(for language: AppLanguage) -> [TextKey: String] {
        language == .simplifiedChinese ? chineseTexts : englishTexts
    }

    static func scenarios(for language: AppLanguage) -> [String: ScenarioText] {
        language == .simplifiedChinese ? chineseScenarios : englishScenarios
    }
}

/// The language every screen draws in right now.
public enum L10n {
    // `unsafe`: the value is written once at launch, before any UI exists, and
    // read afterwards from the main thread only. A lock would buy nothing.
    nonisolated(unsafe) public private(set) static var current = Localizer.english

    /// `preferred` is `Locale.preferredLanguages` in the app; tests pass it
    /// explicitly so a Chinese Mac does not silently change their assertions.
    public static func use(
        _ stored: AppLanguage, preferred: [String] = Locale.preferredLanguages
    ) {
        current = Localizer(language: AppLanguage.resolved(stored, preferred: preferred))
    }
}

// MARK: - Tables

extension Localizer {
    static let englishTexts: [TextKey: String] = [
        .allCaughtUp: "All caught up",
        .newCount: "%d new",
        .noticeOne: "1 notice",
        .noticeMany: "%d notices",
        .noticeSource: "via %@",
        .noticeClear: "Clear all",
        .nothingFinished: "Nothing has finished yet",
        .noMatches: "No matches",
        .searchTasks: "Search tasks",
        .searchOneTask: "Search 1 task",
        .searchManyTasks: "Search %d tasks",
        .overlayHints: "↑↓ move   ↩ open   ⌘1–9 jump   ⌘, settings   esc close",
        .overlayHintsWithLauncher: "↑↓ move   ↩ open   ⇥ ask   ⌘1–9 jump   ⌘, settings   esc close",
        .launcherAsk: "Ask %@…",
        .launcherHintsNextMode: "↩ send to %@   ⇥ next mode   esc cancel",
        .launcherKindWeb: "Web ask",
        .launcherDefault: "default",
        .tabLauncher: "Launcher",
        .launcherSettingsFootnote:
            "One mode per row, walked with ⇥; the first row is the mode the overlay opens in. Search tasks cannot be removed. An extra parameter only reaches the URL once it is ticked. DeepSeek needs a question of at most 800 characters to send it, a signed-in session, and the site root.",
        .launcherAdd: "Add mode…",
        .launcherEdit: "Edit",
        .launcherDelete: "Delete",
        .launcherSheetAdd: "Add mode",
        .launcherSheetEdit: "Edit mode",
        .launcherFieldName: "Name",
        .launcherFieldBaseURL: "Site address",
        .launcherFieldQueryItem: "Question parameter",
        .launcherFieldOptionKey: "Parameter",
        .launcherFieldOptionValue: "Value",
        .launcherFieldOptionLabel: "Label",
        .launcherOptionAdd: "Add parameter",
        .launcherOptionAutoSend: "Automatic send",
        .launcherFieldOptionEnabled: "Enabled",
        .launcherSave: "Save",
        .launcherCancel: "Cancel",
        .launcherSource: "source: %@",
        .launcherSourceSettings: "set in island",
        .launcherSourceEnvironment: "from ISLAND_LAUNCHER_TARGETS",
        .launcherSourceBuiltIn: "default",
        .launcherSourceOff: "off",
        .launcherIssueName: "Give the mode a name",
        .launcherIssueBaseURL: "The site address must be an http(s) URL with a host",
        .launcherIssueQueryItem: "The question parameter cannot be empty or contain & = ? #",
        .launcherIssueOptionKeyEmpty: "A parameter name cannot be empty",
        .launcherIssueOptionKeyUnusable:
            "A parameter name must be its own, without & = ? # and not the question parameter",
        .launcherIssueOptionKeyDuplicated: "A parameter name is used twice",

        .summonOverlayWith: "Summon overlay (%@)",
        .summonHotkey: "Summon hotkey",
        .hotkeyWithSource: "hotkey %@ · %@",
        .hotkeyOffFree: "hotkey off — the key is free for other apps",
        .popupOnFor: "pops up for %@s when a run finishes",
        .popupOffCountStill: "pop-up off — the count still updates",
        .updateAvailable: "Update to %@ available…",
        .openSettings: "Settings…",
        .launchAtLogin: "Launch at login",
        .lastAttemptFailed: "last attempt failed: %@",
        .quitIsland: "Quit island",
        .tooltipSummon: "island — summon with %@",
        .tooltipHotkeyOff: "island — hotkey switched off",
        .automationLimited:
            "island could only bring the app forward, not the exact tab. Turn island on for these apps in Privacy & Security → Automation.",
        .hotkeySourceMenu: "set in island",
        .hotkeySourceEnvironment: "from ISLAND_HOTKEY",
        .hotkeySourceDefault: "default",

        .settingsTitle: "island settings",
        .tabGeneral: "General",
        .tabAppearance: "Appearance",
        .tabNotifications: "Notifications",
        .tabAgents: "Agents",
        .tabUpdates: "Updates",
        .tabFeedback: "Feedback",
        .updatesTabAttention: "Updates 🔴",
        .showKeyboardHints: "Show keyboard hints",
        .popupOnFinish: "Pop up when an agent run finishes",
        .enabled: "Enabled",
        .summonHotkeyTitle: "Summon hotkey",
        .recordHelp: "Click to record, then press ⌘⌃⌥⇧ + a key. Esc cancels.",
        .clearButton: "Clear",
        .resetToDefault: "Reset to default",
        .applyButton: "Apply",
        .overlayThemeTitle: "Overlay theme",
        .themeHelp: "Applies immediately; the overlay shows a preview.",
        .languageTitle: "Language",
        .languageHelp: "The menu bar and overlay update at once; reopen this window to refresh it.",
        .popupTitle: "Pop-up",
        .stayOnScreenFor: "Stay on screen for",
        .secondsUnit: "seconds",
        .popupHelp:
            "Hovering the pop-up keeps it open. The menu bar counts unread runs either way;\nruns you watched finish are listed without a dot or a pop-up.",
        .hintActive: "active: %@",
        .hintHotkeyOffApply: "hotkey is off — Apply a combination to switch it back on",
        .hintPressApply: "press Apply to bind %@",
        .failNeedsModifier: "needs a key plus at least one modifier, e.g. ⌃⌘,",
        .failPressComboFirst:
            "press a key combination first, or use Clear to switch the hotkey off",
        .failRefusedKept: "macOS refused it (%@); kept %@",
        .failRefusedStaysOff: "macOS refused it (%@); the hotkey stays off",
        .hintSwitchedOffFree: "hotkey switched off; the key is free for other apps",
        .hintSwitchedOff: "hotkey switched off",
        .hintSaved: "saved: %@ — already active",
        .errorEmpty: "press a key combination first",
        .errorMissingModifier: "needs at least one modifier, e.g. ⌃⌘,",
        .errorUnknownModifier: "unknown modifier \"%@\"",
        .errorUnknownKey: "unknown key \"%@\"",
        .pressCombination: "Press a combination…",
        .recorderNone: "None",

        .languageSystem: "System",
        .languageEnglish: "English",
        .languageChinese: "中文",

        .themeSystem: "System",
        .themeLagoon: "Lagoon",
        .themeCoral: "Coral",
        .themeSand: "Sand",
        .themeMidnight: "Midnight",
        .themeLiquidGlass: "Liquid Glass",

        .agentsFootnote:
            "island only watches what is switched on. Runs switched off are neither counted\nnor listed (island --scan-agents still shows them, marked off).",
        .clickAction: "Click: %@",

        .sendFeedback: "Send feedback",
        .feedbackIntro:
            "A bug, an idea, anything. Your island and macOS versions are added for you.",
        .sendEmail: "Send Email",
        .openGitHubIssue: "Open GitHub Issue",
        .copyButton: "Copy",
        .feedbackEmpty: "Write something first.",
        .feedbackNoMailApp: "No mail app answered; copied instead — paste it into a mail to %@.",
        .feedbackMailOpened: "Opened in your mail app — press Send there. Thank you!",
        .feedbackNoBrowser: "Could not open the browser; copied instead.",
        .feedbackGitHubOpened: "Opened on GitHub — submit it there. Thank you!",
        .feedbackCopied: "Copied — paste it into a mail to %@.",

        .checkNow: "Check Now",
        .checkAutomatically: "Check for updates automatically",
        .versionLabel: "Version",
        .upgradeFailedLog: "The last upgrade failed; see ~/Library/Logs/island-upgrade.log.",
        .upgradeExplain:
            "Upgrading quits island, runs brew upgrade --cask %@,\nand opens island again.",
        .notHomebrew:
            "island was not installed with Homebrew, so updates open the download page.\nTip: brew install --cask %@ enables one-click upgrades.",
        .updateChecking: "Checking for updates…",
        .updateFailed: "Could not check for updates (you have %@).",
        .updateUpToDate: "island %@ is up to date.",
        .updateAvailableDetail: "island %@ is available — you have %@.",
        .updateDevBuild: "This is a development build (%@); install with Homebrew to get updates.",
        .updateActionBrew: "Upgrade to %@ & Relaunch",
        .updateActionDownload: "Download %@…",

        .ageNow: "now",
        .ageMinutes: "%dm",
        .ageHours: "%dh",
        .ageDays: "%dd",

        .moveToApplications: "Move to Applications",
        .notNow: "Not Now",
        .movePromptMessage: "Move island to your Applications folder?",
        .moveWhyTranslocated:
            "macOS is running island from a temporary, read-only copy because it was not moved into Applications.",
        .moveWhyDiskImage:
            "island is running from the disk image, which goes away once it is ejected.",
        .movePromptSuffix:
            " Launch at login only works from Applications. island can copy itself there and reopen.",
        .moveDragHint:
            "Drag Island into the Applications folder in Finder, then open it from there.",

        .loginAllowHint: "allow island in System Settings → General → Login Items",
        .loginMoveHint: "move Island.app to /Applications, then try again",

        .automationMenuTitle: "Allow island to control %@…",
    ]

    static let chineseTexts: [TextKey: String] = [
        .allCaughtUp: "全部已读",
        .newCount: "%d 条未读",
        .noticeOne: "1 条外部通知",
        .noticeMany: "%d 条外部通知",
        .noticeSource: "来自 %@",
        .noticeClear: "全部清除",
        .nothingFinished: "还没有任务完成",
        .noMatches: "没有匹配的任务",
        .searchTasks: "搜索任务",
        .searchOneTask: "搜索 1 个任务",
        .searchManyTasks: "搜索 %d 个任务",
        .overlayHints: "↑↓ 选择   ↩ 打开   ⌘1–9 直达   ⌘, 设置   esc 关闭",
        .overlayHintsWithLauncher: "↑↓ 选择   ↩ 打开   ⇥ 提问   ⌘1–9 直达   ⌘, 设置   esc 关闭",
        .launcherAsk: "问 %@…",
        .launcherHintsNextMode: "↩ 发送到 %@   ⇥ 切换模式   esc 取消",
        .launcherKindWeb: "网页提问",
        .launcherDefault: "默认",
        .tabLauncher: "启动器",
        .launcherSettingsFootnote:
            "一行一个模式，用 ⇥ 依次经过；第一行就是召唤后直接进入的模式。「搜索任务」不可删除。附加参数只有勾选后才写进网址。DeepSeek 的「自动发送」要求问题不超过 800 字、已登录，且只在站点根路径生效。",
        .launcherAdd: "添加模式…",
        .launcherEdit: "编辑",
        .launcherDelete: "删除",
        .launcherSheetAdd: "添加模式",
        .launcherSheetEdit: "编辑模式",
        .launcherFieldName: "名称",
        .launcherFieldBaseURL: "站点基址",
        .launcherFieldQueryItem: "问题参数名",
        .launcherFieldOptionKey: "参数名",
        .launcherFieldOptionValue: "值",
        .launcherFieldOptionLabel: "标签",
        .launcherOptionAdd: "添加参数",
        .launcherOptionAutoSend: "自动发送",
        .launcherFieldOptionEnabled: "启用",
        .launcherSave: "保存",
        .launcherCancel: "取消",
        .launcherSource: "生效来源：%@",
        .launcherSourceSettings: "设置页",
        .launcherSourceEnvironment: "环境变量 ISLAND_LAUNCHER_TARGETS",
        .launcherSourceBuiltIn: "内置",
        .launcherSourceOff: "已关闭",
        .launcherIssueName: "给这个模式起个名字",
        .launcherIssueBaseURL: "站点基址必须是带 host 的 http(s) 网址",
        .launcherIssueQueryItem: "问题参数名不能为空，也不能含 & = ? #",
        .launcherIssueOptionKeyEmpty: "参数名不能为空",
        .launcherIssueOptionKeyUnusable: "参数名必须独立，不能含 & = ? #，也不能与问题参数同名",
        .launcherIssueOptionKeyDuplicated: "参数名重复了",

        .summonOverlayWith: "召唤悬浮窗（%@）",
        .summonHotkey: "启用召唤快捷键",
        .hotkeyWithSource: "快捷键 %@ · %@",
        .hotkeyOffFree: "快捷键已关闭 — 组合键已释放给其他应用",
        .popupOnFor: "任务完成时弹出 %@ 秒",
        .popupOffCountStill: "自动弹出已关闭 — 未读数照常更新",
        .updateAvailable: "有可用更新 %@…",
        .openSettings: "设置…",
        .launchAtLogin: "开机自启",
        .lastAttemptFailed: "上次尝试失败：%@",
        .quitIsland: "退出 island",
        .tooltipSummon: "island — 按 %@ 召唤",
        .tooltipHotkeyOff: "island — 快捷键已关闭",
        .automationLimited:
            "island 只能把对应 app 切到前台，无法定位到具体 tab。请在「系统设置 → 隐私与安全性 → 自动化」里为这些 app 打开 island。",
        .hotkeySourceMenu: "应用内设置",
        .hotkeySourceEnvironment: "来自 ISLAND_HOTKEY",
        .hotkeySourceDefault: "默认",

        .settingsTitle: "island 设置",
        .tabGeneral: "通用",
        .tabAppearance: "外观",
        .tabNotifications: "通知",
        .tabAgents: "Agent",
        .tabUpdates: "更新",
        .tabFeedback: "反馈",
        .updatesTabAttention: "更新 🔴",
        .showKeyboardHints: "显示键盘提示",
        .popupOnFinish: "任务完成时自动弹出",
        .enabled: "启用",
        .summonHotkeyTitle: "召唤快捷键",
        .recordHelp: "点击后按下 ⌘⌃⌥⇧ 加一个键开始录制。按 esc 取消。",
        .clearButton: "清除",
        .resetToDefault: "恢复默认",
        .applyButton: "应用",
        .overlayThemeTitle: "悬浮窗主题",
        .themeHelp: "立即生效，悬浮窗会显示预览。",
        .languageTitle: "语言",
        .languageHelp: "菜单栏与悬浮窗立即更新；本窗口需重开后才会变成新语言。",
        .popupTitle: "自动弹出",
        .stayOnScreenFor: "停留时间",
        .secondsUnit: "秒",
        .popupHelp:
            "鼠标停在悬浮窗上会暂停自动隐藏。无论是否弹出，菜单栏都会统计未读；\n你看着它完成的任务不弹出、也不带红点。",
        .hintActive: "当前：%@",
        .hintHotkeyOffApply: "快捷键已关闭 — 按「应用」重新启用",
        .hintPressApply: "按「应用」绑定 %@",
        .failNeedsModifier: "需要按下一个键，并至少一个修饰键，例如 ⌃⌘，",
        .failPressComboFirst: "请先按下组合键，或用「清除」关闭快捷键",
        .failRefusedKept: "macOS 拒绝了该组合（%@）；已保留 %@",
        .failRefusedStaysOff: "macOS 拒绝了该组合（%@）；快捷键保持关闭",
        .hintSwitchedOffFree: "快捷键已关闭，组合键已释放给其他应用",
        .hintSwitchedOff: "快捷键已关闭",
        .hintSaved: "已保存：%@ — 已生效",
        .errorEmpty: "请先按下组合键",
        .errorMissingModifier: "至少需要一个修饰键，例如 ⌃⌘，",
        .errorUnknownModifier: "未知修饰键「%@」",
        .errorUnknownKey: "未知按键「%@」",
        .pressCombination: "请按组合键…",
        .recorderNone: "未设置",

        .languageSystem: "跟随系统",
        .languageEnglish: "English",
        .languageChinese: "中文",

        .themeSystem: "跟随系统",
        .themeLagoon: "泻湖",
        .themeCoral: "珊瑚",
        .themeSand: "沙滩",
        .themeMidnight: "午夜",
        .themeLiquidGlass: "液态玻璃",

        .agentsFootnote:
            "island 只监视已打开的场景。关闭的场景既不计数也不列出（island --scan-agents 仍会显示它们，并标记为已关闭）。",
        .clickAction: "点击后：%@",

        .sendFeedback: "发送反馈",
        .feedbackIntro: "bug、想法，什么都可以。island 版本和 macOS 版本会自动附上。",
        .sendEmail: "发送邮件",
        .openGitHubIssue: "打开 GitHub Issue",
        .copyButton: "复制",
        .feedbackEmpty: "请先写点内容。",
        .feedbackNoMailApp: "没有邮件应用响应；已改为复制 — 请粘贴到发给 %@ 的邮件里。",
        .feedbackMailOpened: "已在邮件应用中打开 — 请在那里点击发送。谢谢！",
        .feedbackNoBrowser: "无法打开浏览器；已改为复制。",
        .feedbackGitHubOpened: "已在 GitHub 打开 — 请在那里提交。谢谢！",
        .feedbackCopied: "已复制 — 请粘贴到发给 %@ 的邮件里。",

        .checkNow: "立即检查",
        .checkAutomatically: "自动检查更新",
        .versionLabel: "版本",
        .upgradeFailedLog: "上次升级失败；详见 ~/Library/Logs/island-upgrade.log。",
        .upgradeExplain: "升级会退出 island，执行 brew upgrade --cask %@，然后重新打开 island。",
        .notHomebrew:
            "island 不是用 Homebrew 安装的，所以更新会打开下载页。\n提示：brew install --cask %@ 之后即可一键升级。",
        .updateChecking: "正在检查更新…",
        .updateFailed: "无法检查更新（当前 %@）。",
        .updateUpToDate: "island %@ 已是最新版本。",
        .updateAvailableDetail: "island %@ 可用 — 当前 %@。",
        .updateDevBuild: "这是开发版（%@）；用 Homebrew 安装才能收到更新。",
        .updateActionBrew: "升级到 %@ 并重启",
        .updateActionDownload: "下载 %@…",

        .ageNow: "刚刚",
        .ageMinutes: "%d 分钟",
        .ageHours: "%d 小时",
        .ageDays: "%d 天",

        .moveToApplications: "移到「应用程序」",
        .notNow: "以后再说",
        .movePromptMessage: "要把 island 移到「应用程序」文件夹吗？",
        .moveWhyTranslocated: "macOS 正在运行 island 的临时只读副本，因为它没有被移到「应用程序」。",
        .moveWhyDiskImage: "island 正在从磁盘映像运行，推出映像后就会消失。",
        .movePromptSuffix: " 开机自启只在「应用程序」下有效。island 可以把自己复制过去并重新打开。",
        .moveDragHint: "请在访达里把 Island 拖进「应用程序」文件夹，然后从那里打开它。",

        .loginAllowHint: "在「系统设置 → 通用 → 登录项」中允许 island",
        .loginMoveHint: "把 Island.app 移到 /Applications 后重试",

        .automationMenuTitle: "允许 island 控制 %@…",
    ]

    static let englishScenarios: [String: ScenarioText] = [
        "claude-code.terminal": ScenarioText(
            title: "Terminal CLI",
            detection: "claude in tmux, cmux, Ghostty, Terminal, iTerm2 or VS Code's terminal",
            jumpBack: "Focuses the exact tab or tmux pane; else copies claude --resume"),
        "claude-code.editor": ScenarioText(
            title: "Editor extension",
            detection: "Claude Code panels inside VS Code or JetBrains IDEs",
            jumpBack: "Brings the editor window forward"),
        "claude-code.desktop": ScenarioText(
            title: "Code in the Claude app",
            detection: "Claude Code sessions started from the Claude desktop app",
            jumpBack: "Brings the Claude app forward"),
        "claude-code.headless": ScenarioText(
            title: "SDK & other entry points",
            detection: "Agent SDK and any entry point island does not know yet",
            jumpBack: "Brings its host app forward; else copies claude --resume"),
        "claude-desktop.chat": ScenarioText(
            title: "Chats",
            detection: "Replies in conversations the Claude app has open (its local cache)",
            jumpBack: "Opens the conversation (claude:// link)"),
        "pi.terminal": ScenarioText(
            title: "Terminal CLI",
            detection: "pi in any terminal, matched to its process by working directory",
            jumpBack: "Focuses the exact tab or tmux pane; else copies pi --session"),
        "codex.app": ScenarioText(
            title: "Desktop app & IDE",
            detection: "Threads from the Codex (ChatGPT) app and the VS Code extension",
            jumpBack: "Opens the thread (codex:// link)"),
        "codex.cli": ScenarioText(
            title: "Terminal CLI",
            detection: "The codex TUI in a terminal",
            jumpBack: "Opens the thread in the Codex app (codex:// link)"),
        "codex.exec": ScenarioText(
            title: "Headless exec",
            detection: "codex exec runs from scripts or CI",
            jumpBack: "Opens the thread in the Codex app (codex:// link)"),
    ]

    static let chineseScenarios: [String: ScenarioText] = [
        "claude-code.terminal": ScenarioText(
            title: "终端 CLI",
            detection: "tmux、cmux、Ghostty、Terminal、iTerm2 或 VS Code 终端里的 claude",
            jumpBack: "切到对应 tab 或 tmux pane；定位不到则复制 claude --resume"),
        "claude-code.editor": ScenarioText(
            title: "编辑器扩展",
            detection: "VS Code 或 JetBrains IDE 里的 Claude Code 面板",
            jumpBack: "把编辑器窗口切到前台"),
        "claude-code.desktop": ScenarioText(
            title: "Claude 应用里的 Code",
            detection: "从 Claude 桌面版启动的 Claude Code 会话",
            jumpBack: "把 Claude 应用切到前台"),
        "claude-code.headless": ScenarioText(
            title: "SDK 及其他入口",
            detection: "Agent SDK，以及 island 尚不认识的入口",
            jumpBack: "把宿主 app 切到前台；定位不到则复制 claude --resume"),
        "claude-desktop.chat": ScenarioText(
            title: "对话",
            detection: "Claude 应用已打开的会话里的回复（读它的本地缓存）",
            jumpBack: "打开该对话（claude:// 链接）"),
        "pi.terminal": ScenarioText(
            title: "终端 CLI",
            detection: "任意终端里的 pi，按工作目录匹配进程",
            jumpBack: "切到对应 tab 或 tmux pane；定位不到则复制 pi --session"),
        "codex.app": ScenarioText(
            title: "桌面版与 IDE",
            detection: "Codex（ChatGPT）应用与 VS Code 扩展产生的会话",
            jumpBack: "打开该会话（codex:// 链接）"),
        "codex.cli": ScenarioText(
            title: "终端 CLI",
            detection: "终端里的 codex TUI",
            jumpBack: "在 Codex 应用里打开该会话（codex:// 链接）"),
        "codex.exec": ScenarioText(
            title: "无头执行",
            detection: "脚本或 CI 里跑的 codex exec",
            jumpBack: "在 Codex 应用里打开该会话（codex:// 链接）"),
    ]
}

/// Remembers the language picked in settings.
public struct UserDefaultsLanguageStore {
    public static let key = "IslandLanguage"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppLanguage {
        guard let stored = defaults.string(forKey: Self.key) else { return .fallback }
        return AppLanguage(rawValue: stored) ?? .fallback
    }

    public func save(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
    }
}
