import XCTest

@testable import IslandCore

final class IPCSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let snapshot = IPCSnapshot(
        appVersion: "1.2.3",
        unreadTasks: 2,
        tasks: [
            .init(
                id: "t1", agent: "codex", title: "fix", cwd: "/tmp/island",
                completedAt: Date(timeIntervalSince1970: 0), host: "terminal:1"),
            .init(
                id: "t2", agent: "pi", title: "refactor", cwd: nil,
                completedAt: Date(timeIntervalSince1970: 60), host: "unknown"),
        ])

    private func hello(id: String? = "h", client: String = "cli") -> IPCRequest {
        IPCRequest(id: id, method: .hello(client: client, protocolVersion: 1, pid: nil))
    }

    private func notify(
        id: String? = "n", kind: String = "notice", title: String? = "done",
        eventID: String = "e1"
    ) -> IPCRequest {
        IPCRequest(id: id, method: .notify(kind: kind, title: title, clientEventID: eventID))
    }

    private func query(_ what: IPCQuery, limit: Int? = nil, id: String? = "q") -> IPCRequest {
        IPCRequest(id: id, method: .query(what: what, limit: limit))
    }

    private func frame(_ reply: IPCSession.Reply) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: reply.data.dropLast())) as! [String: Any]
    }

    private func result(_ reply: IPCSession.Reply) -> [String: Any] {
        frame(reply)["result"] as! [String: Any]
    }

    private func errorCode(_ reply: IPCSession.Reply) -> String? {
        ((frame(reply)["error"] as? [String: Any])?["code"] as? String)
    }

    func testHelloAnswersWithTheServerDescription() {
        var session = IPCSession(sessionID: "session-1")
        let reply = session.handle(hello(), inbox: ExternalInbox(), snapshot: snapshot)

        XCTAssertFalse(reply.close)
        let payload = frame(reply)
        XCTAssertEqual(payload["v"] as? Int, 1)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["id"] as? String, "h")
        let hello = result(reply)
        XCTAssertEqual(hello["server"] as? String, "island")
        XCTAssertEqual(hello["version"] as? String, "1.2.3")
        XCTAssertEqual(hello["protocol"] as? Int, 1)
        XCTAssertEqual(hello["methods"] as? [String], ["hello", "notify", "query"])
        XCTAssertEqual(hello["events"] as? [String], [])
        XCTAssertEqual(hello["session"] as? String, "session-1")
        let limits = hello["limits"] as? [String: Any]
        XCTAssertEqual(limits?["max_frame_bytes"] as? Int, 65_536)
        XCTAssertEqual(limits?["max_subscriptions"] as? Int, 0)
        XCTAssertEqual(limits?["idle_timeout_seconds"] as? Int, 0)
        XCTAssertEqual(session.state, .ready(client: "cli"))
    }

    func testHelloWithoutAnIDStillGetsAReply() {
        var session = IPCSession()
        let reply = session.handle(hello(id: nil), inbox: ExternalInbox(), snapshot: snapshot)

        XCTAssertNil(frame(reply)["id"])
        XCTAssertFalse(session.sessionID.isEmpty)
    }

    func testMethodsBeforeHelloAreUnauthorized() {
        var session = IPCSession()
        let inbox = ExternalInbox()

        let beforeNotify = session.handle(notify(), inbox: inbox, snapshot: snapshot)
        XCTAssertEqual(errorCode(beforeNotify), "unauthorized")
        XCTAssertEqual(frame(beforeNotify)["id"] as? String, "n")
        XCTAssertEqual(inbox.allEntries.count, 0)

        let beforeQuery = session.handle(query(.status), inbox: inbox, snapshot: snapshot)
        XCTAssertEqual(errorCode(beforeQuery), "unauthorized")
        XCTAssertNil(beforeQuery.notification)
        XCTAssertEqual(session.state, .awaitingHello)

        _ = session.handle(hello(), inbox: inbox, snapshot: snapshot)
        let after = session.handle(query(.status), inbox: inbox, snapshot: snapshot)
        XCTAssertEqual(frame(after)["ok"] as? Bool, true)
    }

    func testNotifyStoresARowAndReportsDuplicates() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        _ = session.handle(hello(client: "probe"), inbox: inbox, snapshot: snapshot)

        let first = session.handle(
            notify(id: "n1", title: "Build done", eventID: "e1"), inbox: inbox,
            snapshot: snapshot, now: now)
        XCTAssertEqual(result(first)["accepted"] as? Bool, true)
        XCTAssertEqual(result(first)["duplicate"] as? Bool, false)
        XCTAssertEqual(first.notification?.title, "Build done")
        XCTAssertEqual(frame(first)["id"] as? String, "n1")
        XCTAssertEqual(inbox.allEntries.map(\.title), ["Build done"])
        XCTAssertEqual(inbox.allEntries.map(\.client), ["probe"])
        XCTAssertEqual(inbox.allEntries.map(\.receivedAt), [now])

        let second = session.handle(
            notify(id: "n2", title: "Build done", eventID: "e1"), inbox: inbox,
            snapshot: snapshot)
        XCTAssertEqual(result(second)["duplicate"] as? Bool, true)
        XCTAssertNil(second.notification)
        XCTAssertEqual(inbox.allEntries.count, 1)
    }

    func testNotifyFallsBackToTheKindAsTitle() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        _ = session.handle(hello(), inbox: inbox, snapshot: snapshot)

        _ = session.handle(
            notify(kind: "task.finished", title: nil, eventID: "e"), inbox: inbox,
            snapshot: snapshot)

        XCTAssertEqual(inbox.allEntries.first?.title, "task.finished")
    }

    func testASecondHelloRenamesTheClient() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        _ = session.handle(hello(client: "one"), inbox: inbox, snapshot: snapshot)
        _ = session.handle(hello(client: "two"), inbox: inbox, snapshot: snapshot)

        _ = session.handle(notify(eventID: "e"), inbox: inbox, snapshot: snapshot)

        XCTAssertEqual(inbox.allEntries.first?.client, "two")
    }

    func testStatusReportsBothCounters() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        inbox.add(client: "cli", title: "x", eventID: "e", at: now)
        _ = session.handle(hello(), inbox: inbox, snapshot: snapshot)

        let reply = session.handle(query(.status), inbox: inbox, snapshot: snapshot)

        let payload = result(reply)
        XCTAssertEqual(payload["query"] as? String, "status")
        XCTAssertEqual(payload["server"] as? String, "island")
        XCTAssertEqual(payload["version"] as? String, "1.2.3")
        XCTAssertEqual(payload["protocol"] as? Int, 1)
        XCTAssertEqual(payload["methods"] as? [String], IPCProtocol.methods)
        XCTAssertEqual(payload["events"] as? [String], [])
        let unread = payload["unread"] as? [String: Any]
        XCTAssertEqual(unread?["tasks"] as? Int, 2)
        XCTAssertEqual(unread?["notifications"] as? Int, 1)
        XCTAssertNotNil(payload["limits"])
    }

    func testUnreadAndCapabilities() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        _ = session.handle(hello(), inbox: inbox, snapshot: snapshot)

        let unread = result(session.handle(query(.unread), inbox: inbox, snapshot: snapshot))
        XCTAssertEqual(unread["query"] as? String, "unread")
        XCTAssertEqual(unread["tasks"] as? Int, 2)
        XCTAssertEqual(unread["notifications"] as? Int, 0)

        let capabilities = result(
            session.handle(query(.capabilities), inbox: inbox, snapshot: snapshot))
        XCTAssertEqual(capabilities["query"] as? String, "capabilities")
        XCTAssertEqual(capabilities["methods"] as? [String], IPCProtocol.methods)
        XCTAssertEqual(capabilities["events"] as? [String], [])
        XCTAssertNotNil(capabilities["limits"])
    }

    func testTasksListsRowsAndHonoursTheLimit() {
        var session = IPCSession()
        let inbox = ExternalInbox()
        _ = session.handle(hello(), inbox: inbox, snapshot: snapshot)

        let all = result(session.handle(query(.tasks), inbox: inbox, snapshot: snapshot))
        XCTAssertEqual(all["query"] as? String, "tasks")
        XCTAssertEqual(all["truncated"] as? Bool, false)
        let rows = all["items"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0]["id"] as? String, "t1")
        XCTAssertEqual(rows?[0]["agent"] as? String, "codex")
        XCTAssertEqual(rows?[0]["title"] as? String, "fix")
        XCTAssertEqual(rows?[0]["cwd"] as? String, "/tmp/island")
        XCTAssertEqual(rows?[0]["host"] as? String, "terminal:1")
        XCTAssertEqual(
            rows?[0]["completed_at"] as? String,
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0)))
        XCTAssertNil(rows?[1]["cwd"])

        let limited = result(
            session.handle(query(.tasks, limit: 1), inbox: inbox, snapshot: snapshot))
        XCTAssertEqual((limited["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(limited["truncated"] as? Bool, true)
    }

    func testTasksOnAnEmptySnapshot() {
        var session = IPCSession()
        _ = session.handle(hello(), inbox: ExternalInbox(), snapshot: .empty)
        let reply = session.handle(
            query(.tasks), inbox: ExternalInbox(), snapshot: .empty)

        let payload = result(reply)
        XCTAssertEqual((payload["items"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertEqual(IPCSnapshot.empty.appVersion, "0.0.0")
    }

    func testRejectedFramesCarryTheErrorAndClosePolicy() {
        let cases: [(IPCParseError, String, Bool)] = [
            (.malformed("why"), "bad_params", false),
            (.tooLarge, "too_large", true),
            (.badVersion(3), "bad_version", true),
            (.unknownMethod("x"), "unknown_method", false),
            (.badParams("p"), "bad_params", false),
        ]
        for (error, code, closes) in cases {
            let reply = IPCSession.reject(error)
            XCTAssertEqual(reply.close, closes)
            XCTAssertEqual(errorCode(reply), code)
            XCTAssertNil(frame(reply)["id"])
        }
    }

    func testTheSnapshotStoreHandsOutTheLatestValue() {
        let store = IPCSnapshotStore()
        XCTAssertEqual(store.read(), .empty)

        store.update(snapshot)
        XCTAssertEqual(store.read(), snapshot)
    }
}
