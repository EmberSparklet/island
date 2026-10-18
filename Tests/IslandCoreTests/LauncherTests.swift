import XCTest

@testable import IslandCore

final class LauncherTests: XCTestCase {
    private let target = LauncherTarget(
        id: "probe", name: "Probe",
        baseURL: URL(string: "https://example.com/chat")!,
        queryItem: "q")

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
        XCTAssertEqual(Launcher.builtIn, [Launcher.deepSeek])
        XCTAssertEqual(Launcher.deepSeek.id, "deepseek")
        XCTAssertEqual(Launcher.deepSeek.name, "DeepSeek")
        XCTAssertEqual(Launcher.deepSeek.queryItem, "q")
        XCTAssertEqual(
            Launcher.url(for: Launcher.deepSeek, query: "hi")?.absoluteString,
            "https://chat.deepseek.com/?q=hi")
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

    // MARK: - Target list

    func testATargetListIsPipesBetweenFieldsAndSemicolonsBetweenTargets() {
        let parsed = Launcher.parseTargets(
            "  deepseek | DeepSeek | https://chat.deepseek.com/ | q ;other|Other|https://other.example.com|ask  "
        )
        XCTAssertEqual(
            parsed.targets,
            [
                Launcher.deepSeek,
                LauncherTarget(
                    id: "other", name: "Other",
                    baseURL: URL(string: "https://other.example.com")!, queryItem: "ask"),
            ])
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testEmptyPiecesAreNotTargetsAndNotMistakes() {
        let parsed = Launcher.parseTargets(" ;; deepseek|DeepSeek|https://chat.deepseek.com/|q ; ")
        XCTAssertEqual(parsed.targets, [Launcher.deepSeek])
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

    // MARK: - Settings

    func testTheLauncherIsOnByDefault() {
        let settings = LauncherSettings.resolve(environment: [:])
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.targets, Launcher.builtIn)
        XCTAssertFalse(settings.ignoredInvalidEntries)
    }

    func testSwitchingItOffLeavesNoTarget() {
        for value in ["off", "0", "false", "no", " NO "] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertFalse(settings.isEnabled, value)
            XCTAssertEqual(settings.targets, [], value)
        }
    }

    func testTheSwitchBeatsAConfiguredTargetList() {
        let settings = LauncherSettings.resolve(environment: [
            LauncherSettings.environmentKey: "off",
            Launcher.targetsEnvironmentKey: "kimi|Kimi|https://www.kimi.com/|q",
        ])
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.targets, [])
    }

    func testAnyOtherSwitchValueKeepsTheLauncherOn() {
        for value in ["on", "yes", "1", "deepseek"] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertEqual(settings.targets, Launcher.builtIn, value)
        }
    }

    func testAConfiguredListReplacesTheBuiltIn() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey:
                "kimi|Kimi|https://www.kimi.com/|q; deepseek|DeepSeek|https://chat.deepseek.com/|q"
        ])
        XCTAssertEqual(settings.targets.map(\.id), ["kimi", "deepseek"])
        XCTAssertFalse(settings.ignoredInvalidEntries)
    }

    func testUnusableEntriesAreSkippedAndReported() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey: "junk;kimi|Kimi|https://www.kimi.com/|q"
        ])
        XCTAssertEqual(settings.targets.map(\.id), ["kimi"])
        XCTAssertTrue(settings.ignoredInvalidEntries)
    }

    func testAListWithNothingUsableFallsBackToTheBuiltIn() {
        let settings = LauncherSettings.resolve(environment: [
            Launcher.targetsEnvironmentKey: "junk;;more junk"
        ])
        XCTAssertEqual(settings.targets, Launcher.builtIn)
        XCTAssertTrue(settings.ignoredInvalidEntries)
    }

    func testAnEmptyListValueIsTheSameAsUnset() {
        for value in ["", "   ", ";"] {
            let settings = LauncherSettings.resolve(environment: [
                Launcher.targetsEnvironmentKey: value
            ])
            XCTAssertEqual(settings.targets, Launcher.builtIn, value)
            XCTAssertFalse(settings.ignoredInvalidEntries, value)
        }
    }

    // MARK: - Compose keys

    func testTabStartsComposing() {
        XCTAssertEqual(
            Launcher.composeTabAction(composing: false, targetIndex: 0, targetCount: 3), .begin)
        XCTAssertEqual(
            Launcher.composeTabAction(composing: false, targetIndex: 0, targetCount: 1), .begin)
    }

    func testTabWalksTheTargetsAndWrapsAtBothEnds() {
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 0, targetCount: 3),
            .moveToTarget(1))
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 1, targetCount: 3),
            .moveToTarget(2))
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 2, targetCount: 3),
            .moveToTarget(0))
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 1, targetCount: 2),
            .moveToTarget(0))
    }

    /// With nothing to switch to, `⇥` leaves compose instead of doing nothing —
    /// the meaning it had before the target list became configurable.
    func testTabEndsComposeWhenThereIsOnlyOneTarget() {
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 0, targetCount: 1), .end)
    }

    func testTabIsIgnoredWhenTheLauncherIsOff() {
        for composing in [true, false] {
            XCTAssertEqual(
                Launcher.composeTabAction(composing: composing, targetIndex: 0, targetCount: 0),
                .ignored, "\(composing)")
        }
    }

    func testAnOutOfRangeIndexStartsOver() {
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: 9, targetCount: 3),
            .moveToTarget(0))
        XCTAssertEqual(
            Launcher.composeTabAction(composing: true, targetIndex: -1, targetCount: 3),
            .moveToTarget(0))
    }
}
