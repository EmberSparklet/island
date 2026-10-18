import XCTest

@testable import IslandCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        // `L10n.current` is process-wide; leave it where the app starts.
        L10n.use(.english, preferred: [])
        super.tearDown()
    }

    /// Every key is translated in both tables, and neither table carries a key
    /// that no longer exists.
    func testBothTablesTranslateExactlyTheDeclaredKeys() {
        let keys = Set(TextKey.allCases)

        XCTAssertEqual(Set(Localizer.englishTexts.keys), keys)
        XCTAssertEqual(Set(Localizer.chineseTexts.keys), keys)
    }

    func testNoTranslationIsEmpty() {
        for (key, text) in Localizer.englishTexts {
            XCTAssertFalse(text.isEmpty, "english \(key.rawValue)")
        }
        for (key, text) in Localizer.chineseTexts {
            XCTAssertFalse(text.isEmpty, "chinese \(key.rawValue)")
        }
    }

    /// A `%@` dropped in translation would silently print the wrong argument.
    func testTranslationsKeepTheirPlaceholdersInOrder() {
        for key in TextKey.allCases {
            XCTAssertEqual(
                placeholders(in: Localizer.chinese.text(key)),
                placeholders(in: Localizer.english.text(key)),
                key.rawValue)
        }
    }

    func testScenarioTextsCoverEveryScenarioInBothLanguages() {
        let ids = Set(AgentProfile.all.flatMap(\.scenarios).map(\.id))

        XCTAssertEqual(Set(Localizer.englishScenarios.keys), ids)
        XCTAssertEqual(Set(Localizer.chineseScenarios.keys), ids)
        for (id, text) in Localizer.chineseScenarios {
            XCTAssertFalse(text.title.isEmpty, id)
            XCTAssertFalse(text.detection.isEmpty, id)
            XCTAssertFalse(text.jumpBack.isEmpty, id)
        }
    }

    /// A missing entry cannot happen through `TextKey`, so an empty table is
    /// the only reachable path to the fallback — and it is the one that has to
    /// keep the UI from trapping.
    func testAMissingEntryFallsBackToTheKeyName() {
        let empty = Localizer(language: .english, texts: [:], scenarios: [:])

        XCTAssertEqual(empty.text(.allCaughtUp), "allCaughtUp")
        XCTAssertNil(empty.scenario("pi.terminal"))
    }

    func testSystemFollowsThePreferredLanguages() {
        XCTAssertEqual(AppLanguage.resolved(.system, preferred: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolved(.system, preferred: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolved(.system, preferred: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolved(.system, preferred: ["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.resolved(.system, preferred: []), .english)
    }

    func testAPinnedLanguageIgnoresTheSystem() {
        XCTAssertEqual(AppLanguage.resolved(.english, preferred: ["zh-Hans"]), .english)
        XCTAssertEqual(
            AppLanguage.resolved(.simplifiedChinese, preferred: ["en-US"]), .simplifiedChinese)
    }

    /// A localizer holds a language that has a table, never `system`.
    func testSystemIsResolvedBeforeALocalizerExists() {
        XCTAssertEqual(Localizer(language: .system).language, .english)
    }

    func testFormattingUsesTheLanguagesOwnTemplate() {
        XCTAssertEqual(Localizer.english.formatted(.newCount, 3), "3 new")
        XCTAssertEqual(Localizer.chinese.formatted(.newCount, 3), "3 条未读")
        XCTAssertEqual(
            Localizer.chinese.formatted(.hotkeyWithSource, "⌃⌘,", "默认"),
            "快捷键 ⌃⌘, · 默认")
    }

    func testUseSwitchesTheCurrentLanguage() {
        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(L10n.current.language, .simplifiedChinese)
        XCTAssertEqual(L10n.current.text(.allCaughtUp), "全部已读")

        L10n.use(.english, preferred: [])
        XCTAssertEqual(L10n.current.language, .english)
        XCTAssertEqual(L10n.current.text(.allCaughtUp), "All caught up")
    }

    func testUseFollowsTheSystemWhenNoLanguageIsPinned() {
        L10n.use(.system, preferred: ["zh-Hans-CN"])
        XCTAssertEqual(L10n.current.language, .simplifiedChinese)

        L10n.use(.system, preferred: ["en-US"])
        XCTAssertEqual(L10n.current.language, .english)
    }

    /// The app ships English by default, which is what keeps every other test
    /// in this suite deterministic.
    func testCurrentStartsInEnglish() {
        L10n.use(.english, preferred: [])
        XCTAssertEqual(L10n.current, .english)
    }

    func testLanguagePickerLabelsFollowTheTable() {
        L10n.use(.english, preferred: [])
        XCTAssertEqual(AppLanguage.system.label, "System")
        XCTAssertEqual(AppLanguage.english.label, "English")
        XCTAssertEqual(AppLanguage.simplifiedChinese.label, "中文")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(AppLanguage.system.label, "跟随系统")
    }

    /// The app calls this without `preferred`, so the default has to work.
    func testUseFallsBackToTheSystemPreferredLanguages() {
        L10n.use(.english)
        XCTAssertEqual(L10n.current.language, .english)

        L10n.use(.simplifiedChinese)
        XCTAssertEqual(L10n.current.language, .simplifiedChinese)
    }

    func testLanguageLabelsAreReadableInEitherTable() {
        XCTAssertEqual(Localizer.english.text(.languageChinese), "中文")
        XCTAssertEqual(Localizer.chinese.text(.languageEnglish), "English")
        XCTAssertEqual(Localizer.chinese.text(.languageSystem), "跟随系统")
    }

    private func placeholders(in text: String) -> [Character] {
        var found: [Character] = []
        var iterator = text.makeIterator()
        while let character = iterator.next(), character == "%" {
            if let next = iterator.next(), next == "@" || next == "d" {
                found.append(next)
            } else {
                break
            }
        }
        return found
    }
}

final class UserDefaultsLanguageStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "island.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFollowsTheSystemBeforeAnythingIsSaved() {
        XCTAssertEqual(UserDefaultsLanguageStore(defaults: defaults).load(), .system)
    }

    func testSavedLanguageSurvivesANewStoreInstance() {
        UserDefaultsLanguageStore(defaults: defaults).save(.simplifiedChinese)

        XCTAssertEqual(UserDefaultsLanguageStore(defaults: defaults).load(), .simplifiedChinese)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsLanguageStore.key), "simplifiedChinese")
    }

    func testAnUnusableStoredValueFallsBackToTheSystem() {
        defaults.set("klingon", forKey: UserDefaultsLanguageStore.key)

        XCTAssertEqual(UserDefaultsLanguageStore(defaults: defaults).load(), .system)
    }
}

/// The texts the interface actually renders, checked through the callers that
/// used to hard-code them.
final class LocalizedSurfaceTests: XCTestCase {
    override func tearDown() {
        L10n.use(.english, preferred: [])
        super.tearDown()
    }

    func testOverlayStatusFollowsTheCurrentLanguage() {
        XCTAssertEqual(OverlayStatus.text(unread: 2), "2 new")
        XCTAssertEqual(OverlayStatus.text(unread: 0), "All caught up")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(OverlayStatus.text(unread: 2), "2 条未读")
        XCTAssertEqual(OverlayStatus.text(unread: 0), "全部已读")
    }

    func testThemeNamesFollowTheCurrentLanguage() {
        XCTAssertEqual(OverlayTheme.midnight.displayName, "Midnight")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(OverlayTheme.midnight.displayName, "午夜")
        XCTAssertEqual(OverlayTheme.system.displayName, "跟随系统")
    }

    func testShortAgeFollowsTheCurrentLanguage() {
        let now = Date()
        XCTAssertEqual(ShortAge.text(since: now, now: now), "now")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(ShortAge.text(since: now, now: now), "刚刚")
        XCTAssertEqual(ShortAge.text(since: now.addingTimeInterval(-180), now: now), "3 分钟")
        XCTAssertEqual(ShortAge.text(since: now.addingTimeInterval(-7200), now: now), "2 小时")
        XCTAssertEqual(ShortAge.text(since: now.addingTimeInterval(-172800), now: now), "2 天")
    }

    func testScenarioTextFollowsTheCurrentLanguage() {
        let scenario = AgentScenario.claudeCodeTerminal
        XCTAssertEqual(scenario.title, "Terminal CLI")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(scenario.title, "终端 CLI")
        XCTAssertTrue(scenario.detection.contains("tmux"))
        XCTAssertTrue(scenario.jumpBack.contains("claude --resume"))
    }

    /// A scenario island does not know yet still has to render in the list.
    func testAnUnknownScenarioFallsBackToItsID() {
        let unknown = AgentScenario(id: "maker.unknown", agent: .pi)

        XCTAssertEqual(unknown.title, "maker.unknown")
        XCTAssertEqual(unknown.detection, "")
        XCTAssertEqual(unknown.jumpBack, "")
    }

    func testLoginItemHintsFollowTheCurrentLanguage() {
        XCTAssertTrue(
            LoginItemMenuPresentation.make(for: .requiresApproval).hint?.hasPrefix("allow") == true)

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(
            LoginItemMenuPresentation.make(for: .requiresApproval).hint,
            "在「系统设置 → 通用 → 登录项」中允许 island")
    }

    func testMovePromptFollowsTheCurrentLanguage() {
        let english = MoveToApplications.prompt(for: .diskImage)
        XCTAssertEqual(english?.message, "Move island to your Applications folder?")

        L10n.use(.simplifiedChinese, preferred: [])
        let chinese = MoveToApplications.prompt(for: .diskImage)
        XCTAssertEqual(chinese?.message, "要把 island 移到「应用程序」文件夹吗？")
        XCTAssertEqual(chinese?.informativeText.contains("开机自启"), true)
    }

    func testMoveButtonsFollowTheCurrentLanguage() {
        XCTAssertEqual(MoveToApplications.moveButton, "Move to Applications")
        XCTAssertEqual(MoveToApplications.laterButton, "Not Now")

        L10n.use(.simplifiedChinese, preferred: [])
        XCTAssertEqual(MoveToApplications.moveButton, "移到「应用程序」")
        XCTAssertEqual(MoveToApplications.laterButton, "以后再说")
    }
}
