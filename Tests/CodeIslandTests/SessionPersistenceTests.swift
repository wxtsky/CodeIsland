import XCTest
import CodeIslandCore
@testable import CodeIsland

final class SessionPersistenceTests: XCTestCase {
    func testCatPawChildIdentitySurvivesSaveAndLegacyDecode() throws {
        let file = URL(fileURLWithPath: SessionPersistence.dirPath).appendingPathComponent("sessions.json")
        let previous = try? Data(contentsOf: file)
        defer {
            if let previous { try? previous.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
        }
        var child = SessionSnapshot()
        child.source = "catpaw-idekit"
        child.catpawIsSubagent = true
        child.catpawAgentName = "Explorer"
        child.lastUserPrompt = "child task"
        child.lastAssistantMessage = "child reply"
        var parent = SessionSnapshot()
        parent.source = "catpaw"
        parent.lastUserPrompt = String(repeating: "0", count: 30) + "private-prompt-tail"
        parent.lastAssistantMessage = String(repeating: "a", count: 30) + "private-reply-tail"
        var claude = parent
        claude.source = "claude"
        SessionPersistence.save(["catpaw-idekit:child": child, "catpaw:parent": parent, "claude": claude])
        let all = SessionPersistence.load()
        let main = try XCTUnwrap(all.first { $0.sessionId == "catpaw:parent" })
        XCTAssertEqual(main.lastUserPrompt, String(repeating: "0", count: 30) + "…")
        XCTAssertEqual(main.lastAssistantMessage, String(repeating: "a", count: 30) + "…")
        XCTAssertEqual(all.first { $0.sessionId == "claude" }?.lastAssistantMessage, claude.lastAssistantMessage)
        let saved = try XCTUnwrap(SessionPersistence.load().first { $0.sessionId == "catpaw-idekit:child" })
        XCTAssertEqual(saved.catpawIsSubagent, true)
        XCTAssertEqual(saved.catpawAgentName, "Explorer")
        XCTAssertNil(saved.lastUserPrompt)
        XCTAssertNil(saved.lastAssistantMessage)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(saved)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "catpawIsSubagent")
        legacy.removeValue(forKey: "catpawAgentName")
        let old = try decoder.decode(PersistedSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.catpawIsSubagent)
        XCTAssertNil(old.catpawAgentName)
    }

    func testPersistedSessionDecodesWithoutCliStartTimeForBackwardCompatibility() throws {
        let json = """
        {
          "sessionId": "session-1",
          "cwd": "/tmp/demo",
          "source": "claude",
          "model": "claude-sonnet-4",
          "sessionTitle": null,
          "sessionTitleSource": null,
          "providerSessionId": null,
          "lastUserPrompt": "hi",
          "lastAssistantMessage": "hello",
          "termApp": null,
          "itermSessionId": null,
          "ttyPath": null,
          "kittyWindowId": null,
          "tmuxPane": null,
          "tmuxClientTty": null,
          "tmuxEnv": null,
          "termBundleId": null,
          "cliPid": 123,
          "startTime": "2026-04-09T10:00:00Z",
          "lastActivity": "2026-04-09T10:01:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(PersistedSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionId, "session-1")
        XCTAssertEqual(session.cliPid, 123)
        XCTAssertNil(session.cliStartTime)
    }

    func testPersistedSessionRoundTripPreservesCliStartTime() throws {
        let startTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:00Z")!
        let cliStartTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:05Z")!
        let session = PersistedSession(
            sessionId: "session-2",
            cwd: "/tmp/demo",
            source: "codex",
            model: "gpt-5",
            sessionTitle: "Demo",
            sessionTitleSource: nil,
            providerSessionId: "provider-2",
            lastUserPrompt: "ping",
            lastAssistantMessage: "pong",
            termApp: "iTerm.app",
            itermSessionId: "abc",
            ttyPath: "/dev/ttys001",
            kittyWindowId: nil,
            tmuxPane: nil,
            tmuxClientTty: nil,
            tmuxEnv: nil,
            termBundleId: nil,
            cmuxSurfaceId: nil,
            cmuxWorkspaceId: nil,
            zellijPaneId: nil,
            zellijSessionName: nil,
            weztermPaneId: nil,
            herdrPaneId: nil,
            herdrSocketPath: nil,
            herdrBinaryPath: nil,
            cliPid: 456,
            cliStartTime: cliStartTime,
            startTime: startTime,
            lastActivity: startTime.addingTimeInterval(30),
            transcriptPath: nil,
            closedSubagentIds: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(PersistedSession.self, from: data)

        XCTAssertEqual(decoded.cliPid, 456)
        XCTAssertEqual(decoded.cliStartTime, cliStartTime)
    }

    func testPersistedSessionRoundTripPreservesClosedSubagentIds() throws {
        let startTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:00Z")!
        let session = PersistedSession(
            sessionId: "session-3",
            cwd: "/tmp/demo",
            source: "cursor",
            model: nil,
            sessionTitle: nil,
            sessionTitleSource: nil,
            providerSessionId: "parent-1",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            termApp: nil,
            itermSessionId: nil,
            ttyPath: nil,
            kittyWindowId: nil,
            tmuxPane: nil,
            tmuxClientTty: nil,
            tmuxEnv: nil,
            termBundleId: nil,
            cmuxSurfaceId: nil,
            cmuxWorkspaceId: nil,
            zellijPaneId: nil,
            zellijSessionName: nil,
            weztermPaneId: nil,
            herdrPaneId: nil,
            herdrSocketPath: nil,
            herdrBinaryPath: nil,
            cliPid: nil,
            cliStartTime: nil,
            startTime: startTime,
            lastActivity: startTime,
            transcriptPath: nil,
            closedSubagentIds: ["2528cb91-6379-48f2-aff8-40f4b804dafa"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedSession.self, from: try encoder.encode(session))

        XCTAssertEqual(decoded.closedSubagentIds, ["2528cb91-6379-48f2-aff8-40f4b804dafa"])
    }

    func testPersistedSessionDecodesWithoutClosedSubagentIdsForBackwardCompatibility() throws {
        let json = """
        {
          "sessionId": "session-4",
          "cwd": "/tmp/demo",
          "source": "cursor",
          "model": null,
          "sessionTitle": null,
          "sessionTitleSource": null,
          "providerSessionId": null,
          "lastUserPrompt": "hi",
          "lastAssistantMessage": null,
          "termApp": null,
          "itermSessionId": null,
          "ttyPath": null,
          "kittyWindowId": null,
          "tmuxPane": null,
          "tmuxClientTty": null,
          "tmuxEnv": null,
          "termBundleId": null,
          "cliPid": null,
          "startTime": "2026-04-09T10:00:00Z",
          "lastActivity": "2026-04-09T10:01:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(PersistedSession.self, from: Data(json.utf8))
        XCTAssertNil(session.closedSubagentIds)
    }

    func testPersistedSessionRoundTripPreservesTranscriptPath() throws {
        let startTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:00Z")!
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl"
        let session = PersistedSession(
            sessionId: "session-5",
            cwd: "/tmp/demo",
            source: "cursor",
            model: nil,
            sessionTitle: nil,
            sessionTitleSource: nil,
            providerSessionId: "e1247fd5-d9a0-48ef-8457-0304606b1833",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            termApp: nil,
            itermSessionId: nil,
            ttyPath: nil,
            kittyWindowId: nil,
            tmuxPane: nil,
            tmuxClientTty: nil,
            tmuxEnv: nil,
            termBundleId: nil,
            cmuxSurfaceId: nil,
            cmuxWorkspaceId: nil,
            zellijPaneId: nil,
            zellijSessionName: nil,
            weztermPaneId: nil,
            herdrPaneId: nil,
            herdrSocketPath: nil,
            herdrBinaryPath: nil,
            cliPid: nil,
            cliStartTime: nil,
            startTime: startTime,
            lastActivity: startTime,
            transcriptPath: path,
            closedSubagentIds: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedSession.self, from: try encoder.encode(session))
        XCTAssertEqual(decoded.transcriptPath, path)
    }

    func testPersistedSessionDecodesWithoutTranscriptPathForBackwardCompatibility() throws {
        let json = """
        {
          "sessionId": "session-6",
          "cwd": "/tmp/demo",
          "source": "cursor",
          "model": null,
          "sessionTitle": null,
          "sessionTitleSource": null,
          "providerSessionId": null,
          "lastUserPrompt": "hi",
          "lastAssistantMessage": null,
          "termApp": null,
          "itermSessionId": null,
          "ttyPath": null,
          "kittyWindowId": null,
          "tmuxPane": null,
          "tmuxClientTty": null,
          "tmuxEnv": null,
          "termBundleId": null,
          "cliPid": null,
          "startTime": "2026-04-09T10:00:00Z",
          "lastActivity": "2026-04-09T10:01:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(PersistedSession.self, from: Data(json.utf8))
        XCTAssertNil(session.transcriptPath)
    }
    func testPersistedSessionRoundTripPreservesHerdrRouting() throws {
        let startTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:00Z")!
        let session = PersistedSession(
            sessionId: "session-herdr",
            cwd: "/tmp/demo",
            source: "omp",
            model: nil,
            sessionTitle: nil,
            sessionTitleSource: nil,
            providerSessionId: nil,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            termApp: "ghostty",
            itermSessionId: nil,
            ttyPath: "/dev/ttys001",
            kittyWindowId: nil,
            tmuxPane: nil,
            tmuxClientTty: nil,
            tmuxEnv: nil,
            termBundleId: "com.mitchellh.ghostty",
            cmuxSurfaceId: nil,
            cmuxWorkspaceId: nil,
            zellijPaneId: nil,
            zellijSessionName: nil,
            weztermPaneId: nil,
            herdrPaneId: "w1:p2",
            herdrSocketPath: "/tmp/herdr.sock",
            herdrBinaryPath: "/opt/homebrew/bin/herdr",
            cliPid: nil,
            cliStartTime: nil,
            startTime: startTime,
            lastActivity: startTime,
            transcriptPath: nil,
            closedSubagentIds: nil
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: data)

        XCTAssertEqual(decoded.herdrPaneId, "w1:p2")
        XCTAssertEqual(decoded.herdrSocketPath, "/tmp/herdr.sock")
        XCTAssertEqual(decoded.herdrBinaryPath, "/opt/homebrew/bin/herdr")
    }

    /// A file written by a newer version, read back after a downgrade: one
    /// entry this build cannot decode must not take every session with it.
    func testDecodeDropsOnlyTheEntryThatCannotBeRead() {
        let json = """
        [
          {"sessionId":"good","source":"claude","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z"},
          {"sessionId":"broken","source":"claude","startTime":"not a date","lastActivity":"2026-04-09T10:01:00Z"},
          {"sessionId":"future-status","source":"codex","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z",
           "agentTasks":{"items":[
             {"id":"step:0","title":"Read","status":"completed"},
             {"id":"step:1","title":"Patch","status":"blocked_on_review"}
           ]}}
        ]
        """

        let sessions = SessionPersistence.decode(Data(json.utf8))

        XCTAssertEqual(sessions.map(\.sessionId), ["good", "future-status"])
        XCTAssertEqual(
            sessions.last?.agentTasks?.items.map(\.status),
            [.completed, .pending],
            "a status this build does not know reads as pending"
        )
    }

    func testDecodeOfAFileThatIsNotAListYieldsNothing() {
        XCTAssertTrue(SessionPersistence.decode(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(SessionPersistence.decode(Data("garbage".utf8)).isEmpty)
    }
}
