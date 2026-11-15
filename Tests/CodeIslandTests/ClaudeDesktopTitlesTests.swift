import XCTest
import CodeIslandCore
@testable import CodeIsland

final class ClaudeDesktopTitlesTests: XCTestCase {
    private var root: URL!
    private var orgDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-titles-\(UUID().uuidString)", isDirectory: true)
        orgDirectory = root.appendingPathComponent("account/org", isDirectory: true)
        try FileManager.default.createDirectory(at: orgDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeSession(_ name: String, _ json: [String: Any]) throws -> URL {
        let url = orgDirectory.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: url)
        return url
    }

    func testFindsTheTitleByCliSessionId() throws {
        try writeSession("local_a.json", ["cliSessionId": "cli-1", "sessionId": "local_a", "title": "Fix the login flow"])
        try writeSession("local_b.json", ["cliSessionId": "cli-2", "sessionId": "local_b", "title": "  Other  "])
        let titles = ClaudeDesktopTitles(root: root)

        XCTAssertEqual(titles.title(cliSessionId: "cli-1"), "Fix the login flow")
        XCTAssertEqual(titles.title(cliSessionId: "cli-2"), "Other")
        XCTAssertNil(titles.title(cliSessionId: "cli-unknown"))
    }

    func testOnlyLocalSessionFilesCount() throws {
        try writeSession("deleted_c.json", ["cliSessionId": "cli-3", "title": "Gone"])
        try writeSession("local_c.txt", ["cliSessionId": "cli-3", "title": "Not JSON"])

        XCTAssertNil(ClaudeDesktopTitles(root: root).title(cliSessionId: "cli-3"))
    }

    func testABlankTitleIsNoTitle() throws {
        try writeSession("local_d.json", ["cliSessionId": "cli-4", "title": "   "])

        XCTAssertNil(ClaudeDesktopTitles(root: root).title(cliSessionId: "cli-4"))
    }

    func testAnIdPastTheHeadIsStillFound() throws {
        // Sorted keys put the filler first, pushing the id past the head read.
        let filler = String(repeating: "x", count: 40_000)
        try writeSession("local_e.json", ["aaa": filler, "cliSessionId": "cli-5", "title": "Deep"])

        XCTAssertEqual(ClaudeDesktopTitles(root: root).title(cliSessionId: "cli-5"), "Deep")
    }

    func testARenameIsPickedUp() throws {
        let url = try writeSession("local_f.json", ["cliSessionId": "cli-6", "title": "Old"])
        let titles = ClaudeDesktopTitles(root: root)
        XCTAssertEqual(titles.title(cliSessionId: "cli-6"), "Old")

        try writeSession("local_f.json", ["cliSessionId": "cli-6", "title": "New"])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        XCTAssertEqual(titles.title(cliSessionId: "cli-6"), "New")
    }

    func testAMissingRootFindsNothing() {
        let titles = ClaudeDesktopTitles(root: root.appendingPathComponent("missing"))
        XCTAssertNil(titles.title(cliSessionId: "cli-1"))
    }

    // MARK: - SessionTitleStore

    private func writeTranscript(_ lines: [String]) throws -> String {
        let url = root.appendingPathComponent("moved-project/session.jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testTheDesktopTitleWinsOverTheTranscript() throws {
        try writeSession("local_g.json", ["cliSessionId": "cli-7", "title": "Desktop title"])
        let transcript = try writeTranscript([#"{"type":"custom-title","customTitle":"Transcript title"}"#])

        let resolved = SessionTitleStore.title(
            for: "cli-7", provider: "claude", cwd: nil, transcriptPath: transcript,
            desktopTitles: ClaudeDesktopTitles(root: root))

        XCTAssertEqual(resolved, ResolvedSessionTitle(title: "Desktop title", source: .claudeDesktopTitle))
    }

    func testWithoutADesktopTitleTheHooksTranscriptPathIsRead() throws {
        // The cwd no longer matches the project dir the transcript sits under.
        let transcript = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"Generated title"}"#,
            #"{"type":"custom-title","customTitle":"Renamed title"}"#,
        ])

        let resolved = SessionTitleStore.title(
            for: "cli-8", provider: "claude", cwd: root.appendingPathComponent("elsewhere").path,
            transcriptPath: transcript, desktopTitles: ClaudeDesktopTitles(root: root))

        XCTAssertEqual(resolved, ResolvedSessionTitle(title: "Renamed title", source: .claudeCustomTitle))
    }

    func testAMissingTranscriptPathFindsNothingWithoutACwd() {
        let resolved = SessionTitleStore.claudeTitle(
            sessionId: "cli-9", cwd: nil, transcriptPath: root.appendingPathComponent("none.jsonl").path)
        XCTAssertNil(resolved)
    }
}
