import XCTest

@testable import IslandCore

final class ExternalInboxTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)

    func testAddsNewestFirstAndCountsUnread() {
        let inbox = ExternalInbox()
        let first = inbox.add(client: "cli", title: "first", eventID: "1", at: base)
        let second = inbox.add(client: "cli", title: "second", eventID: "2", at: base + 5)

        XCTAssertEqual(first?.id, "cli\u{1F}1")
        XCTAssertEqual(second?.title, "second")
        XCTAssertEqual(inbox.unreadCount, 2)
        XCTAssertEqual(inbox.allEntries.map(\.title), ["second", "first"])
        XCTAssertEqual(inbox.allEntries.map(\.client), ["cli", "cli"])
        XCTAssertEqual(inbox.allEntries.first?.isRead, false)
        XCTAssertEqual(inbox.allEntries.first?.receivedAt, base + 5)
    }

    func testTheSameClientEventIsDeduplicated() {
        let inbox = ExternalInbox()

        XCTAssertNotNil(inbox.add(client: "cli", title: "one", eventID: "e", at: base))
        XCTAssertNil(inbox.add(client: "cli", title: "one again", eventID: "e", at: base + 1))
        XCTAssertEqual(inbox.allEntries.count, 1)
        XCTAssertEqual(inbox.allEntries.first?.title, "one")
    }

    func testTheSameEventIDFromAnotherClientIsANewRow() {
        let inbox = ExternalInbox()

        inbox.add(client: "a", title: "a", eventID: "same", at: base)
        inbox.add(client: "b", title: "b", eventID: "same", at: base)

        XCTAssertEqual(inbox.allEntries.count, 2)
    }

    func testMarkReadOnlyTouchesAKnownRow() {
        let inbox = ExternalInbox()
        inbox.add(client: "cli", title: "one", eventID: "1", at: base)
        let id = inbox.allEntries[0].id

        inbox.markRead(id: "nothing")
        XCTAssertEqual(inbox.unreadCount, 1)

        inbox.markRead(id: id)
        XCTAssertEqual(inbox.unreadCount, 0)
        XCTAssertEqual(inbox.allEntries[0].isRead, true)

        inbox.markRead(id: id)
        XCTAssertEqual(inbox.unreadCount, 0)
    }

    func testClearDropsEveryRowButKeepsTheDedupWindow() {
        let inbox = ExternalInbox()
        for index in 1...3 {
            inbox.add(client: "cli", title: "\(index)", eventID: "\(index)", at: base)
        }
        inbox.markRead(id: inbox.allEntries[0].id)

        inbox.clear()

        XCTAssertEqual(inbox.allEntries.count, 0)
        XCTAssertEqual(inbox.unreadCount, 0)
        XCTAssertNil(inbox.add(client: "cli", title: "1 again", eventID: "1", at: base))
        XCTAssertNotNil(inbox.add(client: "cli", title: "4", eventID: "4", at: base))
        XCTAssertEqual(inbox.allEntries.map(\.title), ["4"])
    }

    func testTheCapacityBoundsMemory() {
        let inbox = ExternalInbox(capacity: 5)
        for index in 1...5 {
            inbox.add(
                client: "cli", title: "\(index)", eventID: "\(index)", at: base + Double(index))
        }

        XCTAssertEqual(inbox.allEntries.count, 5)
        XCTAssertEqual(inbox.allEntries.map(\.title), ["5", "4", "3", "2", "1"])
    }

    func testTheDeduplicationWindowForgetsOldEvents() {
        let inbox = ExternalInbox(dedupCapacity: 2)
        inbox.add(client: "cli", title: "1", eventID: "1", at: base)
        inbox.add(client: "cli", title: "2", eventID: "2", at: base)
        inbox.add(client: "cli", title: "3", eventID: "3", at: base)

        XCTAssertNotNil(
            inbox.add(client: "cli", title: "1 again", eventID: "1", at: base + 1))
        XCTAssertEqual(inbox.allEntries.count, 4)
    }

    func testTrimDropsTheOldestReadRowsButKeepsUnreadOnes() {
        let inbox = ExternalInbox(capacity: 2)
        for index in 1...3 {
            inbox.add(client: "cli", title: "\(index)", eventID: "\(index)", at: base)
        }
        XCTAssertEqual(inbox.allEntries.count, 3)

        for entry in inbox.allEntries.prefix(2) { inbox.markRead(id: entry.id) }
        XCTAssertEqual(inbox.allEntries.count, 3)

        inbox.add(client: "cli", title: "4", eventID: "4", at: base)
        XCTAssertEqual(inbox.allEntries.count, 2)
        XCTAssertEqual(inbox.allEntries.map(\.isRead), [false, false])
    }

    func testTheCapacitiesAreClampedToAtLeastOne() {
        let inbox = ExternalInbox(capacity: 0, dedupCapacity: 0)
        inbox.add(client: "cli", title: "one", eventID: "e", at: base)
        XCTAssertEqual(inbox.allEntries.count, 1)
        XCTAssertNil(inbox.add(client: "cli", title: "one", eventID: "e", at: base))
    }
}

final class IPCSettingsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/probe")

    func testDefaultsToTheSupportDirectory() {
        let settings = IPCSettings.resolve(environment: [:], home: home)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(
            settings.socketURL?.path,
            "/Users/probe/Library/Application Support/island/ipc/island.sock")
    }

    func testOffSwitchesTheChannelOff() {
        for value in ["off", " OFF ", "0", "false", "no"] {
            let settings = IPCSettings.resolve(environment: ["ISLAND_IPC": value], home: home)
            XCTAssertFalse(settings.isEnabled)
            XCTAssertNil(settings.socketURL)
        }
    }

    func testAnyOtherValueKeepsItOn() {
        for value in ["on", "open", "token", "1", ""] {
            let settings = IPCSettings.resolve(environment: ["ISLAND_IPC": value], home: home)
            XCTAssertTrue(settings.isEnabled)
        }
    }

    func testThePathOverrideWins() {
        let settings = IPCSettings.resolve(
            environment: ["ISLAND_IPC_PATH": " /tmp/island-probe.sock "], home: home)

        XCTAssertEqual(settings.socketURL?.path, "/tmp/island-probe.sock")
    }

    func testAnEmptyPathOverrideFallsBackToTheDefault() {
        let settings = IPCSettings.resolve(environment: ["ISLAND_IPC_PATH": "   "], home: home)

        XCTAssertEqual(
            settings.socketURL?.path,
            "/Users/probe/Library/Application Support/island/ipc/island.sock")
    }

    func testThePathOverrideExpandsATilde() {
        let settings = IPCSettings.resolve(
            environment: ["ISLAND_IPC_PATH": "~/island.sock"], home: home)

        XCTAssertEqual(settings.socketURL?.path.hasPrefix("~"), false)
        XCTAssertTrue(settings.socketURL?.path.hasSuffix("/island.sock") == true)
    }
}
