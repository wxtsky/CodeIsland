import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class PixelCritterTests: XCTestCase {
    private var sandbox: DefaultsSandbox!

    override func setUp() {
        super.setUp()
        sandbox = DefaultsSandbox(keys: [SettingsKey.mascotStyle, SettingsKey.mascotSpeed])
        // Speed "Off": every mascot renders one fixed frame, so two renders
        // of the same mascot are pixel-identical.
        UserDefaults.standard.set(0, forKey: SettingsKey.mascotSpeed)
    }

    override func tearDown() {
        sandbox.restore()
        super.tearDown()
    }

    func testStatusPicksThePoseWhenThereIsNoOutcome() {
        let expected: [(MascotAgentStatus, PixelCritterView.Pose)] = [
            (.idle, .idle), (.processing, .thinking), (.running, .running),
            (.waitingApproval, .approval), (.waitingQuestion, .question),
        ]
        for (status, pose) in expected {
            XCTAssertEqual(PixelCritterView.pose(status: status, outcome: nil), pose, "\(status)")
        }
    }

    func testAnOutcomeWinsOverTheStatus() {
        for status in [MascotAgentStatus.idle, .processing, .running, .waitingApproval, .waitingQuestion] {
            XCTAssertEqual(PixelCritterView.pose(status: status, outcome: .done), .done)
            XCTAssertEqual(PixelCritterView.pose(status: status, outcome: .error), .error)
        }
    }

    func testClassicIsTheDefaultAndDrawsNoCritter() {
        XCTAssertEqual(MascotStyle(setting: SettingsDefaults.mascotStyle), .classic)
        XCTAssertEqual(MascotStyle(setting: "something-else"), .classic)
        XCTAssertNil(MascotStyle.classic.critter(codex: false))
        XCTAssertNil(MascotStyle.classic.critter(codex: true))
        XCTAssertEqual(MascotStyle.critter.critter(codex: false), .clawd)
        XCTAssertEqual(MascotStyle.critter.critter(codex: true), .dex)
    }

    func testByDefaultClaudeAndCodexDrawTheirClassicMascots() throws {
        _ = NSApplication.shared
        // Nothing stored: the setting reads as its default (registered or not).
        XCTAssertEqual(MascotStyle(setting: UserDefaults.standard.string(forKey: SettingsKey.mascotStyle)
                                   ?? SettingsDefaults.mascotStyle), .classic)
        try assertSame(MascotView(source: "claude", status: .running, size: 32),
                       ClawdView(status: .running, size: 32))
        try assertSame(MascotView(source: "codex", status: .waitingApproval, size: 32),
                       DexView(status: .waitingApproval, size: 32))
        // Outcomes are only for the critter.
        try assertSame(MascotView(source: "claude", status: .idle, size: 32, outcome: .error),
                       ClawdView(status: .idle, size: 32))
    }

    func testPixelCritterReplacesClaudeAndCodexOnly() throws {
        _ = NSApplication.shared
        UserDefaults.standard.set(MascotStyle.critter.rawValue, forKey: SettingsKey.mascotStyle)
        try assertSame(MascotView(source: "claude", status: .running, size: 32),
                       PixelCritterView(status: .running, size: 32, style: .clawd))
        try assertSame(MascotView(source: "codex", status: .idle, size: 32, outcome: .done),
                       PixelCritterView(status: .idle, outcome: .done, size: 32, style: .dex))
        try assertSame(MascotView(source: "gemini", status: .running, size: 32),
                       GeminiView(status: .running, size: 32))
        // The comparison can tell the two styles apart.
        XCTAssertNotEqual(try pixels(MascotView(source: "claude", status: .running, size: 32)),
                          try pixels(ClawdView(status: .running, size: 32)))
    }

    private func pixels<V: View>(_ view: V) throws -> Data {
        let still = view.environment(\.mascotSpeed, 0).background(Color.black)
        let image = try XCTUnwrap(OffscreenRender.rasterize(still))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    private func assertSame<A: View, B: View>(_ a: A, _ b: B, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try pixels(a), try pixels(b), "renders differ", file: file, line: line)
    }
}
