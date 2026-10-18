import XCTest

@testable import IslandCore

final class IPCProtocolTests: XCTestCase {
    private func parse(_ text: String) -> Result<IPCRequest, IPCParseError> {
        IPCParser.parse(Data(text.utf8))
    }

    func testParsesAHello() {
        XCTAssertEqual(
            parse(
                #"{"v":1,"id":"h","method":"hello","params":{"client":" cli ","protocol":1,"pid":42}}"#
            ),
            .success(
                IPCRequest(
                    id: "h",
                    method: .hello(client: "cli", protocolVersion: 1, pid: 42))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"hello","params":{"client":"cli","protocol":1}}"#),
            .success(
                IPCRequest(
                    id: nil, method: .hello(client: "cli", protocolVersion: 1, pid: nil))))
    }

    func testRejectsABadHello() {
        XCTAssertEqual(
            parse(#"{"v":1,"method":"hello"}"#),
            .failure(.badParams("hello needs params.client")))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"hello","params":{"protocol":1}}"#),
            .failure(.badParams("hello needs params.client")))
        for client in ["", "   "] {
            XCTAssertEqual(
                parse(
                    #"{"v":1,"method":"hello","params":{"client":"\#(client)","protocol":1}}"#),
                .failure(.badParams("params.client must be 1-64 characters")))
        }
        XCTAssertEqual(
            parse(#"{"v":1,"method":"hello","params":{"client":"cli"}}"#),
            .failure(.badParams("hello needs params.protocol")))
        let longClient = String(repeating: "c", count: 65)
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"hello","params":{"client":"\#(longClient)","protocol":1}}"#),
            .failure(.badParams("params.client must be 1-64 characters")))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"hello","params":{"client":"cli","protocol":2}}"#),
            .failure(.badVersion(2)))
    }

    func testParsesANotify() {
        XCTAssertEqual(
            parse(
                #"{"v":1,"id":"n","method":"notify","params":{"kind":"notice","title":"  done  ","client_event_id":" e1 "}}"#
            ),
            .success(
                IPCRequest(
                    id: "n",
                    method: .notify(kind: "notice", title: "done", clientEventID: "e1"))))
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"notify","params":{"kind":"task.finished","client_event_id":"e2"}}"#
            ),
            .success(
                IPCRequest(
                    id: nil,
                    method: .notify(kind: "task.finished", title: nil, clientEventID: "e2"))))
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"notify","params":{"kind":"notice","title":"   ","client_event_id":"e3"}}"#
            ),
            .success(
                IPCRequest(
                    id: nil, method: .notify(kind: "notice", title: nil, clientEventID: "e3"))))
    }

    func testRejectsABadNotify() {
        XCTAssertEqual(
            parse(#"{"v":1,"method":"notify","params":{"client_event_id":"e"}}"#),
            .failure(.badParams("params.kind must be one of [\"notice\", \"task.finished\"]")))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"notify","params":{"kind":"chat","client_event_id":"e"}}"#),
            .failure(.badParams("params.kind must be one of [\"notice\", \"task.finished\"]")))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"notify","params":{"kind":"notice"}}"#),
            .failure(.badParams("notify needs params.client_event_id")))
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"notify","params":{"kind":"notice","client_event_id":"   "}}"#),
            .failure(.badParams("notify needs params.client_event_id")))
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"notify","params":{"kind":"notice","title":5,"client_event_id":"e"}}"#
            ),
            .failure(.badParams("params.title must be a string")))
        let longTitle = String(repeating: "t", count: 201)
        XCTAssertEqual(
            parse(
                #"{"v":1,"method":"notify","params":{"kind":"notice","title":"\#(longTitle)","client_event_id":"e"}}"#
            ),
            .failure(.badParams("params.title is longer than 200")))
    }

    func testParsesEveryQuery() {
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"status"}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .status, limit: nil))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"unread"}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .unread, limit: nil))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"tasks","limit":3}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .tasks, limit: 3))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"capabilities"}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .capabilities, limit: nil))))
    }

    func testQueryLimitIsClampedToAtLeastOne() {
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"tasks","limit":0}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .tasks, limit: 1))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"tasks","limit":-4}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .tasks, limit: 1))))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"tasks","limit":"x"}}"#),
            .success(IPCRequest(id: nil, method: .query(what: .tasks, limit: nil))))
    }

    func testRejectsABadQuery() {
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query","params":{"what":"everything"}}"#),
            .failure(
                .badParams("params.what must be status, unread, tasks, or capabilities")))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"query"}"#),
            .failure(
                .badParams("params.what must be status, unread, tasks, or capabilities")))
    }

    func testRejectsMalformedFrames() {
        XCTAssertEqual(parse("not json"), .failure(.malformed("frame is not a JSON object")))
        XCTAssertEqual(parse("[]"), .failure(.malformed("frame is not a JSON object")))
        XCTAssertEqual(parse(#"{"method":"hello"}"#), .failure(.malformed("missing v")))
        XCTAssertEqual(parse(#"{"v":"1","method":"hello"}"#), .failure(.malformed("missing v")))
        XCTAssertEqual(parse(#"{"v":true,"method":"hello"}"#), .failure(.malformed("missing v")))
        XCTAssertEqual(parse(#"{"v":1.5,"method":"hello"}"#), .failure(.malformed("missing v")))
        XCTAssertEqual(parse(#"{"v":1}"#), .failure(.malformed("missing method")))
        XCTAssertEqual(parse(#"{"v":1,"method":""}"#), .failure(.malformed("missing method")))
        XCTAssertEqual(
            parse(#"{"v":2,"method":"hello"}"#), .failure(.badVersion(2)))
        XCTAssertEqual(
            parse(#"{"v":1,"method":"dance"}"#), .failure(.unknownMethod("dance")))
    }

    func testRejectsAFrameOverTheLimit() {
        let oversized = Data(repeating: 0x20, count: IPCProtocol.maxFrameBytes + 1)

        XCTAssertEqual(IPCParser.parse(oversized), .failure(.tooLarge))
        XCTAssertEqual(
            IPCParser.parse(Data(repeating: 0x20, count: IPCProtocol.maxFrameBytes)),
            .failure(.malformed("frame is not a JSON object")))
    }

    func testParseErrorsDescribeThemselves() {
        let cases: [(IPCParseError, IPCErrorCode, String, Bool)] = [
            (.malformed("bad"), .badParams, "bad", false),
            (.tooLarge, .tooLarge, "frame exceeds 65536 bytes", true),
            (.badVersion(9), .badVersion, "unsupported protocol version 9", true),
            (.unknownMethod("x"), .unknownMethod, "unknown method x", false),
            (.badParams("p"), .badParams, "p", false),
        ]
        for (error, code, detail, closes) in cases {
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.detail, detail)
            XCTAssertEqual(error.closesConnection, closes)
            XCTAssertEqual(IPCErrorCode(rawValue: code.rawValue), code)
        }
    }

    func testEncodesSuccessfulAndFailedFrames() throws {
        let success = IPCFrame.success(id: "1", result: ["ok": true])
        XCTAssertEqual(success.last, 0x0A)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: success.dropLast()) as? [String: Any])
        XCTAssertEqual(decoded["v"] as? Int, 1)
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        XCTAssertEqual(decoded["id"] as? String, "1")
        XCTAssertEqual((decoded["result"] as? [String: Any])?["ok"] as? Bool, true)

        let anonymous = IPCFrame.success(id: nil, result: [:])
        let anonymousJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: anonymous.dropLast()) as? [String: Any])
        XCTAssertNil(anonymousJSON["id"])

        let failure = IPCFrame.failure(id: "2", code: .badParams, detail: "why")
        let failureJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: failure.dropLast()) as? [String: Any])
        XCTAssertEqual(failureJSON["ok"] as? Bool, false)
        XCTAssertEqual(failureJSON["id"] as? String, "2")
        let error = failureJSON["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "bad_params")
        XCTAssertEqual(error?["detail"] as? String, "why")

        let noID = IPCFrame.failure(id: nil, code: .internalError, detail: "boom")
        let noIDJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: noID.dropLast()) as? [String: Any])
        XCTAssertNil(noIDJSON["id"])

        XCTAssertEqual(
            IPCFrame.success(id: "x", result: ["a": 1]),
            IPCFrame.success(
                id: "x", result: ["a": 1]))
    }

    func testAnUnserializableResultStillProducesAFrame() throws {
        let reply = IPCFrame.success(id: "1", result: ["when": Date()])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reply.dropLast()) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, false)
        let error = decoded["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "internal")
        XCTAssertEqual(error?["detail"] as? String, "frame encoding failed")
    }
}
