import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// AiWork RPC paths exercised against `FakeAgentixDaemon` instead of whatever
/// Agentix daemon happens to be running on the machine.
final class AiWorkFakeDaemonTests: XCTestCase {

    private static let statsReply = #"""
    {"kind":"response","operation":"agent.stats","ok":true,"data":{"agent_id":"coder","active_request_details":[{"session_id":"acp:coder:busy"}]}}
    """#

    func testUnaryCallAsyncRoundTripsAgainstFakeDaemon() async throws {
        let daemon = try FakeAgentixDaemon { method in
            method == "agent.stats" ? .reply(Self.statsReply) : .close
        }
        defer { daemon.stop() }

        let found = AiWorkWatchClient.discoverReadyDaemons(stateDir: daemon.stateDir)
        XCTAssertEqual(found.map(\.agentId), ["coder"])
        XCTAssertEqual(found.first?.socketPath, daemon.socketPath)

        let frame = await AiWorkWatchClient.unaryCallAsync(
            socketPath: daemon.socketPath,
            method: "agent.stats",
            params: [String: Any](),
            timeoutSeconds: 3
        )
        guard case .response(let operation, let ok)? = frame?.kind else {
            return XCTFail("expected a response frame, got \(String(describing: frame?.kind))")
        }
        XCTAssertEqual(operation, "agent.stats")
        XCTAssertTrue(ok)
        XCTAssertEqual(frame?.dataObject?["agent_id"]?.asString, "coder")

        let busy = await AiWorkStatusMapper.fetchBusyDaemonSessionIds(socketPath: daemon.socketPath)
        XCTAssertEqual(busy, ["acp:coder:busy"])
    }

    /// "Unreachable" must come back as nil, never as "nothing is busy" — the
    /// reconcile would otherwise force-idle every session of that daemon.
    func testFetchBusyIsNilWhenDaemonHangsUp() async throws {
        let daemon = try FakeAgentixDaemon { _ in .close }
        defer { daemon.stop() }

        let busy = await AiWorkStatusMapper.fetchBusyDaemonSessionIds(socketPath: daemon.socketPath)
        XCTAssertNil(busy)
    }

    /// A daemon that accepts but never answers used to pin one cooperative-pool
    /// thread per in-flight RPC for the whole timeout (the blocking wait ran inside
    /// `Task.detached`). With more callers than cores, unrelated tasks starved.
    func testHungDaemonDoesNotStarveCooperativePool() async throws {
        let daemon = try FakeAgentixDaemon { _ in .hang }
        defer { daemon.stop() }
        let socketPath = daemon.socketPath

        let callers = ProcessInfo.processInfo.activeProcessorCount + 2
        for _ in 0..<callers {
            Task.detached(priority: .utility) {
                _ = await AiWorkWatchClient.unaryCallAsync(
                    socketPath: socketPath,
                    method: "agent.stats",
                    timeoutSeconds: 3
                )
            }
        }
        try await Task.sleep(for: .milliseconds(200))

        let start = ProcessInfo.processInfo.systemUptime
        let probe = await Task.detached(priority: .utility) { 42 }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(probe, 42)
        XCTAssertLessThan(elapsed, 1.0, "blocking RPC waits pinned the cooperative pool")
        // stop() (deferred) closes the held connection; queued callers then find
        // the socket gone and return at once.
    }

    /// `sessions.get` failing used to release the hydrate marker, and an untitled
    /// session re-hydrates on every event — so each streamed token opened a new
    /// connection to the daemon.
    @MainActor
    func testFailedHydrateIsNotRedialledPerToken() async throws {
        let daemon = try FakeAgentixDaemon { method in
            .reply(#"{"kind":"response","operation":"\#(method)","ok":false,"error":{"message":"unavailable"}}"#)
        }
        defer { daemon.stop() }

        let appState = AppState()
        appState.aiworkStateDirOverride = daemon.stateDir
        let sid = "acp:coder:storm"

        let started = try XCTUnwrap(AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","event":{"name":"stream.started"},"data":{"session":{"session_id":"acp:coder:storm"}},"meta":{"session_id":"acp:coder:storm"}}
        """#.utf8)))
        appState.handleAiWorkStreamEvent(name: "stream.started", frame: started, agentId: "coder")

        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while appState.aiworkHydrateFailedAt[sid] == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(appState.aiworkHydrateFailedAt[sid], "first sessions.get never failed")
        XCTAssertEqual(daemon.connectionCount, 1)

        let delta = try XCTUnwrap(AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","event":{"name":"stream.text_delta"},"data":{"text":"tok "},"meta":{"session_id":"acp:coder:storm"}}
        """#.utf8)))
        for _ in 0..<25 {
            appState.handleAiWorkStreamEvent(name: "stream.text_delta", frame: delta, agentId: "coder")
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(daemon.connectionCount, 1, "failed sessions.get was re-dialled per token")
        XCTAssertEqual(daemon.methods, ["sessions.get"])
        // The session itself keeps streaming; only the metadata lookup waits.
        XCTAssertEqual(appState.sessions["aiwork:" + sid]?.status, .processing)
    }
}
