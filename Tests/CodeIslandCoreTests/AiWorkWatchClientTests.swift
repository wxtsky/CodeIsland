import XCTest
@testable import CodeIslandCore

final class AiWorkWatchClientTests: XCTestCase {

    // MARK: - Frame parsing

    func testParseResponseFrame() {
        let json = #"{"kind":"response","ok":true,"category":"session","operation":"sessions.list","data":{"sessions":[]},"meta":{"schema_version":"2.0"}}"#
        let frame = AiWorkWatchClient.parseFrame(Data(json.utf8))
        XCTAssertEqual(frame?.kind, .response(operation: "sessions.list", ok: true))
        XCTAssertNotNil(frame?.dataObject)
    }

    func testParseEventFrameExtractsSessionIdFromMeta() {
        let json = #"{"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.tool_call","phase":"start"},"data":{"title":"exec"},"meta":{"session_id":"acp:coder:abc","schema_version":"2.0"}}"#
        let frame = AiWorkWatchClient.parseFrame(Data(json.utf8))
        XCTAssertEqual(frame?.kind, .event(name: "stream.tool_call", phase: "start"))
        XCTAssertEqual(frame?.sessionId, "acp:coder:abc")
        XCTAssertEqual(AiWorkStatusMapper.toolName(from: frame?.dataObject), "exec")
    }

    func testParseEventFrameFallsBackToDataSession() {
        let json = #"{"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.started","phase":"start"},"data":{"session":{"session_id":"cli:coder:xyz"}},"meta":{}}"#
        let frame = AiWorkWatchClient.parseFrame(Data(json.utf8))
        XCTAssertEqual(frame?.sessionId, "cli:coder:xyz")
    }

    func testDrainFramesKeepsPartialTrailingLine() {
        var buffer = Data()
        buffer.append(Data(#"{"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.started","phase":"start"},"data":{},"meta":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"kind":"event","event":{"name":"stream.partial"#.utf8))

        let frames = AiWorkWatchClient.drainFrames(buffer: &buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].eventName, "stream.started")
        XCTAssertEqual(String(data: buffer, encoding: .utf8), #"{"kind":"event","event":{"name":"stream.partial"#)
    }

    // MARK: - Status mapping

    func testStatusMappingPriorityEvents() {
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.approval_required"), .waitingApproval)
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.plan_confirmation_required"), .waitingApproval)
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.question_required"), .waitingQuestion)
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.tool_call"), .running)
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.thinking_delta"), .processing)
        XCTAssertEqual(AiWorkStatusMapper.status(forEventName: "stream.completed"), .idle)
        XCTAssertNil(AiWorkStatusMapper.status(forEventName: "stream.session_watch_diagnostic"))
    }

    func testSourceLabelFromSessionPrefix() {
        XCTAssertEqual(AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "acp:coder:1"), "AiWork")
        XCTAssertEqual(AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "cli:coder:1"), "AiWork CLI")
        XCTAssertEqual(AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "gateway:coder:1"), "AiWork")
        XCTAssertEqual(AiWorkStatusMapper.sourceLabel(forDaemonSessionId: nil), "AiWork")
    }

    func testSourceLabelPrefersClientTypeOverAcpPrefix() {
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(
                forDaemonSessionId: "acp:coder:1",
                clientType: "DTCoderTUI"
            ),
            "AiWork CLI"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(
                forDaemonSessionId: "acp:coder:1",
                clientType: "DTCoderGUI"
            ),
            "AiWork"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(
                forDaemonSessionId: "acp:coder:1",
                clientType: "AiWorkTUI"
            ),
            "AiWork CLI"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(
                forDaemonSessionId: "acp:coder:1",
                clientType: "AiWorkGUI"
            ),
            "AiWork"
        )
    }

    func testActiveListEntryFilter() {
        let idle: [String: AnyCodableLike] = [
            "status": .string("active"),
            "readable_summary": .object(["phase": .string("idle")])
        ]
        XCTAssertFalse(AiWorkStatusMapper.isActiveListEntry(idle))

        let waiting: [String: AnyCodableLike] = [
            "status": .string("waiting_approval")
        ]
        XCTAssertTrue(AiWorkStatusMapper.isActiveListEntry(waiting))

        let streaming: [String: AnyCodableLike] = [
            "status": .string("active"),
            "readable_summary": .object(["phase": .string("llm_streaming")])
        ]
        XCTAssertTrue(AiWorkStatusMapper.isActiveListEntry(streaming))
    }

    func testAgentStatusFromListEntry() {
        let waitingQ: [String: AnyCodableLike] = [
            "status": .string("active"),
            "external_turn": .object(["status": .string("waiting_user_input"), "waiting_for": .string("question")])
        ]
        XCTAssertEqual(AiWorkStatusMapper.agentStatus(fromListEntry: waitingQ), .waitingQuestion)

        let tool: [String: AnyCodableLike] = [
            "status": .string("active"),
            "readable_summary": .object(["phase": .string("tool_execution")])
        ]
        XCTAssertEqual(AiWorkStatusMapper.agentStatus(fromListEntry: tool), .running)
    }

    // MARK: - Discovery

    func testDiscoverReadyDaemonsRequiresSockAndReady() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codeisland-aiwork-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let coder = root.appendingPathComponent("run/coder", isDirectory: true)
        try fm.createDirectory(at: coder, withIntermediateDirectories: true)
        try Data().write(to: coder.appendingPathComponent("agent.sock"))
        try Data("1".utf8).write(to: coder.appendingPathComponent("agent.ready"))

        let incomplete = root.appendingPathComponent("run/default", isDirectory: true)
        try fm.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data().write(to: incomplete.appendingPathComponent("agent.sock"))
        // no agent.ready

        let found = AiWorkWatchClient.discoverReadyDaemons(stateDir: root.path, fileManager: fm)
        XCTAssertEqual(found.map(\.agentId), ["coder"])
        XCTAssertTrue(found[0].socketPath.hasSuffix("/run/coder/agent.sock"))
    }

    func testDefaultStateDirHonorsEnv() {
        let path = AiWorkWatchClient.defaultStateDir(
            environment: ["AGENTIX_STATE_DIR": "/tmp/custom-agentix"],
            homeDirectory: "/Users/test"
        )
        XCTAssertEqual(path, "/tmp/custom-agentix")

        let fallback = AiWorkWatchClient.defaultStateDir(
            environment: [:],
            homeDirectory: "/Users/test"
        )
        XCTAssertEqual(fallback, "/Users/test/.agentix")
    }

    /// Live smoke against a running local Agentix daemon (skipped when absent).
    func testLiveUnaryAgentStatsIfDaemonPresent() throws {
        let daemons = AiWorkWatchClient.discoverReadyDaemons()
        try XCTSkipIf(daemons.isEmpty, "No Agentix daemon ready under ~/.agentix/run")
        let sock = try XCTUnwrap(daemons.first?.socketPath)
        let frame = AiWorkWatchClient.unaryCall(
            socketPath: sock,
            method: "agent.stats",
            params: [String: Any](),
            timeoutSeconds: 5
        )
        guard let frame else {
            XCTFail("unary agent.stats returned nil")
            return
        }
        guard case .response(let op, let ok) = frame.kind else {
            XCTFail("expected response frame, got \(frame.kind)")
            return
        }
        XCTAssertEqual(op, "agent.stats")
        XCTAssertTrue(ok)
        XCTAssertNotNil(frame.dataObject?["agent_id"])
    }

    func testToolDescriptionPrefersCommandAndDisplayTitle() {
        let withCommand: [String: AnyCodableLike] = [
            "name": .string("exec"),
            "input": .object(["command": .string("pwd")])
        ]
        XCTAssertEqual(AiWorkStatusMapper.toolDescription(from: withCommand), "pwd")

        let withDisplay: [String: AnyCodableLike] = [
            "name": .string("web_search"),
            "_meta": .object([
                "agentix.tool_display.v1": .object([
                    "title": .string("web_search: today news"),
                    "tool_name": .string("web_search")
                ])
            ])
        ]
        XCTAssertEqual(AiWorkStatusMapper.toolName(from: withDisplay), "web_search")
        XCTAssertEqual(AiWorkStatusMapper.toolDescription(from: withDisplay), "web_search: today news")
    }

    func testProgressLabelAndText() {
        let data: [String: AnyCodableLike] = [
            "phase": .string("provider_waiting"),
            "text": .string("等待模型服务…")
        ]
        XCTAssertEqual(AiWorkStatusMapper.progressLabel(from: data, eventName: "stream.progress"), "waiting")
        XCTAssertEqual(AiWorkStatusMapper.progressText(from: data), "等待模型服务…")
    }

    func testShouldForceIdleSessionUsesBusySetAndGrace() {
        let now = Date()
        XCTAssertTrue(
            AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: "acp:coder:1",
                lastActivity: now.addingTimeInterval(-15),
                busyDaemonIds: [],
                now: now,
                grace: 8
            )
        )
        XCTAssertFalse(
            AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: "acp:coder:1",
                lastActivity: now.addingTimeInterval(-15),
                busyDaemonIds: ["acp:coder:1"],
                now: now,
                grace: 8
            )
        )
    }

    func testCodeIslandSourceSplitsGuiAndCli() {
        XCTAssertEqual(AiWorkStatusMapper.codeIslandSource(clientType: "DTCoderGUI"), "aiwork")
        XCTAssertEqual(AiWorkStatusMapper.codeIslandSource(clientType: "DTCoderTUI"), "aiwork-cli")
        XCTAssertEqual(AiWorkStatusMapper.codeIslandSource(clientType: "AiWorkGUI"), "aiwork")
        XCTAssertEqual(AiWorkStatusMapper.codeIslandSource(clientType: "AiWorkTUI"), "aiwork-cli")
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: nil, daemonSessionId: "cli:coder:x"),
            "aiwork-cli"
        )
    }
    /// Force-idle groups stuck sessions per owning daemon; that grouping is only
    /// correct if `channel:agent:uuid` yields the agent segment.
    func testAgentIdFromDaemonSessionId() {
        XCTAssertEqual(AiWorkWatchClient.agentId(fromDaemonSessionId: "acp:coder:abc123"), "coder")
        XCTAssertEqual(AiWorkWatchClient.agentId(fromDaemonSessionId: "cli:coder:abc123"), "coder")
        XCTAssertEqual(AiWorkWatchClient.agentId(fromDaemonSessionId: "gateway:review:x"), "review")
        // No agent segment / malformed ids must not attribute to a wrong daemon.
        XCTAssertNil(AiWorkWatchClient.agentId(fromDaemonSessionId: "acp:coder"))
        XCTAssertNil(AiWorkWatchClient.agentId(fromDaemonSessionId: "bare-uuid"))
        XCTAssertNil(AiWorkWatchClient.agentId(fromDaemonSessionId: "acp::abc123"))
        XCTAssertNil(AiWorkWatchClient.agentId(fromDaemonSessionId: ""))
    }

}
