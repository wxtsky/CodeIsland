import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class CodexTerminalRoutingTests: XCTestCase {
    func testGhosttyTmuxCodexDoesNotUseDesktopFallback() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.mitchellh.ghostty"
        session.termApp = "tmux"
        session.tmuxPane = "%14"
        session.tmuxEnv = "/tmp/tmux-test/default,123,0"
        session.tmuxClientTty = "/dev/ttys000"

        XCTAssertFalse(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        // activate() consults this mapping before reaching activateTmux().
        // A desktop entry here steals the jump when Codex.app is running.
        XCTAssertNil(TerminalActivator.sourceToNativeAppBundleId[session.source])
        XCTAssertTrue(TerminalActivator.knownTerminals.contains {
            $0.bundleId == session.termBundleId
        })
    }

    func testCodexWithoutTerminalMetadataDoesNotGuessDesktopHost() {
        // Missing terminal metadata is not evidence that this is a desktop run.
        XCTAssertNil(TerminalActivator.sourceToNativeAppBundleId["codex"])
    }

    func testExplicitCodexDesktopSessionRemainsNativeAppMode() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.openai.codex"

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
    }
}
