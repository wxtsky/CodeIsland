import XCTest
@testable import CodeIslandCore

final class CatPawHookPayloadTests: XCTestCase {
    func testPreviewPreservesUnicodeAndIsIdempotent() {
        XCTAssertNil(CatPawHookPayload.preview(nil))
        for text in ["", "short", "0123456789", "你好👨‍👩‍👧‍👦测试"] {
            XCTAssertEqual(CatPawHookPayload.preview(text), text)
        }
        let text = String(repeating: "你好👨‍👩‍👧‍👦这是一个中文测试和后续文字", count: 3)
        let expected = String(text.prefix(30)) + "…"
        XCTAssertEqual(CatPawHookPayload.preview(text), expected)
        XCTAssertEqual(CatPawHookPayload.preview(expected), expected)
    }

    func testMainPayloadOnlyIncludesShortPreviewsAndMetadata() throws {
        let secret = String(repeating: "private-tail", count: 100_000)
        for source in ["catpaw", "catpaw-idekit"] {
            for name in ["beforeSubmitPrompt", "afterAgentResponse", "beforeShellExecution"] {
                let raw = payload(name, ["prompt": String(repeating: "0", count: 30) + secret,
                    "text": String(repeating: "a", count: 30) + secret, "command": String(repeating: "9", count: 30) + secret,
                    "output": secret, "result_json": secret, "tool_input": ["key": secret],
                    "attachments": [["file_path": secret]], "future_content": secret])
                let normalized = try XCTUnwrap(CatPawHookPayload.normalized(raw, source: source))
                let data = try JSONSerialization.data(withJSONObject: normalized)
                XCTAssertLessThan(data.count, 1000)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-tail"))
                XCTAssertEqual(normalized["suggest_uuid"] as? String, "request-1")
                if name == "beforeSubmitPrompt" { XCTAssertEqual(normalized["prompt"] as? String, String(repeating: "0", count: 30) + "…") }
                if name == "afterAgentResponse" { XCTAssertEqual(normalized["text"] as? String, String(repeating: "a", count: 30) + "…") }
                if name == "beforeShellExecution" {
                    XCTAssertEqual((normalized["tool_input"] as? [String: String])?["command"], String(repeating: "9", count: 30) + "…")
                }
            }
        }
    }

    private func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = [
            "hook_event_name": event, "conversation_id": "chat-1",
            "suggest_uuid": "request-1", "is_sub_agent": false,
            "workspace_roots": ["/project"], "model": "model-1",
        ]
        raw.merge(extra) { _, new in new }
        return raw
    }

    func testIDEKitAndIDEKeepIdenticalConversationIDsSeparate() throws {
        let raw = payload("beforeSubmitPrompt", ["prompt": "hello"])
        let ide = try XCTUnwrap(CatPawHookPayload.normalized(raw, source: "catpaw"))
        let plugin = try XCTUnwrap(CatPawHookPayload.normalized(raw, source: "catpaw-idekit"))
        XCTAssertEqual(plugin["session_id"] as? String, "catpaw-idekit:chat-1")
        XCTAssertNotEqual(ide["session_id"] as? String, plugin["session_id"] as? String)
        XCTAssertEqual(plugin["_source"] as? String, "catpaw-idekit")
        XCTAssertTrue(SessionSnapshot.ideHostSources.contains("catpaw-idekit"))
        XCTAssertNil(CatPawHookPayload.normalized(raw, source: "unrelated"))
    }

    func testIDEKitHostRequiresBothMainExecutableAndBundleIdentity() {
        let executable = "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"
        XCTAssertTrue(CatPawHookPayload.isIDEKitHost(executablePath: executable, bundleIdentifier: "com.jetbrains.intellij"))
        XCTAssertTrue(CatPawHookPayload.isIDEKitHost(executablePath: executable, bundleIdentifier: "com.jetbrains.intellij.ce"))
        XCTAssertFalse(CatPawHookPayload.isIDEKitHost(executablePath: executable, bundleIdentifier: "com.jetbrains.pycharm"))
        XCTAssertFalse(CatPawHookPayload.isIDEKitHost(executablePath: "/usr/bin/java", bundleIdentifier: "com.jetbrains.intellij"))
        XCTAssertFalse(CatPawHookPayload.isIDEKitHost(executablePath: executable, bundleIdentifier: nil))
        XCTAssertFalse(CatPawHookPayload.isIDEKitHost(executablePath: "/bin/sh", bundleIdentifier: nil))
    }

    func testStableConversationAndToolArguments() throws {
        let first = try XCTUnwrap(CatPawHookPayload.normalized(payload("beforeShellExecution", ["command": "ls"])))
        let second = try XCTUnwrap(CatPawHookPayload.normalized(payload("afterShellExecution", ["suggest_uuid": "request-2"])))
        XCTAssertEqual(first["session_id"] as? String, "catpaw:chat-1")
        XCTAssertEqual(first["session_id"] as? String, second["session_id"] as? String)
        XCTAssertEqual(first["tool_name"] as? String, "Bash")
        XCTAssertEqual((first["tool_input"] as? [String: String])?["command"], "ls")
        XCTAssertNil(first["tool_use_id"])
        XCTAssertEqual(first["cwd"] as? String, "/project")
    }

    func testMCPParametersAreNeverForwarded() throws {
        let good = try XCTUnwrap(CatPawHookPayload.normalized(payload("beforeMCPExecution", ["tool_input": #"{"path":"file"}"#])))
        XCTAssertNil(good["tool_input"])
        let bad = try XCTUnwrap(CatPawHookPayload.normalized(payload("beforeMCPExecution", ["tool_input": "bad json"])))
        XCTAssertNil(bad["tool_input"])
    }

    func testUnsupportedEventsNeverReachReducer() {
        for event in ["afterAgentThought", "beforeReadFile", "afterFileEdit", "unknown"] {
            XCTAssertNil(CatPawHookPayload.normalized(payload(event)), event)
        }
        XCTAssertNil(CatPawHookPayload.normalized(["hook_event_name": "beforeSubmitPrompt"]))
    }

    func testChildConversationsStaySeparateEvenWithIdenticalNamesAndRequests() throws {
        var sessions: [String: SessionSnapshot] = [:]
        func send(_ event: String, id: String, child: Bool, extra: [String: Any] = [:]) throws -> [SideEffect] {
            var raw = payload(event, ["conversation_id": id, "is_sub_agent": child, "agent_name": "Agent"])
            raw.merge(extra) { _, new in new }
            guard let normalized = CatPawHookPayload.normalized(raw, source: "catpaw-idekit") else { return [] }
            let hook = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: normalized)))
            XCTAssertNil(hook.agentId, "No invented parent/child folding id")
            return reduceEvent(sessions: &sessions, event: hook, maxHistory: 20)
        }
        _ = try send("beforeSubmitPrompt", id: "parent", child: false, extra: ["prompt": "parent task"])
        for id in ["child-a", "child-b"] {
            let effects = try send("beforeSubmitPrompt", id: id, child: true, extra: ["prompt": id])
            XCTAssertFalse(effects.contains { if case .playSound = $0 { return true }; return false })
            XCTAssertEqual(sessions["catpaw-idekit:\(id)"]?.catpawSubagentLabel, "Subagent · Agent")
        }
        _ = try send("beforeShellExecution", id: "child-a", child: true, extra: ["command": "ls"])
        XCTAssertEqual(sessions["catpaw-idekit:child-a"]?.status, .running)
        XCTAssertEqual(sessions["catpaw-idekit:child-b"]?.status, .processing)
        XCTAssertEqual(sessions["catpaw-idekit:parent"]?.status, .processing)
        _ = try send("afterShellExecution", id: "child-a", child: true)
        for text in ["working", "still working", "public report"] {
            let effects = try send("afterAgentResponse", id: "child-a", child: true, extra: ["text": text])
            XCTAssertFalse(effects.contains { if case .enqueueCompletion = $0 { return true }; return false })
        }
        _ = try send("stop", id: "parent", child: false, extra: ["status": "completed"])
        _ = try send("stop", id: "child-a", child: true, extra: ["status": "completed"])
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions["catpaw-idekit:parent"]?.lastUserPrompt, "parent task")
        XCTAssertNil(sessions["catpaw-idekit:parent"]?.lastAssistantMessage)
        XCTAssertTrue(sessions["catpaw-idekit:parent"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["catpaw-idekit:parent"]?.status, .processing)
        XCTAssertEqual(sessions["catpaw-idekit:child-a"]?.status, .processing)
        XCTAssertNil(sessions["catpaw-idekit:child-a"]?.lastAssistantMessage)
        XCTAssertTrue(PushEventClassifier.isSubagentCompletion(agentId: nil, raw: [:], sessionId: "catpaw-idekit:child-a", session: sessions["catpaw-idekit:child-a"]))
        XCTAssertFalse(PushEventClassifier.isSubagentCompletion(agentId: nil, raw: [:], sessionId: "catpaw-idekit:parent", session: sessions["catpaw-idekit:parent"]))
    }

    func testResponsePreservesStateAndNeverCompletesTurn() throws {
        var session = SessionSnapshot()
        session.source = "catpaw"
        session.status = .idle
        var sessions = ["catpaw:chat-1": session]
        let normalized = try XCTUnwrap(CatPawHookPayload.normalized(payload("afterAgentResponse", ["text": "public reply"])))
        let data = try JSONSerialization.data(withJSONObject: normalized)
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
        XCTAssertEqual(sessions["catpaw:chat-1"]?.lastAssistantMessage, "public reply")
        XCTAssertEqual(sessions["catpaw:chat-1"]?.status, .idle)
        XCTAssertFalse(effects.contains {
            if case .enqueueCompletion = $0 { return true }
            return false
        })
    }

    func testIDEIdentityDoesNotCaptureOtherAgentsInItsTerminal() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("catpaw"), "catpaw")
        XCTAssertTrue(SessionSnapshot.ideHostSources.contains("catpaw"))
        XCTAssertNil(CLIProcessResolver.inferSource(ancestry: [(100, "/Applications/CatPaw IDE.app/Contents/MacOS/Electron")]))
        var session = SessionSnapshot()
        session.source = "catpaw"
        session.termBundleId = "com.meituan.catpaw"
        XCTAssertEqual(session.sourceLabel, "CatPaw IDE")
        XCTAssertTrue(session.isNativeAppMode)
        session.source = "claude"
        XCTAssertFalse(session.isNativeAppMode)
        XCTAssertTrue(session.isIDETerminal)
    }
}
