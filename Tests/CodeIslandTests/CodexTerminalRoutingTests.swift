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

    /// A Desktop card opens its own thread through Codex's link (#387).
    func testCodexDesktopJumpLinksToTheCardsThread() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.openai.codex"
        session.providerSessionId = "019a3f6e-1b2c-7d4e-8f90-123456789abc"

        XCTAssertEqual(TerminalActivator.codexDesktopThreadLink(for: session)?.absoluteString,
                       "codex://threads/019a3f6e-1b2c-7d4e-8f90-123456789abc")
    }

    /// No link is guessed: without a well-formed thread id, or for anything
    /// but a Desktop session, the jump raises the app as before.
    func testCodexDesktopJumpGuessesNoLink() {
        var desktop = SessionSnapshot()
        desktop.source = "codex"
        desktop.termBundleId = "com.openai.codex"
        XCTAssertNil(TerminalActivator.codexDesktopThreadLink(for: desktop))

        desktop.providerSessionId = "codexapp:019a3f6e-1b2c-7d4e-8f90-123456789abc"
        XCTAssertNil(TerminalActivator.codexDesktopThreadLink(for: desktop))
        desktop.providerSessionId = "../settings"
        XCTAssertNil(TerminalActivator.codexDesktopThreadLink(for: desktop))

        // Another agent run in Codex Desktop's terminal is not a Codex thread.
        var claude = SessionSnapshot()
        claude.source = "claude"
        claude.termBundleId = "com.openai.codex"
        claude.providerSessionId = "019a3f6e-1b2c-7d4e-8f90-123456789abc"
        XCTAssertNil(TerminalActivator.codexDesktopThreadLink(for: claude))

        // A Codex CLI in a terminal keeps its terminal jump.
        var cli = SessionSnapshot()
        cli.source = "codex"
        cli.termBundleId = "com.mitchellh.ghostty"
        cli.providerSessionId = "019a3f6e-1b2c-7d4e-8f90-123456789abc"
        XCTAssertNil(TerminalActivator.codexDesktopThreadLink(for: cli))
    }

    /// An ambiguous Codex tmux jump raises the session's terminal app only.
    func testAmbiguousJumpRaisesTheSessionsTerminalApp() {
        XCTAssertEqual(TerminalActivator.appLevelTerminalBundleId(
            termApp: "Ghostty", termBundleId: "com.googlecode.iterm2"), "com.googlecode.iterm2")
        XCTAssertEqual(TerminalActivator.appLevelTerminalBundleId(
            termApp: "ghostty", termBundleId: nil), "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalActivator.appLevelTerminalBundleId(
            termApp: "iTerm2", termBundleId: ""), "com.googlecode.iterm2")
        XCTAssertNil(TerminalActivator.appLevelTerminalBundleId(termApp: "Hyper", termBundleId: nil))
    }

    /// Buddy's focus button with no Codex card still raises Codex.app; only a
    /// session's own jump stopped falling back to it.
    func testSessionlessCallersStillFindTheCodexDesktopApp() {
        XCTAssertEqual(TerminalActivator.desktopAppBundleId(forSource: "codex"), "com.openai.codex")
        XCTAssertEqual(TerminalActivator.desktopAppBundleId(forSource: "trae"), "com.trae.app")
        XCTAssertNil(TerminalActivator.desktopAppBundleId(forSource: "claude"))
    }
}
