import XCTest
@testable import CodeIslandCore

final class ESP32ProtocolTests: XCTestCase {
    // MARK: - Source folding

    func testMascotIDFoldsAllCanonicalSources() {
        let pairs: [(String, MascotID)] = [
            ("claude", .claude), ("codex", .codex), ("gemini", .gemini),
            ("cursor", .cursor), ("copilot", .copilot),
            ("trae", .trae), ("traecn", .trae), ("traecli", .trae),
            ("qoder", .qoder),
            ("droid", .droid), ("factory", .droid),
            ("codebuddy", .codebuddy), ("codybuddycn", .codebuddy),
            ("stepfun", .stepfun), ("opencode", .opencode),
            ("qwen", .qwen), ("qwen-code", .qwen),
            ("antigravity", .antigravity), ("ag", .antigravity),
            ("workbuddy", .workbuddy), ("hermes", .hermes),
            ("kimi", .kimi),
        ]
        for (name, expected) in pairs {
            XCTAssertEqual(MascotID(sourceName: name), expected, "source=\(name)")
        }
    }

    func testMascotIDReturnsNilForUnknownSource() {
        XCTAssertNil(MascotID(sourceName: nil))
        XCTAssertNil(MascotID(sourceName: ""))
        XCTAssertNil(MascotID(sourceName: "not-a-real-agent"))
    }

    // MARK: - Status mapping

    func testStatusCodeMapping() {
        XCTAssertEqual(MascotStatusCode(.idle).rawValue, 0)
        XCTAssertEqual(MascotStatusCode(.processing).rawValue, 1)
        XCTAssertEqual(MascotStatusCode(.running).rawValue, 2)
        XCTAssertEqual(MascotStatusCode(.waitingApproval).rawValue, 3)
        XCTAssertEqual(MascotStatusCode(.waitingQuestion).rawValue, 4)
    }

    // MARK: - Frame encoding

    func testEncodeMinimalFrameHasThreeBytes() {
        let frame = MascotFramePayload(mascot: .copilot, status: .waitingApproval)
        let data = frame.encode()
        XCTAssertEqual(Array(data), [4, 3, 0])
    }

    func testEncodeWithShortToolName() {
        let frame = MascotFramePayload(mascot: .claude, status: .running, toolName: "Bash")
        let data = frame.encode()
        XCTAssertEqual(data[0], 0)
        XCTAssertEqual(data[1], 2)
        XCTAssertEqual(data[2], 4)
        XCTAssertEqual(data.count, 3 + 4)
        XCTAssertEqual(String(data: data.subdata(in: 3..<data.count), encoding: .utf8), "Bash")
    }

    func testEncodeTruncatesToolNameToSeventeenBytes() {
        let long = "ThisIsAVeryLongToolName_WayPast17Bytes"
        let frame = MascotFramePayload(mascot: .gemini, status: .processing, toolName: long)
        let data = frame.encode()
        XCTAssertLessThanOrEqual(data.count, ESP32Protocol.maxFrameBytes)
        XCTAssertEqual(data[2], UInt8(ESP32Protocol.maxToolNameBytes))
        XCTAssertEqual(data.count, 3 + ESP32Protocol.maxToolNameBytes)
        // First 17 bytes of the UTF-8 must match.
        let expected = Array(long.utf8.prefix(ESP32Protocol.maxToolNameBytes))
        XCTAssertEqual(Array(data.suffix(ESP32Protocol.maxToolNameBytes)), expected)
    }

    func testEncodeEmptyToolNameIsTreatedAsNone() {
        let frame = MascotFramePayload(mascot: .kimi, status: .idle, toolName: "")
        XCTAssertEqual(Array(frame.encode()), [15, 0, 0])
    }

    func testEncodeBrightnessConfigFrame() {
        let frame = BuddyBrightnessPayload(percent: UInt8(64))
        XCTAssertEqual(Array(frame.encode()), [ESP32Protocol.brightnessFrameMarker, 64])
    }

    func testBrightnessConfigClampsToSupportedRange() {
        XCTAssertEqual(BuddyBrightnessPayload(percent: 1.0).percent, ESP32Protocol.minBrightnessPercent)
        XCTAssertEqual(BuddyBrightnessPayload(percent: 150.0).percent, ESP32Protocol.maxBrightnessPercent)
        XCTAssertEqual(BuddyBrightnessPayload(percent: Double.nan).percent, ESP32Protocol.defaultBrightnessPercent)
    }

    func testEncodeScreenOrientationConfigFrame() {
        XCTAssertEqual(
            Array(BuddyScreenOrientationPayload(orientation: .up).encode()),
            [ESP32Protocol.orientationFrameMarker, 0]
        )
        XCTAssertEqual(
            Array(BuddyScreenOrientationPayload(orientation: .down).encode()),
            [ESP32Protocol.orientationFrameMarker, 1]
        )
    }

    func testEncodeWorkspaceFrame() {
        let frame = BuddyWorkspacePayload(workspaceName: "CodeIsland")
        let data = frame.encode()
        XCTAssertEqual(data[0], ESP32Protocol.workspaceFrameMarker)
        XCTAssertEqual(data[1], 10)
        XCTAssertEqual(String(data: data.subdata(in: 2..<data.count), encoding: .utf8), "CodeIsland")
    }

    func testEncodeMessagePreviewFrame() {
        let frame = BuddyMessagePreviewPayload(index: 1, total: 3, isUser: true, text: "Need help")
        let data = frame.encode()
        XCTAssertEqual(data[0], ESP32Protocol.messagePreviewFrameMarker)
        XCTAssertEqual(data[1], 1)
        XCTAssertEqual(data[2], 3)
        XCTAssertEqual(data[3] & 0x80, 0x80)
        XCTAssertEqual(data[3] & 0x7F, 9)
        XCTAssertEqual(String(data: data.subdata(in: 4..<data.count), encoding: .utf8), "Need help")
    }

    func testMessagePreviewPayloadPreservesBoundarySpacesInsideSegment() {
        let frame = BuddyMessagePreviewPayload(index: 0, total: 2, isUser: false, text: "generated ")

        XCTAssertEqual(frame.text, "generated ")
        XCTAssertEqual(String(data: frame.encode().subdata(in: 4..<frame.encode().count), encoding: .utf8), "generated ")
    }

    func testScreenOrientationDefaultsToUpForUnknownValues() {
        XCTAssertEqual(BuddyScreenOrientation(settingsValue: "down"), .down)
        XCTAssertEqual(BuddyScreenOrientation(settingsValue: "sideways"), .up)
        XCTAssertEqual(BuddyScreenOrientation(wireValue: 1), .down)
        XCTAssertEqual(BuddyScreenOrientation(wireValue: 7), .up)
    }

    func testConvenienceInitFromSourceString() {
        let frame = MascotFramePayload(source: "factory", status: .running, toolName: "Edit")
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.mascot, .droid)
        XCTAssertEqual(frame?.status, .running)
    }

    func testConvenienceInitReturnsNilForUnknownSource() {
        XCTAssertNil(MascotFramePayload(source: "bogus", status: .idle))
    }

    func testBuddyUplinkEventParsesControlCommands() {
        XCTAssertEqual(BuddyUplinkEvent(payload: Data([0xF0])), .command(.approveCurrentPermission))
        XCTAssertEqual(BuddyUplinkEvent(payload: Data([0xF1])), .command(.denyCurrentPermission))
        XCTAssertEqual(BuddyUplinkEvent(payload: Data([0xF2])), .command(.skipCurrentQuestion))
    }

    // MARK: - All 16 × 5 round-trip sanity

    func testAllMascotStatusCombinationsEncodeWithinLimits() {
        for mascot in MascotID.allCases {
            for statusRaw: UInt8 in 0...4 {
                let status = MascotStatusCode(rawValue: statusRaw)!
                let data = MascotFramePayload(mascot: mascot, status: status, toolName: "abc").encode()
                XCTAssertEqual(data[0], mascot.rawValue)
                XCTAssertEqual(data[1], statusRaw)
                XCTAssertEqual(data[2], 3)
                XCTAssertEqual(data.count, 6)
            }
        }
    }
}
