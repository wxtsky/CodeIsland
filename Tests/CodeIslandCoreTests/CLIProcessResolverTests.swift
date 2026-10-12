import XCTest
@testable import CodeIslandCore

final class CLIProcessResolverTests: XCTestCase {

    // MARK: - resolvedSessionPID

    /// #148 core repro: Cursor IDE spawns N sub-agent processes, each runs
    /// its own hook subprocess with a different immediate ppid. All those
    /// sub-agents share the same root Cursor binary in their ancestry, so
    /// `resolvedSessionPID` must collapse them onto the same PID.
    func testParallelSubAgentsCollapseToRootSourcePID() {
        // Sub-agent #1 ancestry: hook → sub-agent A (12345) → cursor-agent main (5000)
        let subA: [(pid: Int32, executablePath: String?)] = [
            (12345, "/Users/u/.cursor/agent/sub-agent"),
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        // Sub-agent #2 ancestry: hook → sub-agent B (67890) → cursor-agent main (5000)
        let subB: [(pid: Int32, executablePath: String?)] = [
            (67890, "/Users/u/.cursor/agent/sub-agent"),
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]

        let pidA = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: subA
        )
        let pidB = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 67890, source: "cursor-cli", ancestry: subB
        )

        XCTAssertEqual(pidA, 5000)
        XCTAssertEqual(pidB, 5000, "Different sub-agent ppids must resolve to the same root cursor-agent PID for session grouping (#148)")
    }

    /// When multiple binaries of the same source appear in the ancestry,
    /// pick the *root-most* (last) one. Distinguishes resolvedSessionPID
    /// from resolvedTrackedPID, which picks the nearest (first).
    func testResolvedSessionPIDPicksRootMostMatch() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (1001, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // nearest
            (2002, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // intermediate
            (3003, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),  // root-most
        ]
        let session = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        let tracked = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(session, 3003, "session pid is the root-most matching binary")
        XCTAssertEqual(tracked, 1001, "tracked pid stays the nearest matching binary")
    }

    /// No binary in the ancestry matches the declared source — fall back
    /// to the immediate ppid (preserves prior behavior for everything but
    /// sub-agent CLIs).
    func testResolvedSessionPIDFallsBackToImmediateParentWhenNoMatch() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/bin/sh"),
            (5000, "/usr/bin/login"),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    /// Empty ancestry (e.g. proc lookup failed) — fall back to immediate ppid.
    func testResolvedSessionPIDFallsBackOnEmptyAncestry() {
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: []
        )
        XCTAssertEqual(pid, 12345)
    }

    /// nil source — nothing to match against, so return immediate ppid.
    func testResolvedSessionPIDFallsBackOnNilSource() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (12345, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: nil, ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    // MARK: - codexDesktopTermBundle

    /// The bundled Codex binary lives inside ChatGPT.app, so its own outermost
    /// bundle is com.openai.codex whoever started it.
    private func bundledCodex(_ arguments: [String]) -> ProcessAncestor {
        ProcessAncestor(
            pid: 900,
            executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            arguments: arguments,
            bundleIdentifier: "com.openai.codex"
        )
    }

    private let desktopArguments = ["codex", "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"]
    private let chatGPT = ProcessAncestor(
        pid: 800,
        executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        bundleIdentifier: "com.openai.codex"
    )
    private let zsh = ProcessAncestor(pid: 850, executablePath: "/bin/zsh", arguments: ["-zsh"])
    private let terminal = ProcessAncestor(
        pid: 700,
        executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        bundleIdentifier: "com.apple.Terminal"
    )

    /// ChatGPT starts Codex Desktop's app-server without __CFBundleIdentifier;
    /// its hooks, run directly or through `sh -c`, still belong to Desktop.
    func testDesktopAppServerHookGetsCodexDesktopBundle() {
        let hookShell = ProcessAncestor(pid: 950, executablePath: "/bin/sh", arguments: ["sh", "-c", "codeisland-bridge --source codex"])
        for ancestry in [
            [bundledCodex(desktopArguments), chatGPT],
            [hookShell, bundledCodex(desktopArguments), chatGPT],
            [bundledCodex(["codex", "app-server"]), chatGPT],
        ] {
            XCTAssertEqual(CLIProcessResolver.codexDesktopTermBundle(ancestry: ancestry), "com.openai.codex")
        }
    }

    func testAppServerLaunchedByBundledToolIsNotDesktopHost() {
        let broker = ProcessAncestor(
            pid: 850,
            executablePath: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
            arguments: ["node_repl"],
            bundleIdentifier: "com.openai.codex"
        )
        let chain = [bundledCodex(["codex", "app-server", "--listen", "stdio://"]), broker, chatGPT]
        XCTAssertNil(CLIProcessResolver.codexDesktopTermBundle(ancestry: chain))
        XCTAssertEqual(CLIProcessResolver.codexBundledProcessRole(ancestry: chain), .session)
    }

    /// The same binary also runs Codex CLI from a terminal (ChatGPT's
    /// `codex-cli/bin/codex` launcher), from ChatGPT's own terminal, where
    /// `exec codex` leaves ChatGPT as the direct parent, and as the app-server
    /// Claude Code's Codex plugin starts (#368).
    func testSameBinaryOutsideTheDesktopAppServerIsNotDesktop() {
        let pluginBroker = ProcessAncestor(
            pid: 850,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "app-server-broker.mjs", "serve"]
        )
        let cases: [(String, [ProcessAncestor])] = [
            ("terminal", [bundledCodex(["codex"]), zsh, terminal]),
            ("ChatGPT's terminal", [bundledCodex(["codex"]), zsh, chatGPT]),
            ("exec in ChatGPT's terminal", [bundledCodex(["codex"]), chatGPT]),
            ("Claude Code's Codex plugin", [bundledCodex(["codex", "app-server"]), pluginBroker]),
            ("parent unreadable", [bundledCodex(desktopArguments)]),
        ]
        for (name, ancestry) in cases {
            XCTAssertNil(CLIProcessResolver.codexDesktopTermBundle(ancestry: ancestry), name)
        }
    }

    /// Under ChatGPT (`exec codex …` in its own terminal), `app-server` only
    /// counts as the subcommand, after nothing but `-c key=value` overrides.
    func testAppServerAnywhereElseInTheArgumentsIsNotDesktop() {
        for arguments in [
            ["codex", "exec", "app-server"],
            ["codex", "--", "app-server"],
            ["codex", "-m", "app-server"],
            ["codex", "-c", "model=app-server"],
            [],
        ] {
            XCTAssertNil(
                CLIProcessResolver.codexDesktopTermBundle(ancestry: [bundledCodex(arguments), chatGPT]),
                arguments.joined(separator: " ")
            )
        }
    }

    /// `exec -a '' codex exec app-server` gives Codex an empty argv[0], which
    /// ProcArgsParser skips with the exec-path padding; the shifted arguments
    /// must not read as Desktop's `app-server`.
    func testEmptyArgvZeroDoesNotShiftIntoAppServer() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { buffer.append(contentsOf: $0) }
        func cString(_ s: String) { buffer.append(contentsOf: Array(s.utf8)); buffer.append(0) }
        cString("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        buffer.append(contentsOf: [0, 0, 0])                // exec-path padding
        cString(""); cString("exec"); cString("app-server")

        let arguments = ProcArgsParser.parse(buffer)?.arguments ?? []
        XCTAssertNil(CLIProcessResolver.codexDesktopTermBundle(ancestry: [bundledCodex(arguments), chatGPT]))
    }

    func testNoCodexProcessInAncestryIsNotDesktop() {
        XCTAssertNil(CLIProcessResolver.codexDesktopTermBundle(ancestry: [zsh, chatGPT]))
    }

    // MARK: - codexBundledProcessRole

    /// Discovery sees the bundled binary with its parent only. Desktop's
    /// app-server hosts the Desktop threads; ChatGPT's cloud `exec-server`
    /// (running from Resources) hosts none; the rest own their own rollouts.
    func testBundledCodexProcessRoles() {
        let pluginBroker = ProcessAncestor(
            pid: 850,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "app-server-broker.mjs", "serve"]
        )
        let execServer = ["codex", "-c", #"forced_login_method="chatgpt""#, "exec-server", "--remote", "https://example.invalid"]
        let cases: [(String, [ProcessAncestor], CodexProcessRole?)] = [
            ("Desktop app-server", [bundledCodex(desktopArguments), chatGPT], .desktopHost),
            ("ChatGPT's exec-server", [bundledCodex(execServer), chatGPT], nil),
            ("login", [bundledCodex(["codex", "login"]), zsh], nil),
            ("terminal TUI", [bundledCodex(["codex"]), zsh], .session),
            ("terminal TUI with a prompt", [bundledCodex(["codex", "fix the exec-server bug"]), zsh], .session),
            ("codex exec", [bundledCodex(["codex", "exec", "summarise"]), zsh], .session),
            ("Claude Code's Codex plugin", [bundledCodex(["codex", "app-server"]), pluginBroker], .session),
            ("parent unreadable", [bundledCodex(desktopArguments)], .session),
            ("nothing", [], nil),
        ]
        for (name, ancestry, expected) in cases {
            XCTAssertEqual(CLIProcessResolver.codexBundledProcessRole(ancestry: ancestry), expected, name)
        }
    }

    // MARK: - inferSource (#220 / #95)

    /// #220: Claude Code launched inside Cursor's integrated terminal fires the
    /// source-less Claude hook. The real `claude` process is a Node binary (its
    /// path does NOT end in `/claude`), while Cursor's GUI host/helper processes
    /// carry `/cursor` in their path. inferSource must NOT greedily attribute the
    /// session to the desktop `cursor` source — it should return nil so the
    /// bridge falls back to the default "claude".
    func testInferSourceIgnoresCursorIDEHostForSourcelessClaude() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            // `claude` is really a Node script; argv0 is node, not .../claude.
            (4321, "/opt/homebrew/bin/node"),
            (4000, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
            (3000, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        XCTAssertNil(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "Cursor's GUI host must not be inferred as the `cursor` source (#220)"
        )
    }

    /// #95 guard: the omo/OpenCode plugin fires the source-less Claude hook from
    /// inside OpenCode. The real `opencode` binary IS in the ancestry, so
    /// inferSource must still recover "opencode" (the original reason this
    /// inference exists). The #220 fix must not regress this.
    func testInferSourceStillRecoversOpenCodeFromAncestry() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (1234, "/bin/sh"),
            (5678, "/Users/u/.opencode/bin/opencode"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "opencode",
            "Source-less Claude hooks fired from inside OpenCode must still resolve to opencode (#95)"
        )
    }

    /// Cursor's CLI agent (`cursor-agent`) is a real CLI and must still be
    /// recovered as `cursor-cli` — only the desktop IDE *host* is excluded.
    func testInferSourceStillRecoversCursorCliAgent() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.inferSource(ancestry: ancestry),
            "cursor-cli"
        )
    }

    // MARK: - resolvedSessionPID

    /// Defensive: invalid (<= 0) immediate ppid is returned unchanged so
    /// callers can still encode it without contortion.
    func testResolvedSessionPIDReturnsImmediateParentWhenZeroOrNegative() {
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (5000, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: 0, source: "cursor-cli", ancestry: ancestry),
            0
        )
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: -1, source: "cursor-cli", ancestry: ancestry),
            -1
        )
    }
}
