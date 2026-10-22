import XCTest
@testable import CodeIsland

final class ClaudeTranscriptFilesTests: XCTestCase {
    func testListsJsonlTranscriptsWithTheMtimesAStatWouldReport() throws {
        let dir = NSTemporaryDirectory() + "claude-transcript-files-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        for (name, age) in [("a.jsonl", 300.0), ("b.jsonl", 10.0), ("notes.txt", 0.0)] {
            let path = "\(dir)/\(name)"
            try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        }
        try fm.createDirectory(atPath: "\(dir)/subdir.jsonl.d", withIntermediateDirectories: true)

        let files = try XCTUnwrap(AppState.claudeTranscriptFiles(in: dir, fm: fm))

        XCTAssertEqual(Set(files.map(\.name)), ["a.jsonl", "b.jsonl"])
        for file in files {
            let stat = try fm.attributesOfItem(atPath: "\(dir)/\(file.name)")[.modificationDate] as? Date
            XCTAssertEqual(file.modified, stat, file.name)
        }
    }

    func testFollowsASymlinkedProjectDirLikeThePerFileStat() throws {
        let root = NSTemporaryDirectory() + "claude-transcript-files-" + UUID().uuidString
        let fm = FileManager.default
        let real = "\(root)/real"
        try fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        try "{}\n".write(toFile: "\(real)/a.jsonl", atomically: true, encoding: .utf8)
        // A transcript that is itself a symlink reports its own mtime, not its target's.
        let target = "\(root)/elsewhere.jsonl"
        try "{}\n".write(toFile: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: target)
        try fm.createSymbolicLink(atPath: "\(real)/b.jsonl", withDestinationPath: target)
        // The project dir itself symlinked (say, history kept across a moved checkout).
        let linked = "\(root)/linked"
        try fm.createSymbolicLink(atPath: linked, withDestinationPath: real)

        let files = try XCTUnwrap(
            AppState.claudeTranscriptFiles(in: linked, fm: fm),
            "contentsOfDirectory(atPath:), which this replaced, follows a symlinked dir"
        )

        XCTAssertEqual(Set(files.map(\.name)), ["a.jsonl", "b.jsonl"])
        for file in files {
            let stat = try fm.attributesOfItem(atPath: "\(linked)/\(file.name)")[.modificationDate] as? Date
            XCTAssertEqual(file.modified, stat, file.name)
        }
    }

    func testMissingProjectDirIsNil() {
        XCTAssertNil(AppState.claudeTranscriptFiles(in: "/nonexistent-\(UUID().uuidString)", fm: .default))
    }
}
