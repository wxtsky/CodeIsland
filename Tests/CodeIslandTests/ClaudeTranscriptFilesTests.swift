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

    func testMissingProjectDirIsNil() {
        XCTAssertNil(AppState.claudeTranscriptFiles(in: "/nonexistent-\(UUID().uuidString)", fm: .default))
    }
}
