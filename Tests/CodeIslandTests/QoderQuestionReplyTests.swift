import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class QoderQuestionReplyTests: XCTestCase {
    func testQoderIDEReceivesTheSelectedOptionsInItsHookFormat() throws {
        let output = try runQuestion(source: "qoder", bundle: "com.qoder.ide") { state in
            state.answerQuestionMulti([("Which mode?", "Fast, Safe"), ("Project name?", "Demo")])
        }
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertNil(output["decision"])
        try assertInputContainsAnswers(output)
    }

    func testNewQoderAndQoderCLIRetainTheirHookFormat() throws {
        for (source, bundle) in [("qoder", "com.qoder.app"), ("qoder-cli", "com.qoder.ide")] {
            let output = try runQuestion(source: source, bundle: bundle) { state in
                state.answerQuestionMulti([("Which mode?", "Fast, Safe"), ("Project name?", "Demo")])
            }
            XCTAssertNil(output["permissionDecision"], bundle)
            let decision = try XCTUnwrap(output["decision"] as? [String: Any])
            XCTAssertEqual(decision["behavior"] as? String, "allow", bundle)
            try assertInputContainsAnswers(decision)
        }
    }

    func testSkippingQoderIDEQuestionDeniesWithoutRewritingInput() throws {
        let output = try runQuestion(source: "qoder", bundle: "com.qoder.ide") { $0.skipQuestion() }
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertNil(output["decision"])
        XCTAssertNil(output["updatedInput"])
    }

    func testQoderIDELeavesNoDecisionAndNotificationRepliesAlone() throws {
        let facts = HookIntake.Facts(sourceTag: "qoder", environment: ["__CFBundleIdentifier": "com.qoder.ide"])
        var permission = try XCTUnwrap(HookIntake(stdin: [
            "hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash",
        ], facts: facts))
        permission.addTerminalContext()
        let noDecision = Data("{}".utf8)
        XCTAssertEqual(permission.stdout(forAnswer: noDecision), noDecision)
        let denied = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied"}}}"#.utf8)
        let reply = try XCTUnwrap(permission.stdout(forAnswer: denied))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let hookOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hookOutput["permissionDecisionReason"] as? String, "Denied")

        var notification = try XCTUnwrap(HookIntake(stdin: [
            "hook_event_name": "Notification", "session_id": "s", "question": "Which mode?",
        ], facts: facts))
        notification.addTerminalContext()
        let notificationReply = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification","answer":"Fast"}}"#.utf8)
        XCTAssertEqual(notification.stdout(forAnswer: notificationReply), notificationReply)
    }

    private func assertInputContainsAnswers(_ output: [String: Any]) throws {
        let input = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["Which mode?": "Fast, Safe", "Project name?": "Demo"])
        let questions = try XCTUnwrap(input["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.compactMap { $0["question"] as? String }, ["Which mode?", "Project name?"])
        XCTAssertNil(input["answer"])
    }

    private func runQuestion(
        source: String,
        bundle: String,
        respond: (AppState) -> Void
    ) throws -> [String: Any] {
        let state = AppState()
        let socket = "/tmp/ci-qr-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(appState: state, socketPath: socket)
        let log = socket + ".log"
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: log)
        }
        _ = try XCTUnwrap(server.start() ? server : nil, "Could not bind the test hook socket")

        let bridge = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        let process = Process()
        process.executableURL = bridge
        process.arguments = ["--source", source]
        process.environment = [
            "CODEISLAND_SOCKET_PATH": socket, "CODEISLAND_BRIDGE_LOG": log, "__CFBundleIdentifier": bundle,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let body = #"""
        {"hook_event_name":"PermissionRequest","session_id":"question-reply-test","tool_use_id":"call-1",
         "cwd":"/tmp/codeisland-test","tool_name":"AskUserQuestion","tool_input":{"questions":[
           {"question":"Which mode?","header":"Mode","multiSelect":true,"options":[{"label":"Fast"},{"label":"Safe"}]},
           {"question":"Project name?","header":"Name","options":[{"label":"Example"}]}
         ]}}
        """#
        try input.fileHandleForWriting.write(contentsOf: Data(body.utf8))
        try input.fileHandleForWriting.close()
        let promptDeadline = Date().addingTimeInterval(5)
        while state.questionQueue.isEmpty, process.isRunning, Date() < promptDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let request = try XCTUnwrap(state.questionQueue.first)
        XCTAssertEqual(request.askUserQuestionState?.items.first?.payload.options, ["Fast", "Safe"])
        XCTAssertTrue(process.isRunning, "the hook must still be waiting when the question card opens")
        respond(state)
        let responseDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < responseDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(state.questionQueue.isEmpty, "the question has been resolved")
        XCTAssertFalse(process.isRunning, "the bridge must return the selected answer")
        guard !process.isRunning else { return [:] }
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let hookOutput = try XCTUnwrap(result["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PermissionRequest")
        return hookOutput
    }
}
