import XCTest
@testable import CodeIsland

final class KimiCodeSessionDiscoveryTests: XCTestCase {
    func testDiscoverKimiCodeSessionFromIndexMatchesWorkDirAndReadsWire() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let sessionDir = kimiCode.appendingPathComponent("sessions/sid-1")
        let agentsMain = sessionDir.appendingPathComponent("agents/main")
        try fm.createDirectory(at: agentsMain, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let cwd = "/tmp/project-a"
        let indexLine = """
        {"sessionId":"sid-1","sessionDir":"\(sessionDir.path)","workDir":"\(cwd)"}
        """
        try indexLine.write(
            to: kimiCode.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"status":"running"}"#.write(
            to: sessionDir.appendingPathComponent("state.json"),
            atomically: true,
            encoding: .utf8
        )
        let wire = [
            #"{"type":"turn.prompt","input":[{"type":"text","text":"Hello kimi"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Hi there"}}}"#,
        ].joined(separator: "\n")
        try wire.write(
            to: agentsMain.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let discovered = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: cwd,
            pid: 4242,
            processStart: Date(),
            fm: fm
        )

        let match = try XCTUnwrap(discovered)
        XCTAssertEqual(match.sessionId, "sid-1")
        XCTAssertEqual(match.cwd, cwd)
        XCTAssertEqual(match.pid, 4242)
        XCTAssertEqual(match.source, "kimi")
        XCTAssertEqual(match.messageTexts, ["Hello kimi", "Hi there"])
    }

    func testDiscoverKimiCodeSessionFromIndexIgnoresOtherWorkDirs() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let sessionDir = kimiCode.appendingPathComponent("sessions/sid-other")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try #"{"sessionId":"sid-other","sessionDir":"\#(sessionDir.path)","workDir":"/tmp/other"}"#
            .write(to: kimiCode.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        try #"{"status":"running"}"#
            .write(to: sessionDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let discovered = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: "/tmp/project-a",
            pid: 1,
            processStart: Date(),
            fm: fm
        )
        XCTAssertNil(discovered)
    }

    func testDiscoverKimiCodeSessionFromIndexRejectsStaleState() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let sessionDir = kimiCode.appendingPathComponent("sessions/sid-stale")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let cwd = "/tmp/project-stale"
        try #"{"sessionId":"sid-stale","sessionDir":"\#(sessionDir.path)","workDir":"\#(cwd)"}"#
            .write(to: kimiCode.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let stateURL = sessionDir.appendingPathComponent("state.json")
        try #"{"status":"idle"}"#.write(to: stateURL, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-3600)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: stateURL.path)

        let discovered = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: cwd,
            pid: 1,
            processStart: Date(),
            fm: fm
        )
        XCTAssertNil(discovered)
    }

    /// Multi-line index: same workDir → pick the newest state.json mtime.
    func testDiscoverKimiCodeSessionFromIndexPicksNewestAmongMatchingLines() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let olderDir = kimiCode.appendingPathComponent("sessions/sid-old")
        let newerDir = kimiCode.appendingPathComponent("sessions/sid-new")
        let otherDir = kimiCode.appendingPathComponent("sessions/sid-other")
        try fm.createDirectory(at: olderDir.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newerDir.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let cwd = "/tmp/project-multi"
        let index = [
            #"{"sessionId":"sid-old","sessionDir":"\#(olderDir.path)","workDir":"\#(cwd)"}"#,
            #"{"sessionId":"sid-other","sessionDir":"\#(otherDir.path)","workDir":"/tmp/elsewhere"}"#,
            #"{"sessionId":"sid-new","sessionDir":"\#(newerDir.path)","workDir":"\#(cwd)"}"#,
        ].joined(separator: "\n")
        try index.write(
            to: kimiCode.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let olderState = olderDir.appendingPathComponent("state.json")
        let newerState = newerDir.appendingPathComponent("state.json")
        try #"{"status":"idle"}"#.write(to: olderState, atomically: true, encoding: .utf8)
        try #"{"status":"running"}"#.write(to: newerState, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: olderState.path
        )
        try fm.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: newerState.path
        )

        let discovered = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: cwd,
            pid: 7,
            processStart: Date(),
            fm: fm
        )
        XCTAssertEqual(discovered?.sessionId, "sid-new")
    }

    /// Without processStart, freshness window is 30s (not 300s).
    func testDiscoverKimiCodeSessionFromIndexNilProcessStartUsesShortFreshnessWindow() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let sessionDir = kimiCode.appendingPathComponent("sessions/sid-nil-start")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let cwd = "/tmp/project-nil-start"
        try #"{"sessionId":"sid-nil-start","sessionDir":"\#(sessionDir.path)","workDir":"\#(cwd)"}"#
            .write(to: kimiCode.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let stateURL = sessionDir.appendingPathComponent("state.json")
        try #"{"status":"idle"}"#.write(to: stateURL, atomically: true, encoding: .utf8)
        // Older than 30s → rejected when processStart is nil; would still pass the
        // 300s window used when processStart is set.
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90)],
            ofItemAtPath: stateURL.path
        )

        let rejected = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: cwd,
            pid: 1,
            processStart: nil,
            fm: fm
        )
        XCTAssertNil(rejected)

        let acceptedWithProcessStart = AppState.discoverKimiCodeSessionFromIndexForTesting(
            home: home.path,
            cwd: cwd,
            pid: 1,
            processStart: Date().addingTimeInterval(-120),
            fm: fm
        )
        XCTAssertEqual(acceptedWithProcessStart?.sessionId, "sid-nil-start")
    }
}
