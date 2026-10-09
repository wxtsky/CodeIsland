import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CodexAutoReviewRoutingTests: XCTestCase {
    private var savedCodexHome: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CODEX_HOME", root.path, 1)
        try writeConfig(reviewer: "user")
    }

    override func tearDownWithError() throws {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        try FileManager.default.removeItem(at: root)
    }

    func testDesktopAutoReviewDefersWithoutAnEventOrConfigReviewer() throws {
        // Desktop chooses the reviewer per turn; config.toml has no such key.
        try "model = \"example\"\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        for reviewer in ["auto_review", "guardian_subagent"] {
            let event = try makeEvent(contexts: [context("current", reviewer)])
            XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event), reviewer)
        }
    }

    func testHumanTurnOverridesAutoReviewConfig() throws {
        try writeConfig(reviewer: "auto_review")
        let event = try makeEvent(contexts: [context("current", "user")])
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testAutoReviewTurnOverridesHumanConfig() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testExplicitHookReviewerTakesPrecedenceOverTranscript() throws {
        let human = try makeEvent(contexts: [context("current", "auto_review")], fields: ["approvals_reviewer": "user"])
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(human))
        let automatic = try makeEvent(contexts: [context("current", "user")], fields: ["approvalsReviewer": "auto_review"])
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(automatic))
    }

    func testDifferentTurnsCannotLendTheirReviewerToTheRequest() throws {
        let event = try makeEvent(contexts: [context("previous", "auto_review"), context("later", "auto_review")])
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON))
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testLatestMatchingTurnContextWins() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review"), context("current", "user")])
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testMissingReviewerInLatestContextDoesNotReuseOlderContext() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review"), context("current", nil)])
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON))
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testMissingTurnIdRetainsConfigFallback() throws {
        var raw = try makeEvent(contexts: [context("current", "auto_review")]).rawJSON
        raw.removeValue(forKey: "turn_id")
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(raw))
        try writeConfig(reviewer: "auto_review")
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testMissingTranscriptRetainsConfigFallback() throws {
        let event = try makeEvent(contexts: [])
        try FileManager.default.removeItem(atPath: event.rawJSON["transcript_path"] as! String)
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON))
        try writeConfig(reviewer: "auto_review")
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testMalformedAndIncompleteLinesDoNotHideAValidContext() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        let url = URL(fileURLWithPath: event.rawJSON["transcript_path"] as! String)
        let contents = try String(contentsOf: url, encoding: .utf8)
        try ("not json\n" + contents + "{\"type\":\"turn_context\",\"payload\":")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testBoundedTailDropsTruncatedUtf8LineAndFindsCurrentContext() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        let url = URL(fileURLWithPath: event.rawJSON["transcript_path"] as! String)
        let contents = try String(contentsOf: url, encoding: .utf8)
        try (String(repeating: "界", count: 1000) + "\n" + contents)
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexPermissionRules.transcriptReviewerValue(event.rawJSON, maxBytes: 256), "auto_review")
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON, maxBytes: 8))
    }

    func testOnlyTheNewestContextCanDescribeTheActiveTurn() throws {
        // Codex runs one turn at a time, so a newer context of another turn means
        // this turn's context is stale or missing — never fall through to it.
        let event = try makeEvent(contexts: [context("current", "auto_review"), context("later", "user")])
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON))
    }

    func testMarkerSplitAcrossChunkBoundariesIsStillFound() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        let url = URL(fileURLWithPath: event.rawJSON["transcript_path"] as! String)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let filler = #"{"type":"response_item","payload":{"text":"filler"}}"# + "\n"
        try (filler + contents + filler + filler).write(to: url, atomically: true, encoding: .utf8)
        for chunkBytes in 1...64 {
            XCTAssertEqual(
                CodexPermissionRules.transcriptReviewerValue(event.rawJSON, chunkBytes: chunkBytes),
                "auto_review",
                "chunkBytes \(chunkBytes)"
            )
        }
    }

    func testLongTurnStillFindsItsContextPastFourMiB() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        let url = URL(fileURLWithPath: event.rawJSON["transcript_path"] as! String)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Tool output quoting the marker is JSON-escaped and must not match.
        let output = try JSONSerialization.data(withJSONObject: [
            "type": "response_item",
            "payload": ["output": String(repeating: "x", count: 512 * 1024) + #" "turn_context" "#],
        ])
        for _ in 0..<10 {
            try handle.write(contentsOf: output + Data([0x0A]))
        }
        try handle.close()
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, 5 * 1024 * 1024)
        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testOversizedLineHoldingTheMarkerIsSkipped() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")])
        let url = URL(fileURLWithPath: event.rawJSON["transcript_path"] as! String)
        let contents = try String(contentsOf: url, encoding: .utf8)
        // An unescaped marker in a line too long to be a context is passed over.
        let oversized = #"{"type":"event_msg","payload":{"kind":"turn_context","pad":""#
            + String(repeating: "y", count: 200 * 1024) + "\"}}\n"
        try (contents + oversized).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexPermissionRules.transcriptReviewerValue(event.rawJSON), "auto_review")
    }

    func testHiddenSubagentPermissionIsLeftToAutoReviewInsteadOfAllowed() throws {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("hide", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let url = root.appendingPathComponent("child.jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}"#
        for (reviewer, expected) in [("auto_review", "{}"), ("user", #""behavior":"allow""#)] {
            var data = Data((meta + "\n").utf8)
            data.append(try JSONSerialization.data(withJSONObject: context("current", reviewer)))
            data.append(0x0A)
            try data.write(to: url)
            let payload: [String: Any] = [
                "_source": "codex", "hook_event_name": "PermissionRequest",
                "session_id": "child", "turn_id": "current",
                "transcript_path": url.path, "tool_name": "Bash",
                "tool_input": ["command": "echo test"],
            ]
            let routed = HookServer(appState: AppState())
                .routeSubsessionPayloadIfNeededForTesting(data: try JSONSerialization.data(withJSONObject: payload))
            let response = String(decoding: try XCTUnwrap(routed.responseData, reviewer), as: UTF8.self)
            if expected == "{}" {
                XCTAssertEqual(response, expected, reviewer)
            } else {
                XCTAssertTrue(response.contains(expected), reviewer)
            }
        }
    }

    func testRemoteTranscriptPathIsNeverReadFromTheLocalMachine() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")], fields: ["_remote_host_id": "remote"])
        XCTAssertNil(CodexPermissionRules.transcriptReviewerValue(event.rawJSON))
    }

    func testAskUserQuestionStillUsesIslandInteraction() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")], fields: ["tool_name": "AskUserQuestion"])
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testOtherProvidersAreUnchanged() throws {
        let event = try makeEvent(contexts: [context("current", "auto_review")], fields: ["_source": "claude"])
        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    private func writeConfig(reviewer: String) throws {
        try "approvals_reviewer = \"\(reviewer)\"\n"
            .write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    private func context(_ turnId: String, _ reviewer: String?) -> [String: Any] {
        var payload: [String: Any] = ["turn_id": turnId]
        if let reviewer { payload["approvals_reviewer"] = reviewer }
        return ["type": "turn_context", "payload": payload]
    }

    private func makeEvent(contexts: [[String: Any]], fields: [String: Any] = [:]) throws -> HookEvent {
        let url = root.appendingPathComponent("rollout.jsonl")
        var data = Data()
        for context in contexts {
            data.append(try JSONSerialization.data(withJSONObject: context))
            data.append(0x0A)
        }
        try data.write(to: url)
        var raw: [String: Any] = [
            "_source": "codex", "hook_event_name": "PermissionRequest",
            "session_id": "session", "turn_id": "current",
            "transcript_path": url.path, "tool_name": "Bash",
            "tool_input": ["command": "echo test"],
        ]
        raw.merge(fields) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
    }
}
