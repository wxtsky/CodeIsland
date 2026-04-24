import XCTest
@testable import CodeIslandCore

final class CodexAppServerClientTests: XCTestCase {

    // MARK: - drainMessages

    func testDrainMessagesEmptyBuffer() {
        var buffer = Data()
        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesSingleCompleteLine() {
        var buffer = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1"}}}"#.utf8)
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.kind, .notification(method: "thread/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesTwoLinesConsumedBothLeavesBufferEmpty() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].kind, .notification(method: "thread/started"))
        XCTAssertEqual(messages[1].kind, .notification(method: "turn/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesKeepsTrailingPartialLineInBuffer() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/partial"#.utf8))

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(String(data: buffer, encoding: .utf8), #"{"jsonrpc":"2.0","method":"turn/partial"#)
    }

    func testDrainMessagesSkipsBlankLines() {
        var buffer = Data()
        buffer.append(0x0A)
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: - parseMessage kind detection

    func testParseMessageClassifiesRequest() {
        let data = Data(#"{"jsonrpc":"2.0","id":42,"method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .int(42)))
    }

    func testParseMessageClassifiesNotification() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .notification(method: "thread/started"))
    }

    func testParseMessageClassifiesResponse() {
        let data = Data(#"{"id":7,"result":{"ok":true}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .response(id: .int(7)))
    }

    func testParseMessageClassifiesError() {
        let data = Data(#"{"id":7,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .error(id: .int(7), code: -32601, message: "Method not found"))
    }

    func testParseMessageHandlesStringId() {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc-1","method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .string("abc-1")))
    }

    func testParseMessageRejectsInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertNil(CodexAppServerClient.parseMessage(data))
    }

    func testParseMessagePreservesRawParams() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1","preview":"hi"}}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        let params = msg?.raw["params"]?.asObject
        let thread = params?["thread"]?.asObject
        XCTAssertEqual(thread?["id"]?.asString, "t-1")
        XCTAssertEqual(thread?["preview"]?.asString, "hi")
    }

    // MARK: - AnyCodableLike

    func testAnyCodableLikeRoundTripsPrimitives() {
        XCTAssertEqual(AnyCodableLike.from(nil), .null)
        XCTAssertEqual(AnyCodableLike.from(NSNull()), .null)
        XCTAssertEqual(AnyCodableLike.from(true), .bool(true))
        XCTAssertEqual(AnyCodableLike.from(42), .int(42))
        XCTAssertEqual(AnyCodableLike.from("hi"), .string("hi"))

        // Floats end up as .double (bridged through NSNumber's float-check logic).
        if case .double(let value) = AnyCodableLike.from(3.14) {
            XCTAssertEqual(value, 3.14, accuracy: 0.0001)
        } else {
            XCTFail("expected .double for 3.14")
        }
    }

    func testAnyCodableLikeHandlesNestedObject() {
        let obj: [String: Any] = [
            "k1": "v1",
            "k2": 2,
            "k3": [1, 2, 3],
            "k4": ["inner": true]
        ]
        let wrapped = AnyCodableLike.from(obj)
        let dict = wrapped.asObject
        XCTAssertEqual(dict?["k1"]?.asString, "v1")
        XCTAssertEqual(dict?["k2"], .int(2))
        if case .array(let a) = dict?["k3"] ?? .null {
            XCTAssertEqual(a, [.int(1), .int(2), .int(3)])
        } else {
            XCTFail("expected array for k3")
        }
        XCTAssertEqual(dict?["k4"]?.asObject?["inner"]?.asBool, true)
    }
}
