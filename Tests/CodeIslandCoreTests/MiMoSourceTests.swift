import XCTest
@testable import CodeIslandCore

/// MiMo Code (`mimo` CLI) and the Xiaomi MiMo desktop app (#355) report as one
/// source, "mimo", through the OpenCode plugin CodeIsland installs into
/// `~/.config/mimocode/plugins/`.
final class MiMoSourceTests: XCTestCase {
    private let desktopMain = "/Applications/Xiaomi MiMo.app/Contents/MacOS/Xiaomi MiMo"
    private let overseasMain = "/Applications/Xiaomi MiMo AI.app/Contents/MacOS/Xiaomi MiMo AI"

    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    // MARK: - Source identity

    func testSpellingsOfBothProductsNormalizeToMimo() {
        for raw in ["mimo", "MiMo", " mimo ", "mimocode", "mimo-code", "MiMo Code", "mimo-cli",
                    "mimo-desktop", "xiaomi-mimo", "Xiaomi MiMo", "xiaomi-mimo-ai"] {
            XCTAssertEqual(SessionSnapshot.normalizedSupportedSource(raw), "mimo", raw)
        }
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("mimo"))
        XCTAssertFalse(SessionSnapshot.ideHostSources.contains("mimo"))
    }

    func testNoPrefixRuleClaimsOtherMiWords() {
        // "mimo" is too short a stem to own every word that starts with it.
        XCTAssertNil(SessionSnapshot.normalizedSupportedSource("mimosa"))
        XCTAssertNil(SessionSnapshot.normalizedSupportedSource("mimolive"))
    }

    func testLabelAndBuddySlot() {
        var session = SessionSnapshot()
        session.source = "mimo"
        XCTAssertEqual(session.sourceLabel, "MiMo")
        // Every firmware slot is taken; MiMo Code is an OpenCode fork.
        XCTAssertEqual(MascotID(sourceName: "mimo"), .opencode)
        XCTAssertEqual(MascotID(sourceName: "mimo-code"), .opencode)
    }

    // MARK: - Process matching

    func testCLIInstallsMatchTheMimoSource() {
        let paths = [
            "/Users/u/.mimocode/bin/mimo",                                              // curl installer
            "/opt/homebrew/lib/node_modules/@mimo-ai/cli/bin/.mimocode",                // npm postinstall cache
            "/opt/homebrew/lib/node_modules/@mimo-ai/mimocode-darwin-arm64/bin/mimo",  // npm platform package
            "/usr/local/bin/mimo",
        ]
        for path in paths {
            XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(path, source: "mimo"), path)
            XCTAssertEqual(CLIProcessResolver.inferSource(ancestry: [(1, path)]), "mimo", path)
        }
    }

    func testNearMissesDoNotMatch() {
        for path in [
            "/Users/u/project/mimosa",
            "/Users/u/.config/mimocode/bin/node",
            "/opt/homebrew/bin/node",                // the npm launcher's own process
            "/Users/u/somewhere/else/.mimocode",     // .mimocode outside @mimo-ai/cli
        ] {
            XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(path, source: "mimo"), path)
        }
    }

    /// The desktop app runs the engine in its main process and has its own
    /// terminal. Claiming the bundle would pin any agent started in that
    /// terminal on MiMo; the app reports itself through the plugin instead.
    func testDesktopBundleIsNeverInferredAsASource() {
        for main in [desktopMain, overseasMain] {
            XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(main, source: "mimo"))
            XCTAssertNil(CLIProcessResolver.inferSource(ancestry: [(10, main)]))
            XCTAssertTrue(CLIProcessResolver.isMimoDesktopBundlePath(main))
        }
        let claudeInMimoTerminal: [(pid: Int32, executablePath: String?)] = [
            (300, "/Users/u/.local/bin/claude"),
            (200, "/bin/zsh"),
            (100, desktopMain),
        ]
        XCTAssertEqual(CLIProcessResolver.inferSource(ancestry: claudeInMimoTerminal), "claude")
        XCTAssertFalse(CLIProcessResolver.isMimoDesktopBundlePath("/Users/u/.mimocode/bin/mimo"))
    }

    func testBridgeTracksTheMimoCLIAboveATransientShell() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (900, "/bin/sh"),
            (800, "/Users/u/.mimocode/bin/mimo"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.resolvedTrackedPID(immediateParentPID: 900, source: "mimo", ancestry: ancestry),
            800
        )
    }

    // MARK: - Desktop vs. terminal

    func testDesktopSessionIsNativeAppMode() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "mimo-ses_desk",
            "_source": "mimo",
            "_ppid": 4242,
            "cwd": "/Users/u/proj",
            "_env": ["__CFBundleIdentifier": "com.xiaomi.mimo.desktop"],
        ]), maxHistory: 20)

        let session = try XCTUnwrap(sessions["mimo-ses_desk"])
        XCTAssertEqual(session.source, "mimo")
        XCTAssertEqual(session.termBundleId, "com.xiaomi.mimo.desktop")
        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        XCTAssertEqual(session.terminalName, "Xiaomi MiMo")
        XCTAssertEqual(SessionSnapshot.sourceForAppBundleId("com.xiaomi.mimo.desktop-ai"), "mimo")
    }

    func testCLISessionInATerminalIsNotNativeAppMode() throws {
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: try hookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "mimo-ses_cli",
            "_source": "mimo",
            "_ppid": 5151,
            "cwd": "/Users/u/proj",
            "_env": ["TERM_PROGRAM": "iTerm.app", "__CFBundleIdentifier": "com.googlecode.iterm2"],
        ]), maxHistory: 20)

        let session = try XCTUnwrap(sessions["mimo-ses_cli"])
        XCTAssertFalse(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
    }

    /// Claude Code run in Xiaomi MiMo's integrated terminal keeps Claude's
    /// badge and is treated as an IDE terminal of the MiMo app.
    func testForeignCLIInsideMimoDesktopTerminal() throws {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.xiaomi.mimo.desktop"
        XCTAssertFalse(session.isNativeAppMode)
        XCTAssertTrue(session.isIDETerminal)
        XCTAssertTrue(session.isCLIHostedInForeignApp)
        XCTAssertEqual(session.terminalBadgeLabel, "Claude")
    }
}
