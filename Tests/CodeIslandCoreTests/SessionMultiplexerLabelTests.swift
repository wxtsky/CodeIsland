import XCTest
@testable import CodeIslandCore

final class SessionMultiplexerLabelTests: XCTestCase {
    /// A CLI running under tmux inside iTerm2: the terminal is still iTerm2,
    /// but the multiplexer layered on top of it must surface separately.
    func testTmuxInsideATerminalIsReportedAsAMultiplexer() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.googlecode.iterm2"
        snapshot.tmuxEnv = "/private/tmp/tmux-501/default,27935,0"
        snapshot.tmuxPane = "%11"

        XCTAssertEqual(snapshot.multiplexerLabel, "tmux")
        XCTAssertEqual(snapshot.terminalName, "iTerm2", "the chip augments the terminal name, it never replaces it")
    }

    func testZellijIsReportedAsAMultiplexer() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.googlecode.iterm2"
        snapshot.zellijSessionName = "main"
        snapshot.zellijPaneId = "3"

        XCTAssertEqual(snapshot.multiplexerLabel, "zellij")
    }

    /// Nested multiplexers both leave their env vars behind. The innermost one
    /// is the layer the CLI actually sits in, so that is the one to name.
    func testNestedMultiplexersReportTheInnermostLayer() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.googlecode.iterm2"
        snapshot.tmuxEnv = "/private/tmp/tmux-501/default,27935,0"
        snapshot.zellijPaneId = "3"

        XCTAssertEqual(snapshot.multiplexerLabel, "zellij")
    }

    /// cmux is the terminal itself, already named by terminalName. Reporting it
    /// again as a multiplexer would render the same word twice on one badge.
    func testCmuxIsNotReportedAsAMultiplexerBecauseItIsTheTerminal() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.cmux.app"
        snapshot.cmuxSurfaceId = "6C6E3F2A-0B2E-4F1D-9C55-7A0E2D4B8A31"

        XCTAssertEqual(snapshot.terminalName, "cmux")
        XCTAssertNil(snapshot.multiplexerLabel)
    }

    func testAPlainTerminalSessionHasNoMultiplexer() {
        var snapshot = SessionSnapshot()
        snapshot.termBundleId = "com.googlecode.iterm2"

        XCTAssertNil(snapshot.multiplexerLabel)
    }
}
