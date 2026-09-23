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
}
