import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class KiroSessionDiscoveryTests: XCTestCase {
    func testDiscoverActiveKiroSessionFromLease() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("kiro_test_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        let leasesDir = tempRoot.appendingPathComponent("session-leases")
        let sessionDir = tempRoot.appendingPathComponent("sessions/workspace_123/sess_abc_1")
        try fm.createDirectory(at: leasesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let leaseJson = """
        {"v":1,"pid":99999,"parentPid":88888,"instanceId":"test-inst","clientName":"kiro-cli"}
        """
        try leaseJson.write(to: leasesDir.appendingPathComponent("sess_abc_1.lease"), atomically: true, encoding: .utf8)

        let sessionJson = """
        {
          "schemaVersion": "1.0.0",
          "id": "sess_abc_1",
          "title": "Test Kiro Run",
          "workspacePaths": ["/tmp/kiro-project"],
          "modelId": "claude-opus-5.5",
          "status": "in_progress",
          "createdAt": "2026-11-12T04:00:00.000Z",
          "lastModifiedAt": "2026-11-12T04:05:00.000Z"
        }
        """
        try sessionJson.write(to: sessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let transcript = """
        {"id":"m1","timestamp":"2026-11-12T04:01:00.000Z","payload":{"type":"user","content":"Fix the bug in main.swift"}}
        {"id":"m2","timestamp":"2026-11-12T04:02:00.000Z","payload":{"type":"assistant","content":"I am analyzing main.swift now."}}
        """
        try transcript.write(to: sessionDir.appendingPathComponent("messages.jsonl"), atomically: true, encoding: .utf8)

        let discovered = KiroDiscovery.findActiveKiroSessions(
            root: tempRoot.path,
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(discovered.count, 1)
        let match = try XCTUnwrap(discovered.first)
        XCTAssertEqual(match.sessionId, "sess_abc_1")
        XCTAssertEqual(match.cwd, "/tmp/kiro-project")
        XCTAssertEqual(match.model, "claude-opus-5.5")
        XCTAssertEqual(match.status, .running)
        XCTAssertEqual(match.source, "kiro")
        XCTAssertEqual(match.recentMessages.count, 2)
        XCTAssertEqual(match.recentMessages[0].text, "Fix the bug in main.swift")
        XCTAssertTrue(match.recentMessages[0].isUser)
        XCTAssertEqual(match.recentMessages[1].text, "I am analyzing main.swift now.")
        XCTAssertFalse(match.recentMessages[1].isUser)
    }

    func testDeadLeaseIsIgnored() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("kiro_test_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        let leasesDir = tempRoot.appendingPathComponent("session-leases")
        try fm.createDirectory(at: leasesDir, withIntermediateDirectories: true)

        let leaseJson = """
        {"v":1,"pid":99999,"parentPid":88888,"instanceId":"test-inst","clientName":"kiro-cli"}
        """
        try leaseJson.write(to: leasesDir.appendingPathComponent("sess_dead.lease"), atomically: true, encoding: .utf8)

        let discovered = KiroDiscovery.findActiveKiroSessions(
            root: tempRoot.path,
            isProcessAlive: { _ in false }
        )

        XCTAssertTrue(discovered.isEmpty)
    }

    func testDiscoverKiroSessionByCwd() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("kiro_test_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        let sessionDir = tempRoot.appendingPathComponent("sessions/workspace_xyz/sess_xyz_2")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let sessionJson = """
        {
          "id": "sess_xyz_2",
          "workspacePaths": ["/Users/developer/code"],
          "modelId": "claude-sonnet-5.5",
          "status": "idle"
        }
        """
        try sessionJson.write(to: sessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let match = KiroDiscovery.findRecentKiroSession(
            cwd: "/Users/developer/code",
            after: nil,
            root: tempRoot.path,
            fm: fm
        )

        let session = try XCTUnwrap(match)
        XCTAssertEqual(session.sessionId, "sess_xyz_2")
        XCTAssertEqual(session.model, "claude-sonnet-5.5")
        XCTAssertEqual(session.status, .idle)

        let noMatch = KiroDiscovery.findRecentKiroSession(
            cwd: "/tmp/non-existent-folder",
            after: nil,
            root: tempRoot.path,
            fm: fm
        )
        XCTAssertNil(noMatch)
    }

    func testDiscoverLegacyV2KiroSession() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("kiro_test_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        let cliDir = tempRoot.appendingPathComponent("sessions/cli")
        try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)

        let sessionJson = """
        {
          "session_id": "legacy_v2_session",
          "cwd": "/private/tmp/v2-project",
          "title": "Legacy Test"
        }
        """
        try sessionJson.write(to: cliDir.appendingPathComponent("legacy_v2_session.json"), atomically: true, encoding: .utf8)

        let transcript = """
        {"version":"v1","kind":"Prompt","data":{"content":[{"kind":"text","data":"legacy prompt"}]}}
        """
        try transcript.write(to: cliDir.appendingPathComponent("legacy_v2_session.jsonl"), atomically: true, encoding: .utf8)

        let match = KiroDiscovery.findRecentKiroSession(
            cwd: "/private/tmp/v2-project",
            after: nil,
            root: tempRoot.path,
            fm: fm
        )

        let session = try XCTUnwrap(match)
        XCTAssertEqual(session.sessionId, "legacy_v2_session")
        XCTAssertEqual(session.recentMessages.count, 1)
        XCTAssertEqual(session.recentMessages[0].text, "legacy prompt")
    }

    func testJSONLTailerParsesKiroPayload() {
        let kiroUserLine = """
        {"id":"1","timestamp":"2026-11-12T00:00:00Z","payload":{"type":"user","content":"Run unit tests"}}
        \n
        """
        let scanUser = JSONLTailer.scanLines(Data(kiroUserLine.utf8))
        XCTAssertEqual(scanUser.delta.lastUserPrompt, "Run unit tests")

        let kiroAssistantLine = """
        {"id":"2","timestamp":"2026-11-12T00:00:01Z","payload":{"type":"assistant","content":"All unit tests passed."}}
        \n
        """
        let scanAssistant = JSONLTailer.scanLines(Data(kiroAssistantLine.utf8))
        XCTAssertEqual(scanAssistant.delta.lastAssistantMessage, "All unit tests passed.")

        let kiroToolLine = """
        {"id":"3","timestamp":"2026-11-12T00:00:02Z","payload":{"type":"tool_call","toolName":"execute_bash"}}
        \n
        """
        let scanTool = JSONLTailer.scanLines(Data(kiroToolLine.utf8))
        XCTAssertTrue(scanTool.delta.hasActivity)
    }
}
