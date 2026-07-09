import XCTest
@testable import CodeIslandCore

final class SessionSnapshotTitleTests: XCTestCase {
    func testDisplayTitlePrefersProviderSessionTitle() {
        var snapshot = SessionSnapshot()
        snapshot.sessionTitle = "Investigate icon sizing"

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d6331-3593-7b53-9513-c1dd25d708b0"),
            "Investigate icon sizing"
        )
    }

    func testDisplayTitleFallsBackToSessionIdWhenNoProviderTitleExists() {
        let snapshot = SessionSnapshot()

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d632b-abee-76e3-80d6-667ea86ebeaf"),
            "019d632b-abee-76e3-80d6-667ea86ebeaf"
        )
    }

    func testProjectDisplayNameStillUsesFolderName() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/CodeIsland"

        XCTAssertEqual(snapshot.projectDisplayName, "CodeIsland")
    }

    func testProjectDisplayNameSkipsClaudeMetadataDir() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/Code/CodeIsland/.claude"

        XCTAssertEqual(snapshot.projectDisplayName, "CodeIsland")
    }

    func testProjectDisplayNameDoesNotUseHomeUsernameForGlobalClaudeDir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var snapshot = SessionSnapshot()
        snapshot.cwd = "\(home)/.claude"

        XCTAssertNotEqual(snapshot.projectDisplayName, (home as NSString).lastPathComponent)
        XCTAssertEqual(snapshot.projectDisplayName, "Session")
    }

    func testProjectDisplayNameDecodesCursorProjectsPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let homeEncoded = String(home.dropFirst()).replacingOccurrences(of: "/", with: "-")
        var snapshot = SessionSnapshot()
        snapshot.cwd = "\(home)/.cursor/projects/\(homeEncoded)-Code-CodeIsland/agent-transcripts"

        XCTAssertEqual(snapshot.projectDisplayName, "CodeIsland")
    }

    func testProjectDisplayNamePreservesHyphenatedCursorProjectLeaf() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectDir = "\(home)/Code/codeisland-hyphen-display-test"
        try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: projectDir) }

        let homeEncoded = String(home.dropFirst()).replacingOccurrences(of: "/", with: "-")
        var snapshot = SessionSnapshot()
        snapshot.cwd = "\(home)/.cursor/projects/\(homeEncoded)-Code-codeisland-hyphen-display-test/agent-transcripts"

        XCTAssertEqual(snapshot.projectDisplayName, "codeisland-hyphen-display-test")
    }

    func testProjectDisplayNamePeelsMetadataDirFromCursorEncodedPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let homeEncoded = String(home.dropFirst()).replacingOccurrences(of: "/", with: "-")
        var snapshot = SessionSnapshot()
        snapshot.cwd = "\(home)/.cursor/projects/\(homeEncoded)-Code-CodeIsland-.claude/agent-transcripts"

        XCTAssertEqual(snapshot.projectDisplayName, "CodeIsland")
    }

    func testDisplaySessionIdPrefersProviderSessionId() {
        var snapshot = SessionSnapshot()
        snapshot.providerSessionId = "019d6330-beed-7a13-b61e-cacf03d3cefe"

        XCTAssertEqual(
            snapshot.displaySessionId(sessionId: "hook-codex-session"),
            "019d6330-beed-7a13-b61e-cacf03d3cefe"
        )
    }

    func testDisplaySessionIdFallsBackToTrackedSessionId() {
        let snapshot = SessionSnapshot()

        XCTAssertEqual(
            snapshot.displaySessionId(sessionId: "hook-codex-session"),
            "hook-codex-session"
        )
    }

    func testSessionTitleAssignmentDoesNotOverwriteProjectDisplayName() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/CodeIsland"
        snapshot.sessionTitle = "查看图标bug和窗口大小bug解法"

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d6331-3593-7b53-9513-c1dd25d708b0"),
            "查看图标bug和窗口大小bug解法"
        )
        XCTAssertEqual(snapshot.projectDisplayName, "CodeIsland")
    }
}
