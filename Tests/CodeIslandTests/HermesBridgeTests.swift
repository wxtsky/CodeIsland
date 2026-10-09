import XCTest
@testable import CodeIsland

/// The real bridge binary on a Hermes hook (#364), against a stand-in socket —
/// never the user's live one. Hermes attaches the whole conversation to every
/// pre/post_llm_call; the bridge drops it (from the event and its log) and
/// passes on where the firing profile keeps its store.
final class HermesBridgeTests: XCTestCase {
    func testBridgeDropsTheConversationAndNamesTheHermesHome() throws {
        let bridge = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let log = NSTemporaryDirectory() + "codeisland-bridge-hermes-\(UUID().uuidString).log"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: log) }
        let history = "SECRET-EARLIER-TURN-\(UUID().uuidString)"

        let process = Process()
        process.executableURL = bridge
        process.arguments = ["--source", "hermes"]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": server.path,
            "CODEISLAND_BRIDGE_LOG": log,
            "HERMES_HOME": "/Users/dev/.hermes/profiles/work",
        ]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let payload: [String: Any] = [
            "hook_event_name": "post_llm_call",
            "tool_name": NSNull(),
            "tool_input": NSNull(),
            "session_id": "20261009_101151_eafbd0",
            "cwd": "/Users/dev/project",
            "profile": "work",
            "extra": [
                "user_message": "Fix the login bug",
                "assistant_response": "Fixed.",
                "conversation_history": [["role": "user", "content": history]],
                "model": "hermes-4",
            ] as [String: Any],
        ]
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        let forwarded = try XCTUnwrap(JSONSerialization.jsonObject(with: server.received) as? [String: Any])
        let extra = try XCTUnwrap(forwarded["extra"] as? [String: Any])
        XCTAssertNil(extra["conversation_history"])
        XCTAssertEqual(extra["assistant_response"] as? String, "Fixed.")
        XCTAssertEqual(extra["user_message"] as? String, "Fix the login bug")
        XCTAssertEqual(forwarded["_hermes_home"] as? String, "/Users/dev/.hermes/profiles/work")
        XCTAssertEqual(forwarded["_source"] as? String, "hermes")
        let logged = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(logged.contains(history), "the conversation must not land in the bridge log either")
    }
}
