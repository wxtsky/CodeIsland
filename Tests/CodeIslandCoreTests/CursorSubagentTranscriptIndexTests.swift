import XCTest
@testable import CodeIslandCore

final class CursorSubagentTranscriptIndexTests: XCTestCase {
    private let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"

    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "cursor-subagent-index-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return home
    }

    private func write(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testScanIndexesTaskTranscriptsButNotParentChats() throws {
        let home = try makeHome()
        let base = "\(home)/.cursor/projects/Users-u-proj/agent-transcripts"
        let child = "\(base)/\(parentId)/subagents/\(childId).jsonl"
        try write(child)
        try write("\(base)/\(parentId)/\(parentId).jsonl")

        let index = CursorSubagentTranscriptIndex.scan(home: home)

        XCTAssertEqual(index.transcriptPath(sessionId: childId, preferredBase: nil), child)
        XCTAssertTrue(index.contains(sessionId: " \(childId)\n"), "ids are trimmed like hook ids")
        XCTAssertFalse(index.contains(sessionId: parentId), "a parent chat is not a Task")
    }

    func testScanMatchesSubagentsDirectlyUnderAgentTranscripts() throws {
        let home = try makeHome()
        let path = "\(home)/.cursor/projects/p/agent-transcripts/subagents/\(childId).jsonl"
        try write(path)

        XCTAssertEqual(
            CursorSubagentTranscriptIndex.scan(home: home).transcriptPath(sessionId: childId, preferredBase: nil),
            path
        )
    }

    func testLookupPrefersTheCardsOwnProject() throws {
        let home = try makeHome()
        let other = "\(home)/.cursor/projects/a-other/agent-transcripts"
        let own = "\(home)/.cursor/projects/b-own/agent-transcripts"
        try write("\(other)/\(parentId)/subagents/\(childId).jsonl")
        try write("\(own)/\(parentId)/subagents/\(childId).jsonl")

        let index = CursorSubagentTranscriptIndex.scan(home: home)

        XCTAssertEqual(
            index.transcriptPath(sessionId: childId, preferredBase: own),
            "\(own)/\(parentId)/subagents/\(childId).jsonl"
        )
    }

    func testScanOfMissingStoreIsEmpty() throws {
        let home = try makeHome()
        XCTAssertFalse(CursorSubagentTranscriptIndex.scan(home: home).contains(sessionId: childId))
    }

    func testNextRebuildDatePolicy() {
        let built = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(
            CursorSubagentTranscriptIndex.nextRebuildDate(lastBuiltAt: built, unresolvedMissCounts: []),
            "nothing unresolved, nothing to walk"
        )
        XCTAssertEqual(
            CursorSubagentTranscriptIndex.nextRebuildDate(lastBuiltAt: nil, unresolvedMissCounts: [0]),
            .distantPast,
            "never walked: walk now"
        )
        XCTAssertEqual(
            CursorSubagentTranscriptIndex.nextRebuildDate(lastBuiltAt: built, unresolvedMissCounts: [2, 1]),
            built.addingTimeInterval(CursorSubagentTranscriptIndex.promptRecheckInterval),
            "a card still owed its prompt re-check"
        )
        XCTAssertEqual(
            CursorSubagentTranscriptIndex.nextRebuildDate(lastBuiltAt: built, unresolvedMissCounts: [2, 5]),
            built.addingTimeInterval(CursorSubagentTranscriptIndex.settledRefreshInterval),
            "only settled cards: slow refresh"
        )
    }
}
