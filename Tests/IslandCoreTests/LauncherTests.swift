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

    func testTheLauncherIsOnByDefault() {
        let settings = LauncherSettings.resolve(environment: [:])
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.target, Launcher.deepSeek)
    }

    func testSwitchingItOffLeavesNoTarget() {
        for value in ["off", "0", "false", "no", " NO "] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertFalse(settings.isEnabled, value)
            XCTAssertNil(settings.target, value)
        }
    }

    func testAnyOtherValueKeepsTheLauncherOn() {
        for value in ["on", "yes", "1", "deepseek"] {
            let settings = LauncherSettings.resolve(
                environment: [LauncherSettings.environmentKey: value])
            XCTAssertEqual(settings.target, Launcher.deepSeek, value)
        }
    }
}
