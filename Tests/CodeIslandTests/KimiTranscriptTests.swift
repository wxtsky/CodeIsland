import XCTest
@testable import CodeIsland

final class KimiTranscriptTests: XCTestCase {
    func testReadsKimiCodeWireProtocol() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        let lines = [
            #"{"type":"turn.prompt","input":[{"type":"text","text":"First question"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"ignore"}}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"First answer"}}}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"Second question"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Second "}}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"answer"}}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        // Reader keeps only the last 3 chat rows.
        XCTAssertEqual(messages.map(\.isUser), [false, true, false])
        XCTAssertEqual(messages.map(\.text), [
            "First answer",
            "Second question",
            "Second answer",
        ])
    }

    func testReadsLegacyKimiCliWireProtocol() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        let lines = [
            #"{"message":{"type":"TurnBegin","payload":{"user_input":[{"type":"text","text":"Legacy hi"}]}}}"#,
            #"{"message":{"type":"ContentPart","payload":{"type":"text","text":"Legacy bye"}}}"#,
            #"{"message":{"type":"TurnEnd"}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        XCTAssertEqual(messages.map(\.text), ["Legacy hi", "Legacy bye"])
        XCTAssertEqual(messages.map(\.isUser), [true, false])
    }

    /// Prefer turn.prompt when both exist; append-first must not duplicate the user line.
    func testKimiCodeWirePrefersTurnPromptOverPrecedingAppendMessage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        // Reverse of the usual order: append_message before turn.prompt.
        let lines = [
            #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"From append"}]}}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"From prompt"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Reply"}}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        XCTAssertEqual(messages.map(\.text), ["From prompt", "Reply"])
        XCTAssertEqual(messages.map(\.isUser), [true, false])
    }

    /// Normal order: turn.prompt first; append_message for the same turn is ignored.
    func testKimiCodeWireIgnoresAppendWhenTurnPromptAlreadyOpen() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        let lines = [
            #"{"type":"turn.prompt","input":[{"type":"text","text":"From prompt"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"From append"}]}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Reply"}}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        XCTAssertEqual(messages.map(\.text), ["From prompt", "Reply"])
        XCTAssertEqual(messages.map(\.isUser), [true, false])
    }

    /// Consecutive turn.prompt without assistant must still flush the first user line.
    func testKimiCodeWireConsecutiveTurnPromptsDoNotDropPriorUser() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        let lines = [
            #"{"type":"turn.prompt","input":[{"type":"text","text":"First"}],"origin":{"kind":"user"}}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"Second"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Answer"}}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        XCTAssertEqual(messages.map(\.text), ["First", "Second", "Answer"])
        XCTAssertEqual(messages.map(\.isUser), [true, true, false])
    }

    /// Empty turn.prompt after append_message must keep the append user text.
    func testKimiCodeWireEmptyTurnPromptDoesNotWipePrecedingAppend() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("wire.jsonl").path
        let lines = [
            #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"From append"}]}}"#,
            #"{"type":"turn.prompt","input":[],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Reply"}}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromKimiTranscript(path: path).1
        XCTAssertEqual(messages.map(\.text), ["From append", "Reply"])
        XCTAssertEqual(messages.map(\.isUser), [true, false])
    }
}
