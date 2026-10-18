import XCTest

@testable import IslandCore

final class LauncherTests: XCTestCase {
    private let target = LauncherTarget(
        id: "probe", name: "Probe",
        baseURL: URL(string: "https://example.com/chat")!,
        queryItem: "q")

    private let kimi = LauncherTarget(
        id: "kimi", name: "Kimi",
        baseURL: URL(string: "https://www.kimi.com/")!, queryItem: "q")

    /// The environment channel keeps the four fields it always had: no options.
    /// Ticking one is a Settings feature, so `ISLAND_LAUNCHER_TARGETS` can never
    /// turn auto-send on behind the user's back.
    private let deepSeekFromEnvironment = LauncherTarget(
        id: "deepseek", name: "DeepSeek",
        baseURL: URL(string: "https://chat.deepseek.com/")!, queryItem: "q")

    // MARK: - URLs

    func testABlankQuestionOpensTheSiteItself() {
        XCTAssertEqual(Launcher.url(for: target, query: ""), target.baseURL)
        XCTAssertEqual(Launcher.url(for: target, query: "  \n\t "), target.baseURL)
    }

    func testTheQuestionBecomesTheQueryParameter() {
        XCTAssertEqual(
            Launcher.url(for: target, query: "a b")?.absoluteString,
            "https://example.com/chat?q=a%20b")
        XCTAssertEqual(
            Launcher.url(for: target, query: "  hello  ")?.absoluteString,
            "https://example.com/chat?q=hello")
    }

    /// `&`, `=` and `#` inside a question must not break out of its parameter.
    func testReservedCharactersStayInsideTheValue() {
        XCTAssertEqual(
            Launcher.url(for: target, query: "a&b=c#d")?.absoluteString,
            "https://example.com/chat?q=a%26b%3Dc%23d")
        XCTAssertEqual(
            Launcher.url(for: target, query: "帮我看下#报错")?.absoluteString,
            "https://example.com/chat?q=%E5%B8%AE%E6%88%91%E7%9C%8B%E4%B8%8B%23%E6%8A%A5%E9%94%99")
        XCTAssertEqual(
            Launcher.url(for: target, query: "why?")?.absoluteString,
            "https://example.com/chat?q=why?")  // `?` is legal in a query, so it stays
    }

    func testTheBuiltInTargetIsDeepSeek() {
        XCTAssertEqual(Launcher.deepSeek.id, "deepseek")
        XCTAssertEqual(Launcher.deepSeek.name, "DeepSeek")
        XCTAssertEqual(Launcher.deepSeek.queryItem, "q")
        XCTAssertEqual(
            Launcher.url(for: Launcher.deepSeek, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi")
    }

    /// Kimi's `.cn` prefill link, measured by hand on 2026-10-19. `www.kimi.com`
    /// is a different bundle: it drops the parameters and redirects to the root,
    /// so the older host is the one worth building in.
    func testTheBuiltInKimiTargetUsesThePrefillLink() {
        XCTAssertEqual(Launcher.kimi.id, "kimi")
        XCTAssertEqual(Launcher.kimi.name, "Kimi")
        XCTAssertEqual(Launcher.kimi.queryItem, "prefill_prompt")
        XCTAssertEqual(
            Launcher.url(for: Launcher.kimi, query: "测试")?.absoluteString,
            "https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=%E6%B5%8B%E8%AF%95")
        XCTAssertEqual(Launcher.kimi.options.map(\.key), ["send_immediately"])
        XCTAssertEqual(Launcher.kimi.options[0].value, "true")
        XCTAssertEqual(
            Launcher.kimi.options[0].label, L10n.current.text(.launcherOptionAutoSend))
        XCTAssertFalse(Launcher.kimi.options[0].isEnabled)

        var send = Launcher.kimi
        send.options[0].isEnabled = true
        XCTAssertEqual(
            Launcher.url(for: send, query: "hi")?.absoluteString,
            "https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=hi&send_immediately=true")
    }

    /// A target from the four-field environment channel arrives ticked: it has no
    /// switch to carry, and `⇥` walking past it is what the variable always meant.
    func testEnvironmentTargetsArriveTicked() {
        let parsed = Launcher.parseTargets("kimi|Kimi|https://www.kimi.com/|q")
        XCTAssertEqual(parsed.targets.map(\.isEnabled), [true])
        XCTAssertEqual(parsed.targets.map(\.name), ["Kimi"])
    }

    /// A configured base URL reaches the browser as written, minus the fragment.
    func testTheBaseURLKeepsItsPortAndItsOwnQuery() {
        let selfHosted = LauncherTarget(
            id: "self", name: "Self",
            baseURL: URL(string: "http://127.0.0.1:8080/chat?model=x")!, queryItem: "q")
        XCTAssertEqual(
            Launcher.url(for: selfHosted, query: "hi")?.absoluteString,
            "http://127.0.0.1:8080/chat?model=x&q=hi")
        XCTAssertEqual(
            Launcher.url(for: selfHosted, query: "")?.absoluteString,
            "http://127.0.0.1:8080/chat?model=x")
    }

    // MARK: - Options

    /// The built-in ships `autosend` so the user can tick it, never ticked for
    /// them: a question must not leave island unasked (decision D9/D14).
    func testTheBuiltInTargetShipsAutosendUnticked() {
        XCTAssertEqual(Launcher.deepSeek.options.map(\.key), ["autosend"])
        XCTAssertEqual(Launcher.deepSeek.options.first?.value, "1")
        XCTAssertEqual(Launcher.deepSeek.options.first?.isEnabled, false)
        XCTAssertEqual(
            Launcher.url(for: Launcher.deepSeek, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi")
    }

    func testATickedOptionReachesTheURLAfterTheQuestion() {
        var deepSeek = Launcher.deepSeek
        deepSeek.options[0].isEnabled = true
        XCTAssertEqual(
            Launcher.url(for: deepSeek, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi&autosend=1")
    }

    func testTickedOptionsFollowTheOrderTheUserPutThemIn() {
        let kimiDeepLink = LauncherTarget(
            id: "kimi", name: "Kimi",
            baseURL: URL(string: "https://kimi.moonshot.cn/_prefill_chat")!,
            queryItem: "prefill_prompt",
            options: [
                LauncherOption(
                    key: "send_immediately", value: "true", label: "Auto", isEnabled: true),
                LauncherOption(
                    key: "force_search", value: "false", label: "Force", isEnabled: true),
            ])
        XCTAssertEqual(
            Launcher.url(for: kimiDeepLink, query: "hi")?.absoluteString,
            "https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=hi&send_immediately=true&force_search=false"
        )
    }

    func testAnUntickedOptionStaysOutOfTheURL() {
        var deepSeek = Launcher.deepSeek
        deepSeek.options[0].isEnabled = false
        XCTAssertEqual(
            Launcher.url(for: deepSeek, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi")
    }

    /// A blank question opens the site itself, so options have nothing to
    /// describe and stay out.
    func testABlankQuestionDoesNotCarryOptions() {
        var deepSeek = Launcher.deepSeek
        deepSeek.options[0].isEnabled = true
        XCTAssertEqual(
            Launcher.url(for: deepSeek, query: "   ")?.absoluteString,
            "https://chat.deepseek.com/")
    }

    // MARK: - Target list

    func testATargetListIsPipesBetweenFieldsAndSemicolonsBetweenTargets() {
        let parsed = Launcher.parseTargets(
            "  deepseek | DeepSeek | https://chat.deepseek.com/ | q ;other|Other|https://other.example.com|ask  "
        )
        XCTAssertEqual(
            parsed.targets,
            [
                deepSeekFromEnvironment,
                LauncherTarget(
                    id: "other", name: "Other",
                    baseURL: URL(string: "https://other.example.com")!, queryItem: "ask"),
            ])
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testEmptyPiecesAreNotTargetsAndNotMistakes() {
        let parsed = Launcher.parseTargets(" ;; deepseek|DeepSeek|https://chat.deepseek.com/|q ; ")
        XCTAssertEqual(parsed.targets, [deepSeekFromEnvironment])
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testAnEntryWithTheWrongShapeIsSkipped() {
        for entry in [
            "deepseek|DeepSeek|https://chat.deepseek.com/",
            "deepseek|DeepSeek|https://chat.deepseek.com/|q|extra",
            "|DeepSeek|https://chat.deepseek.com/|q",
            "deep seek|DeepSeek|https://chat.deepseek.com/|q",
            "deepseek||https://chat.deepseek.com/|q",
            "deepseek|DeepSeek|nonsense|q",
            "deepseek|DeepSeek|ftp://example.com/|q",
            "deepseek|DeepSeek|file:///etc/passwd|q",
            "deepseek|DeepSeek|https://chat.deepseek.com/|",
            "deepseek|DeepSeek|https://chat.deepseek.com/|a&b",
            "deepseek|DeepSeek|https://chat.deepseek.com/|a=b",
        ] {
            let parsed = Launcher.parseTargets(entry)
            XCTAssertEqual(parsed.targets, [], entry)
            XCTAssertEqual(parsed.skipped, 1, entry)
        }
    }

    func testTheFirstTargetWinsWhenTwoShareAnId() {
        let parsed = Launcher.parseTargets(
            "dup|First|https://first.example.com/|q;dup|Second|https://second.example.com/|q")
        XCTAssertEqual(parsed.targets.map(\.name), ["First"])
        XCTAssertEqual(parsed.skipped, 1)
    }

    // MARK: - The mode ring

    func testTheBuiltInRingIsTheTaskFilterAndBothMeasuredSites() {
        XCTAssertEqual(
            Launcher.builtIn,
            [.searchTasks, .target(Launcher.deepSeek), .target(Launcher.kimi)])
        XCTAssertEqual(
            Launcher.builtIn.map(\.name), [L10n.current.text(.searchTasks), "DeepSeek", "Kimi"])
        XCTAssertTrue(Launcher.builtIn[0].isSearchTasks)
        XCTAssertNil(Launcher.builtIn[0].target)
        XCTAssertTrue(Launcher.builtIn.allSatisfy(\.isEnabled))
    }

    /// `⇥` used to start composing; now it just moves to the next ticked stop, and
    /// a ring with nothing else ticked leaves the key alone.
    func testTabWalksTheRingAndWrapsAtBothEnds() {
        let ring: [LauncherMode] = [
            .searchTasks, .target(Launcher.kimi), .target(Launcher.deepSeek),
        ]
        XCTAssertEqual(Launcher.nextModeIndex(from: 0, in: ring), 1)
        XCTAssertEqual(Launcher.nextModeIndex(from: 1, in: ring), 2)
        XCTAssertEqual(Launcher.nextModeIndex(from: 2, in: ring), 0)
        XCTAssertEqual(
            Launcher.nextModeIndex(from: 1, in: [.searchTasks, .target(Launcher.kimi)]), 0)
        XCTAssertNil(Launcher.nextModeIndex(from: 0, in: [.searchTasks]))
        XCTAssertNil(Launcher.nextModeIndex(from: 0, in: []))
    }

    /// An unticked mode is skipped. An index that is no longer a stop — the user
    /// unticked the mode the overlay was showing — falls back to the top.
    func testTabSkipsUntickedModes() {
        var ring: [LauncherMode] = [
            .searchTasks, .target(Launcher.kimi), .target(Launcher.deepSeek),
        ]
        ring = Launcher.settingEnabled(false, at: 1, in: ring)
        XCTAssertEqual(Launcher.nextModeIndex(from: 0, in: ring), 2)
        XCTAssertEqual(Launcher.nextModeIndex(from: 2, in: ring), 0)
        XCTAssertEqual(Launcher.nextModeIndex(from: 1, in: ring), 0)
    }

    func testAnOutOfRangeIndexStartsOver() {
        let ring: [LauncherMode] = [
            .searchTasks, .target(Launcher.kimi), .target(Launcher.deepSeek),
        ]
        XCTAssertEqual(Launcher.nextModeIndex(from: 9, in: ring), 0)
        XCTAssertEqual(Launcher.nextModeIndex(from: -1, in: ring), 0)
    }

    func testSummonLandsOnTheFirstTickedMode() {
        let ring: [LauncherMode] = [
            .target(Launcher.kimi), .searchTasks, .target(Launcher.deepSeek),
        ]
        XCTAssertEqual(Launcher.summonIndex(in: ring), 0)
        let withoutKimi = Launcher.settingEnabled(false, at: 0, in: ring)
        XCTAssertEqual(withoutKimi[0].target?.isEnabled, false)
        XCTAssertEqual(Launcher.summonIndex(in: withoutKimi), 1)
        XCTAssertEqual(Launcher.summonIndex(in: []), 0)
    }

    /// The task filter has nothing to switch off — the task list and `esc` need it
    /// — so its box is refused. The view shows it ticked and disabled.
    func testTheTaskFilterCannotBeUnticked() {
        let ring: [LauncherMode] = [.searchTasks, .target(Launcher.kimi)]
        XCTAssertTrue(ring[0].isEnabled)
        XCTAssertEqual(Launcher.settingEnabled(false, at: 0, in: ring), ring)
        XCTAssertEqual(Launcher.settingEnabled(false, at: 9, in: ring), ring)
        let off = Launcher.settingEnabled(false, at: 1, in: ring)
        XCTAssertEqual(off[1].isEnabled, false)
        XCTAssertEqual(Launcher.settingEnabled(true, at: 1, in: off), ring)
    }

    /// The invariant that keeps summoning sane: a sanitized ring always holds a
    /// ticked mode, because the task filter cannot be unticked.
    func testASanitizedRingAlwaysHasATickedMode() {
        XCTAssertTrue(Launcher.sanitized([]).contains(where: \.isEnabled))
        XCTAssertTrue(Launcher.builtIn.contains(where: \.isEnabled))
    }

    /// `--print-config` and the log line say which modes `⇥` will skip.
    func testTheSummaryMarksUntickedModes() {
        let ring = Launcher.settingEnabled(
            false, at: 1, in: [.searchTasks, .target(Launcher.kimi), .target(Launcher.deepSeek)])
        let settings = LauncherSettings(modes: ring, source: .settings)
        XCTAssertEqual(
            settings.names, [L10n.current.text(.searchTasks), "Kimi (off)", "DeepSeek"])
    }

    /// Only the sites measured by hand have a note to show; about a mode the user
    /// added, island has nothing truthful to say.
    func testOnlyTheMeasuredSitesHaveADetailedNote() {
        XCTAssertEqual(
            Launcher.detail(for: Launcher.deepSeek), L10n.current.text(.launcherDetailDeepSeek))
        XCTAssertEqual(
            Launcher.detail(for: Launcher.kimi), L10n.current.text(.launcherDetailKimi))
        XCTAssertNil(Launcher.detail(for: target))
    }

    func testSanitizingPutsTheTaskFilterBackInFront() {
        XCTAssertEqual(
            Launcher.sanitized([.target(Launcher.deepSeek)]),
            [.searchTasks, .target(Launcher.deepSeek)])
        XCTAssertEqual(Launcher.sanitized([]), [.searchTasks])
    }

    /// A second task filter is dropped, but the ring's order is left alone: the
    /// user may well have made a site the default.
    func testSanitizingKeepsTheOrderAndDropsASecondFilter() {
        let modes: [LauncherMode] = [.target(Launcher.deepSeek), .searchTasks, .searchTasks]
        XCTAssertEqual(Launcher.sanitized(modes), [.target(Launcher.deepSeek), .searchTasks])
    }

    /// `NSTableView` reports the drop row before the moved row is taken out.
    func testMovingAModeUsesTheTableRowSemantics() {
        let modes: [LauncherMode] = [.searchTasks, .target(kimi), .target(Launcher.deepSeek)]
        XCTAssertEqual(
            Launcher.moving(modes, from: 2, to: 0),
            [.target(Launcher.deepSeek), .searchTasks, .target(kimi)])
        XCTAssertEqual(
            Launcher.moving(modes, from: 0, to: 3),
            [.target(kimi), .target(Launcher.deepSeek), .searchTasks])
        XCTAssertEqual(Launcher.moving(modes, from: 1, to: 1), modes)
        XCTAssertEqual(Launcher.moving(modes, from: 9, to: 0), modes)
        XCTAssertEqual(Launcher.moving(modes, from: 0, to: 9), modes)
    }

    func testTheTaskFilterCannotBeRemovedOrReplaced() {
        let modes: [LauncherMode] = [.searchTasks, .target(kimi)]
        XCTAssertEqual(Launcher.removing(modes, at: 0), modes)
        XCTAssertEqual(Launcher.replacing(modes, at: 0, with: .target(Launcher.deepSeek)), modes)
        XCTAssertEqual(Launcher.removing(modes, at: 5), modes)
        XCTAssertEqual(Launcher.removing(modes, at: 1), [.searchTasks])
        XCTAssertEqual(
            Launcher.replacing(modes, at: 1, with: .target(Launcher.deepSeek)),
            [.searchTasks, .target(Launcher.deepSeek)])
    }

    func testInsertingClampsToTheRing() {
        XCTAssertEqual(
            Launcher.inserting([.searchTasks], .target(kimi), at: 0),
            [.target(kimi), .searchTasks])
        XCTAssertEqual(
            Launcher.inserting([.searchTasks], .target(kimi), at: 9),
            [.searchTasks, .target(kimi)])
        XCTAssertEqual(
            Launcher.inserting([.searchTasks], .target(kimi), at: -3),
            [.target(kimi), .searchTasks])
    }

    // MARK: - IDs

    func testIDsComeFromTheNameAndStayUnique() {
        XCTAssertEqual(Launcher.uniqueID(from: "Kimi 聊天", taken: []), "kimi")
        XCTAssertEqual(Launcher.uniqueID(from: "My Site!", taken: []), "my-site")
        XCTAssertEqual(Launcher.uniqueID(from: "聊天", taken: []), "mode")
        XCTAssertEqual(Launcher.uniqueID(from: "  --  ", taken: []), "mode")
        XCTAssertEqual(Launcher.uniqueID(from: "Kimi", taken: ["kimi"]), "kimi-2")
        XCTAssertEqual(Launcher.uniqueID(from: "Kimi", taken: ["kimi", "kimi-2"]), "kimi-3")
    }

    // MARK: - Editing a target

    /// Opening the sheet on an existing mode is the only caller of this
    /// initialiser, and it must carry the ticked options over untouched.
    func testADraftStartsFromAnExistingTarget() {
        var deepSeek = Launcher.deepSeek
        deepSeek.options[0].isEnabled = true
        let draft = Launcher.Draft(deepSeek)
        XCTAssertEqual(draft.name, "DeepSeek")
        XCTAssertEqual(draft.baseURLText, "https://chat.deepseek.com/")
        XCTAssertEqual(draft.queryItem, "q")
        XCTAssertEqual(draft.options, deepSeek.options)
        XCTAssertEqual(
            Launcher.target(from: draft, keepingID: deepSeek.id, taken: [])?.options.first?
                .isEnabled,
            true)
    }

    /// The sheet edits the site, never the row's tick box: an edit that saved a
    /// mode back as ticked would undo the user's choice behind their back.
    func testEditingAnUntickedModeKeepsItUnticked() {
        var deepSeek = Launcher.deepSeek
        deepSeek.isEnabled = false
        let draft = Launcher.Draft(deepSeek)
        XCTAssertFalse(draft.isEnabled)
        XCTAssertEqual(
            Launcher.target(from: draft, keepingID: deepSeek.id, taken: []), deepSeek)
    }

    func testAValidDraftHasNoIssues() {
        let draft = Launcher.Draft(
            name: "Kimi", baseURLText: "https://www.kimi.com/", queryItem: "q",
            options: [LauncherOption(key: "send_immediately", value: "true", label: "Auto")])
        XCTAssertEqual(Launcher.issues(in: draft), [])
    }

    func testEveryBrokenFieldIsReportedAtOnce() {
        let draft = Launcher.Draft(
            name: " ", baseURLText: "nonsense", queryItem: "",
            options: [LauncherOption(key: "", value: "1", label: "A")])
        XCTAssertEqual(
            Launcher.issues(in: draft),
            [.emptyName, .unusableBaseURL, .unusableQueryItem, .optionKeyEmpty(index: 0)])
    }

    func testAnOptionKeyMustBeItsOwnAndUnique() {
        let draft = Launcher.Draft(
            name: "K", baseURLText: "https://k.example.com/", queryItem: "q",
            options: [
                LauncherOption(key: "q", value: "1", label: "Same as the question"),
                LauncherOption(key: "a=b", value: "1", label: "Breaks out"),
                LauncherOption(key: "a", value: "2", label: "Fine"),
                LauncherOption(key: "a", value: "3", label: "Twice"),
            ])
        XCTAssertEqual(
            Launcher.issues(in: draft),
            [
                .optionKeyUnusable(index: 0), .optionKeyUnusable(index: 1),
                .optionKeyDuplicated(index: 3),
            ]
        )
        XCTAssertEqual(
            Launcher.issues(in: draft).map(\.textKey),
            [
                .launcherIssueOptionKeyUnusable, .launcherIssueOptionKeyUnusable,
                .launcherIssueOptionKeyDuplicated,
            ])
    }

    func testAValidDraftBecomesATargetWithTrimmedFields() {
        let draft = Launcher.Draft(
            name: " Kimi ", baseURLText: " https://www.kimi.com/ ", queryItem: " q ",
            options: [LauncherOption(key: "send_immediately", value: "true", label: "Auto")])
        let built = Launcher.target(from: draft, keepingID: nil, taken: [])
        XCTAssertEqual(built?.id, "kimi")
        XCTAssertEqual(built?.name, "Kimi")
        XCTAssertEqual(built?.baseURL.absoluteString, "https://www.kimi.com/")
        XCTAssertEqual(built?.queryItem, "q")
        XCTAssertEqual(built?.options.count, 1)
    }

    func testABrokenDraftBecomesNoTarget() {
        XCTAssertNil(
            Launcher.target(
                from: Launcher.Draft(name: "K", baseURLText: "x", queryItem: "q"),
                keepingID: nil, taken: []))
    }

    func testEditingKeepsTheOriginalID() {
        let draft = Launcher.Draft(
            name: "Renamed", baseURLText: "https://x.example.com/", queryItem: "q")
        XCTAssertEqual(
            Launcher.target(from: draft, keepingID: "kimi", taken: ["kimi"])?.id, "kimi")
    }

    func testANewTargetAvoidsTheIDsAlreadyInUse() {
        let draft = Launcher.Draft(
            name: "Kimi", baseURLText: "https://x.example.com/", queryItem: "q")
        XCTAssertEqual(
            Launcher.target(from: draft, keepingID: nil, taken: ["kimi"])?.id, "kimi-2")
    }

    /// A base pasted out of the browser's address bar often still carries its own
    /// `?q=`; ours has to replace it, not sit next to it.
    func testOurParameterReplacesTheOneTheBaseURLCarried() {
        let deepSeekWithBaseQuery = LauncherTarget(
            id: "probe", name: "Probe",
            baseURL: URL(string: "https://chat.deepseek.com/?q=")!,
            queryItem: "q")
        XCTAssertEqual(
            Launcher.url(for: deepSeekWithBaseQuery, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi")
        let clashing = LauncherTarget(
            id: "probe", name: "Probe",
            baseURL: URL(string: "https://example.com/chat?model=x&keep=1")!,
            queryItem: "q",
            options: [LauncherOption(key: "model", value: "y", label: "Model", isEnabled: true)])
        XCTAssertEqual(
            Launcher.url(for: clashing, query: "hi")?.absoluteString,
            "https://example.com/chat?keep=1&q=hi&model=y")
    }

    /// The sheet judges trimmed text, so the stored option must be trimmed too —
    /// otherwise `  autosend  ` reaches the site as `%20autosend%20=1`.
    func testPaddedOptionFieldsAreTrimmedOnTheWayIn() {
        let draft = Launcher.Draft(
            name: "K", baseURLText: "https://k.example.com/", queryItem: " q ",
            options: [
                LauncherOption(
                    key: "  autosend  ", value: " 1 ", label: " Auto ", isEnabled: true)
            ])
        let built = Launcher.target(from: draft, keepingID: nil, taken: [])
        XCTAssertEqual(built?.queryItem, "q")
        XCTAssertEqual(built?.options.first?.key, "autosend")
        XCTAssertEqual(built?.options.first?.value, "1")
        XCTAssertEqual(built?.options.first?.label, " Auto ")
        XCTAssertEqual(
            Launcher.url(for: built!, query: "hi")?.absoluteString,
            "https://k.example.com/?q=hi&autosend=1")
    }

    func testSanitizingKeepsOneModePerTargetID() {
        var first = kimi
        first.name = "First"
        var second = kimi
        second.name = "Second"
        XCTAssertEqual(
            Launcher.sanitized([.searchTasks, .target(first), .target(second), .target(first)]),
            [.searchTasks, .target(first)])
    }

    func testASecondTaskFilterCannotBeInserted() {
        let modes: [LauncherMode] = [.searchTasks, .target(kimi)]
        XCTAssertEqual(Launcher.inserting(modes, .searchTasks, at: 0), modes)
        XCTAssertEqual(
            Launcher.inserting(modes, .target(Launcher.deepSeek), at: 0),
            [.target(Launcher.deepSeek), .searchTasks, .target(kimi)])
    }

    // MARK: - Settings

    func testTheLauncherIsOnByDefault() {
        let settings = LauncherSettings.resolve(environment: [:])
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.modes, Launcher.builtIn)
        XCTAssertEqual(settings.targets, [Launcher.deepSeek, Launcher.kimi])
        XCTAssertEqual(settings.source, .builtIn)
        XCTAssertFalse(settings.ignoredInvalidEntries)
    }

    func testSwitchingItOffLeavesNoTarget() {
        for value in ["off", "0", "false", "no", " NO "] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertFalse(settings.isEnabled, value)
            XCTAssertEqual(settings.modes, [], value)
            XCTAssertEqual(settings.targets, [], value)
            XCTAssertEqual(settings.source, .off, value)
        }
    }

    func testTheSwitchBeatsAConfiguredTargetList() {
        let settings = LauncherSettings.resolve(environment: [
            LauncherSettings.environmentKey: "off",
            Launcher.targetsEnvironmentKey: "kimi|Kimi|https://www.kimi.com/|q",
        ])
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.targets, [])
        XCTAssertEqual(settings.source, .off)
    }

    /// `ISLAND_LAUNCHER=off` is the loudest switch there is, so it outranks a
    /// ring the user saved in Settings too.
    func testTheSwitchBeatsASavedRing() {
        let settings = LauncherSettings.resolve(
            environment: [LauncherSettings.environmentKey: "off"],
            stored: [.searchTasks, .target(kimi)])
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.source, .off)
    }

    func testAnyOtherSwitchValueKeepsTheLauncherOn() {
        for value in ["on", "yes", "1", "deepseek"] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertEqual(settings.modes, Launcher.builtIn, value)
            XCTAssertEqual(settings.source, .builtIn, value)
        }
    }

    func testAConfiguredListReplacesTheBuiltIn() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey:
                "kimi|Kimi|https://www.kimi.com/|q; deepseek|DeepSeek|https://chat.deepseek.com/|q"
        ])
        XCTAssertEqual(settings.targets.map(\.id), ["kimi", "deepseek"])
        XCTAssertEqual(settings.modes.first, .searchTasks)
        XCTAssertEqual(settings.source, .environment)
        XCTAssertFalse(settings.ignoredInvalidEntries)
    }

    func testUnusableEntriesAreSkippedAndReported() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey: "junk;kimi|Kimi|https://www.kimi.com/|q"
        ])
        XCTAssertEqual(settings.targets.map(\.id), ["kimi"])
        XCTAssertTrue(settings.ignoredInvalidEntries)
        XCTAssertEqual(settings.source, .environment)
    }

    func testAListWithNothingUsableFallsBackToTheBuiltIn() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey: "junk;;more junk"
        ])
        XCTAssertEqual(settings.modes, Launcher.builtIn)
        XCTAssertTrue(settings.ignoredInvalidEntries)
        XCTAssertEqual(settings.source, .builtIn)
    }

    func testAnEmptyListValueIsTheSameAsUnset() {
        for value in ["", "   ", ";"] {
            let settings = LauncherSettings.resolve(environment: [
                Launcher.targetsEnvironmentKey: value
            ])
            XCTAssertEqual(settings.modes, Launcher.builtIn, value)
            XCTAssertFalse(settings.ignoredInvalidEntries, value)
        }
    }

    // MARK: - Settings beat the environment

    func testASavedRingBeatsTheEnvironmentList() {
        let saved: [LauncherMode] = [
            .searchTasks,
            .target(
                LauncherTarget(
                    id: "saved", name: "Saved",
                    baseURL: URL(string: "https://saved.example.com/")!, queryItem: "q")),
        ]
        let settings = LauncherSettings.resolve(
            environment: [Launcher.targetsEnvironmentKey: "kimi|Kimi|https://www.kimi.com/|q"],
            stored: saved)
        XCTAssertEqual(settings.source, .settings)
        XCTAssertEqual(settings.names, [L10n.current.text(.searchTasks), "Saved"])
    }

    func testASavedRingIsSanitizedOnTheWayIn() {
        let settings = LauncherSettings.resolve(
            environment: [:], stored: [.target(kimi), .target(Launcher.deepSeek)])
        XCTAssertEqual(settings.modes.first, .searchTasks)
        XCTAssertEqual(settings.targets.map(\.id), ["kimi", "deepseek"])
    }

    /// An empty saved ring means "nothing was ever saved", not "switched off" —
    /// switching off goes through `ISLAND_LAUNCHER=off`.
    func testAnEmptySavedRingReadsAsUnset() {
        XCTAssertEqual(
            LauncherSettings.resolve(environment: [:], stored: []).modes, Launcher.builtIn)
        XCTAssertEqual(
            LauncherSettings.resolve(environment: [:], stored: nil).modes,
            Launcher.builtIn)
    }
}
