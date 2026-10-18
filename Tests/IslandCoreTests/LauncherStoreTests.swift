import XCTest

@testable import IslandCore

final class LauncherStoreTests: XCTestCase {
    private let suiteName = "island.launcher.store.tests"
    private var defaults: UserDefaults!
    private var store: UserDefaultsLauncherStore!

    private let kimi = LauncherTarget(
        id: "kimi", name: "Kimi",
        baseURL: URL(string: "https://www.kimi.com/")!, queryItem: "q")

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsLauncherStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testNothingSavedReadsAsNil() {
        XCTAssertNil(store.load())
    }

    func testTheRingSurvivesARoundTrip() {
        let modes: [LauncherMode] = [.searchTasks, .target(kimi), .target(Launcher.deepSeek)]
        store.save(modes)
        XCTAssertEqual(store.load(), modes)
    }

    func testOptionsSurviveARoundTrip() {
        var deepSeek = Launcher.deepSeek
        deepSeek.options = [
            LauncherOption(key: "autosend", value: "1", label: "自动发送", isEnabled: true),
            LauncherOption(key: "thinking", value: "1", label: "Thinking", isEnabled: false),
        ]
        store.save([.target(deepSeek)])
        XCTAssertEqual(store.load(), [.searchTasks, .target(deepSeek)])
    }

    /// The enable box arrived after the ring did. A saved ring has no such field,
    /// and it must read as ticked — an upgrade may not silently reset what the
    /// user configured.
    ///
    /// Built with `JSONSerialization` rather than by string-editing what the
    /// encoder just wrote: `JSONEncoder` emits keys in hash order, not declaration
    /// order, so a `replacingOccurrences` on its output is a coin flip.
    func testATargetSavedWithoutTheToggleReadsAsTicked() throws {
        let target: [String: Any] = [
            "id": "kimi", "name": "Kimi", "baseURL": "https://www.kimi.com/",
            "queryItem": "q", "options": [Any](),
        ]
        let ring: [[String: Any]] = [
            ["kind": "target", "target": target], ["kind": "searchTasks"],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: ring),
            forKey: UserDefaultsLauncherStore.key)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.map(\.name), ["Kimi", L10n.current.text(.searchTasks)])
        XCTAssertEqual(loaded.map(\.isEnabled), [true, true])
        XCTAssertFalse(store.hasUnreadableValue)
    }

    func testAnUntickedModeSurvivesARoundTrip() {
        let ring = Launcher.settingEnabled(
            false, at: 1, in: [.searchTasks, .target(kimi), .target(Launcher.deepSeek)])
        store.save(ring)
        XCTAssertEqual(store.load(), ring)
        XCTAssertEqual(store.load()?.map(\.isEnabled), [true, false, true])
    }

    func testTheToggleIsReadableInTheStoredJSON() throws {
        store.save(Launcher.settingEnabled(false, at: 1, in: [.searchTasks, .target(kimi)]))
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsLauncherStore.key))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"isEnabled\":false"), text)
    }

    /// The ring is stored as JSON, so its shape can be read back in a bug report.
    func testTheRingIsStoredAsReadableJSON() throws {
        store.save([.searchTasks, .target(kimi)])
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsLauncherStore.key))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"kind\":\"searchTasks\""), text)
        XCTAssertTrue(text.contains("\"kind\":\"target\""), text)
        XCTAssertTrue(text.contains("\"name\":\"Kimi\""), text)
    }

    /// Unreadable data must not brick the launcher: it reads as "never saved",
    /// so the built-in ring is used and the next save overwrites the junk.
    /// "Your saved ring is broken" must be distinguishable from "never saved":
    /// the CLI and the log say so instead of quietly using the built-in ring.
    func testUnreadableDataIsReported() {
        XCTAssertFalse(store.hasUnreadableValue)
        defaults.set(Data("not json at all".utf8), forKey: UserDefaultsLauncherStore.key)
        XCTAssertTrue(store.hasUnreadableValue)
        XCTAssertNil(store.load())
    }

    func testAValueOfTheWrongTypeIsReportedToo() {
        defaults.set("not even data", forKey: UserDefaultsLauncherStore.key)
        XCTAssertTrue(store.hasUnreadableValue)
    }

    func testAReadableRingIsNotReported() {
        store.save([.searchTasks, .target(kimi)])
        XCTAssertFalse(store.hasUnreadableValue)
    }

    func testGarbageReadsAsNil() {
        defaults.set(Data("not json at all".utf8), forKey: UserDefaultsLauncherStore.key)
        XCTAssertNil(store.load())
    }

    func testJSONOfTheWrongShapeReadsAsNil() {
        defaults.set(Data(#"{"modes":[]}"#.utf8), forKey: UserDefaultsLauncherStore.key)
        XCTAssertNil(store.load())
    }

    func testAnUnknownModeKindReadsAsNil() {
        defaults.set(Data(#"[{"kind":"nope"}]"#.utf8), forKey: UserDefaultsLauncherStore.key)
        XCTAssertNil(store.load())
    }

    func testATargetWithoutItsPayloadReadsAsNil() {
        defaults.set(Data(#"[{"kind":"target"}]"#.utf8), forKey: UserDefaultsLauncherStore.key)
        XCTAssertNil(store.load())
    }

    func testSavingPutsTheTaskFilterBackInFront() {
        store.save([.target(kimi)])
        XCTAssertEqual(store.load(), [.searchTasks, .target(kimi)])
    }

    func testAModeEncodesAndDecodesOnItsOwn() throws {
        for mode in [LauncherMode.searchTasks, .target(kimi)] {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(LauncherMode.self, from: data), mode)
        }
    }
}
