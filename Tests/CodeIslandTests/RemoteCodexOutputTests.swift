import Foundation
import XCTest

final class RemoteCodexOutputTests: XCTestCase {
    private var hookPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeIsland/Resources/codeisland-remote-hook.py")
            .path
    }

    private func scan(_ records: [[String: Any]]) throws -> [String: Any] {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }

        let data = try records.map { record -> Data in
            var line = try JSONSerialization.data(withJSONObject: record)
            line.append(0x0A)
            return line
        }.reduce(into: Data()) { $0.append($1) }
        try data.write(to: transcript)

        let runner = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("codeisland_remote_hook", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        print(json.dumps(module._scan_codex_jsonl(sys.argv[2])))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", runner, hookPath, transcript.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
    }

    func testRemoteCodexScanReturnsOnlyCurrentTurnPublicOutput() throws {
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Inspect it"]],
            ["type": "response_item", "payload": [
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": "Private summary"]],
                "content": [["type": "text", "text": "Private reasoning"]],
                "encrypted_content": "ciphertext",
            ]],
            ["type": "response_item", "payload": [
                "type": "function_call_output",
                "output": "Private tool output",
            ]],
            ["type": "response_item", "payload": [
                "type": "agent_message",
                "message": "Private delegation message",
                "author": "/root",
                "recipient": "/root/worker",
                "content": [["type": "input_text", "text": "Private delegation"]],
            ]],
            ["type": "event_msg", "payload": [
                "type": "agent_message",
                "message": "Checking the affected call sites now.",
            ]],
        ]

        let result = try scan(records)

        XCTAssertEqual(result["last_assistant_message"] as? String, "Checking the affected call sites now.")
        XCTAssertFalse(String(describing: result).contains("Private"))
    }

    func testRemoteCodexScanDoesNotReusePreviousTurnOutput() throws {
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Old task"]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Old answer"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "New task"]],
        ]

        XCTAssertTrue(try scan(records).isEmpty)
    }

    func testRemoteCodexScanUsesNewestUserBoundaryAcrossRecordShapes() throws {
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Old task"]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Old answer"]],
            ["type": "response_item", "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "New task"]],
            ]],
        ]

        XCTAssertTrue(try scan(records).isEmpty)
    }
}
