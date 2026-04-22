import XCTest
@testable import CodeIslandCore

final class DerivedSessionStateTests: XCTestCase {
    func testAllIdleSessionsUseMostRecentlyActiveSource() {
        var older = SessionSnapshot()
        older.source = "claude"
        older.status = .idle
        older.lastActivity = Date(timeIntervalSince1970: 100)

        var newer = SessionSnapshot()
        newer.source = "codex"
        newer.status = .idle
        newer.lastActivity = Date(timeIntervalSince1970: 200)

        let summary = deriveSessionSummary(from: [
            "older": older,
            "newer": newer,
        ])

        XCTAssertEqual(summary.primarySource, "codex")
        XCTAssertEqual(summary.activeSessionCount, 0)
        XCTAssertEqual(summary.totalSessionCount, 2)
    }

    func testNormalizesTraecliAliases() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("traecli"), "traecli")
    }

    func testNormalizesThirdPartySourceAliases() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("workbody"), "workbuddy")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("work-body"), "workbuddy")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("hermes-agents"), "hermes")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("anti-gravity"), "antigravity")
    }

    func testNormalizesCocoSnakeCaseEvents() {
        XCTAssertEqual(EventNormalizer.normalize("pre_tool_use"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("permission_request"), "PermissionRequest")
        XCTAssertEqual(EventNormalizer.normalize("post_compact"), "PostCompact")
    }

    func testCLIProcessResolverPrefersTraecliBinaryOverShellParent() {
        let pid = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 100,
            source: "traecli",
            ancestry: [
                (pid: 100, executablePath: "/bin/sh"),
                (pid: 88, executablePath: "/opt/homebrew/bin/coco"),
                (pid: 77, executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            ]
        )

        XCTAssertEqual(pid, 88)
    }

    func testCLIProcessResolverFallsBackToImmediateParentWhenNoMatchFound() {
        let pid = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 100,
            source: "traecli",
            ancestry: [
                (pid: 100, executablePath: "/bin/sh"),
                (pid: 88, executablePath: "/usr/bin/login"),
            ]
        )

        XCTAssertEqual(pid, 100)
    }

    // MARK: - Source inference (issue #95)

    func testInferSourceFindsOpencodeInAncestryWhenSourceTagMissing() {
        // omo plugin triggers Claude hooks, but the real CLI up the ancestry is OpenCode.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh"),
            (pid: 150, executablePath: "/usr/local/bin/node"),
            (pid: 100, executablePath: "/Applications/OpenCode.app/Contents/MacOS/OpenCode"),
        ])

        XCTAssertEqual(source, "opencode")
    }

    func testInferSourceReturnsNilWhenNoKnownBinaryInAncestry() {
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh"),
            (pid: 150, executablePath: "/usr/bin/login"),
            (pid: 100, executablePath: "/sbin/launchd"),
        ])

        XCTAssertNil(source)
    }

    func testInferSourceReturnsClosestMatchAlongAncestry() {
        // If multiple known CLIs appear, the nearest ancestor wins.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/usr/local/bin/codex"),
            (pid: 100, executablePath: "/Applications/Claude.app/Contents/MacOS/claude"),
        ])

        XCTAssertEqual(source, "codex")
    }
}
