import XCTest
@testable import CodeIslandCore

/// Mapping running CLI processes onto config roots during discovery: reading
/// their environment, paused roots, unknown environments and grouping.
final class ConfigRootDiscoveryTests: XCTestCase {
    private let home = "/Users/tester"
    private let keys: Set<String> = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME"]

    // MARK: - KERN_PROCARGS2 environment

    /// argc, exec path, padding, argv, then the environment strings.
    private func procArgs(argc: Int32, argv: [String], env: [String], terminate: Bool = true) -> [UInt8] {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: argc.littleEndian) { buffer.append(contentsOf: $0) }
        func cString(_ s: String) { buffer.append(contentsOf: Array(s.utf8)); buffer.append(0) }
        cString("/opt/homebrew/bin/codex")
        buffer.append(contentsOf: [0, 0])
        argv.forEach(cString)
        env.forEach(cString)
        if terminate { cString("") }
        return buffer
    }

    func testCompleteEnvironmentTellsUnsetFromUnknown() {
        let full = procArgs(argc: 2, argv: ["codex", "--yolo"], env: ["PATH=/usr/bin", "CODEX_HOME=/acct/codex"])
        XCTAssertEqual(ProcArgsParser.completeEnvironment(full, keys: keys), ["CODEX_HOME": "/acct/codex"])

        let unset = procArgs(argc: 1, argv: ["claude"], env: ["PATH=/usr/bin", "HOME=/Users/tester"])
        XCTAssertEqual(ProcArgsParser.completeEnvironment(unset, keys: keys), [:], "read in full, variable unset")

        // The kernel withheld the environment: nothing after argv.
        let withheld = procArgs(argc: 1, argv: ["claude"], env: [], terminate: false)
        XCTAssertNil(ProcArgsParser.completeEnvironment(withheld, keys: keys))
        XCTAssertEqual(ProcArgsParser.parse(withheld, environmentKeys: keys)?.environment, [:],
                       "the lenient parser reads that as 'unset' — why discovery must not use it")

        // argv shorter than argc: the environment was never reached.
        let shortArgv = procArgs(argc: 3, argv: ["codex"], env: [], terminate: false)
        XCTAssertNil(ProcArgsParser.completeEnvironment(shortArgv, keys: keys))

        // The last entry runs off the end of the buffer.
        var cut = procArgs(argc: 1, argv: ["grok"], env: ["PATH=/usr/bin"], terminate: false)
        cut.append(contentsOf: Array("GROK_HOME=/acct/gr".utf8))
        XCTAssertNil(ProcArgsParser.completeEnvironment(cut, keys: keys))

        XCTAssertNil(ProcArgsParser.completeEnvironment([1, 0], keys: keys))
    }

    /// Node rewrites its process title (pi's argv is just "pi"), leaving NULs
    /// where the original argv sat. The environment after that gap is still the
    /// environment; it must not read as withheld.
    func testCompleteEnvironmentSkipsTheGapARewrittenArgvLeaves() {
        var padded = procArgs(argc: 2, argv: ["pi", ""], env: [], terminate: false)
        padded.append(contentsOf: Array(repeating: 0, count: 16))
        func cString(_ s: String) { padded.append(contentsOf: Array(s.utf8)); padded.append(0) }
        cString("KITTY_LISTEN_ON=unix:/tmp/kitty-1")
        cString("PATH=/usr/bin")
        cString("")
        XCTAssertEqual(
            ProcArgsParser.completeEnvironment(padded, keys: ["KITTY_LISTEN_ON"]),
            ["KITTY_LISTEN_ON": "unix:/tmp/kitty-1"]
        )
    }

    // MARK: - Process root

    func testAVariableThatIsNotAnAbsolutePathIsUnknownNotUnset() {
        func root(_ value: String?) -> String? {
            ExtraConfigDirs.processRoot(
                cli: .codex,
                environment: value.map { ["CODEX_HOME": $0] } ?? [:],
                homeDir: home,
                defaultRoot: "/default"
            )
        }
        XCTAssertNil(root("relative/codex"), "resolved against the CLI's own cwd — unknown to us")
        XCTAssertNil(root("/"))
        XCTAssertEqual(root(nil), "/default")
        XCTAssertEqual(root(""), "/default")
        XCTAssertEqual(root("   "), "/default")
        XCTAssertEqual(root("~/.codex-work"), home + "/.codex-work")
    }

    // MARK: - Snapshot

    private func snapshot(
        _ registered: [ExtraConfigDir],
        primary: String = "/p",
        defaultRoot: String = "/d",
        identity: @escaping (String) -> String = { $0 }
    ) -> ConfigRootSnapshot {
        ConfigRootSnapshot(cli: .codex, primary: primary, defaultRoot: defaultRoot, registered: registered, identity: identity)
    }

    func testPausedRootsAreLeftOutOfDiscovery() {
        let snap = snapshot([
            ExtraConfigDir(cli: .codex, path: "/work"),
            ExtraConfigDir(cli: .codex, path: "/paused", enabled: false),
            ExtraConfigDir(cli: .grok, path: "/grok-paused", enabled: false),
        ])
        XCTAssertEqual(snap.lookup("/paused"), .paused)
        XCTAssertEqual(snap.lookup("/work"), .root("/work"))
        XCTAssertEqual(snap.lookup("/p"), .root("/p"))
        // Not registered at all: still discovered where it runs (see the
        // policy on ConfigRootSnapshot).
        XCTAssertEqual(snap.lookup("/unregistered"), .root("/unregistered"))
        XCTAssertEqual(snap.lookup("/grok-paused"), .root("/grok-paused"), "another CLI's registration")
        XCTAssertEqual(snap.lookup(nil), .unknown)
    }

    func testAPausedSpellingOfAnActiveRootIsNotPaused() {
        let identity: (String) -> String = { $0 == "/paused-link" ? "/p" : $0 }
        let snap = snapshot([ExtraConfigDir(cli: .codex, path: "/paused-link", enabled: false)], identity: identity)
        XCTAssertEqual(snap.lookup("/paused-link"), .root("/paused-link"), "it is the primary")
    }

    func testPausedIsMatchedByIdentity() {
        let identity: (String) -> String = { $0.lowercased() }
        let snap = snapshot([ExtraConfigDir(cli: .codex, path: "/Acct/Codex", enabled: false)], identity: identity)
        XCTAssertEqual(snap.lookup("/acct/codex"), .paused)
    }

    /// The fallback for an unreadable environment includes the CLI's default
    /// root even when CodeIsland itself runs with another CODEX_HOME — before
    /// extra roots, discovery always read ~/.codex.
    func testFallbackRootsIncludeTheDefaultAndSkipPausedOnes() {
        let snap = snapshot([
            ExtraConfigDir(cli: .codex, path: "/work"),
            ExtraConfigDir(cli: .codex, path: "/paused", enabled: false),
        ])
        XCTAssertEqual(snap.fallbackRoots, ["/p", "/d", "/work"])
        XCTAssertEqual(snapshot([], primary: "/d").fallbackRoots, ["/d"], "default == primary counted once")
        let pausedDefault = snapshot([ExtraConfigDir(cli: .codex, path: "/d", enabled: false)])
        XCTAssertEqual(pausedDefault.fallbackRoots, ["/p"], "a paused default root stays paused")
    }

    // MARK: - Running discovery

    private struct Proc: Equatable {
        let pid: Int32
        let root: ProcessConfigRoot
    }

    private struct Found: Equatable {
        let id: String
        let pid: Int32?
        let root: String
    }

    /// Every `discover` call: the root and the pids it was asked about.
    private final class CallLog {
        var calls: [(root: String, pids: [Int32])] = []
    }

    /// `sessions[root]` = session ids in that root, handed out in order to the
    /// processes of each `discover` call.
    private func run(
        _ processes: [Proc],
        fallback: [String],
        sessions: [String: [String]],
        identity: @escaping (String) -> String = { $0 },
        log: CallLog = CallLog()
    ) -> [Found] {
        ConfigRootDiscovery.run(
            processes: processes,
            lookup: \.root,
            fallbackRoots: fallback,
            identity: identity,
            discover: { root, group, claimed in
                log.calls.append((root, group.map(\.pid)))
                var available = (sessions[identity(root)] ?? []).filter { !claimed.contains($0) }
                return group.compactMap { process in
                    guard !available.isEmpty else { return nil }
                    return Found(id: available.removeFirst(), pid: process.pid, root: root)
                }
            },
            sessionId: \.id,
            belongsTo: { $0.pid == $1.pid }
        )
    }

    func testKnownProcessesStayInTheirOwnRootGroupedByIdentity() {
        let log = CallLog()
        let found = run(
            [Proc(pid: 1, root: .root("/work")), Proc(pid: 2, root: .root("/work-link")), Proc(pid: 3, root: .root("/p"))],
            fallback: ["/p", "/work"],
            sessions: ["/work": ["w1", "w2"], "/p": ["p1"]],
            identity: { $0 == "/work-link" ? "/work" : $0 },
            log: log
        )
        XCTAssertEqual(found.map(\.id), ["w1", "w2", "p1"])
        XCTAssertEqual(log.calls.map(\.root), ["/work", "/p"], "one pass per root, symlinked spelling merged")
        XCTAssertEqual(log.calls.first?.pids, [1, 2])
    }

    func testPausedProcessesAreSkipped() {
        let found = run(
            [Proc(pid: 1, root: .paused), Proc(pid: 2, root: .root("/p"))],
            fallback: ["/p"],
            sessions: ["/p": ["p1", "p2"]]
        )
        XCTAssertEqual(found, [Found(id: "p1", pid: 2, root: "/p")])
    }

    /// Before: an unknown pid joined every root's group — one card per root,
    /// and it could win a session a known pid of that root needed.
    func testAnUnknownProcessLandsInOneRootWithoutStealing() {
        let log = CallLog()
        let found = run(
            [Proc(pid: 9, root: .unknown), Proc(pid: 1, root: .root("/p"))],
            fallback: ["/p", "/work"],
            sessions: ["/p": ["p1"], "/work": ["w1"]],
            log: log
        )
        XCTAssertEqual(found, [
            Found(id: "p1", pid: 1, root: "/p"),
            Found(id: "w1", pid: 9, root: "/work"),
        ], "the known pid keeps p1; the unknown one falls through to the next root")
        XCTAssertEqual(log.calls.map(\.pids), [[1], [9], [9]])
    }

    func testAResolvedUnknownProcessIsNotTriedAgain() {
        let log = CallLog()
        let found = run(
            [Proc(pid: 9, root: .unknown), Proc(pid: 8, root: .unknown)],
            fallback: ["/p", "/p-link", "/work"],
            sessions: ["/p": ["p1"], "/work": ["w1", "w2"]],
            identity: { $0 == "/p-link" ? "/p" : $0 },
            log: log
        )
        XCTAssertEqual(found.map(\.id), ["p1", "w1"])
        XCTAssertEqual(found.map(\.pid), [9, 8])
        XCTAssertEqual(log.calls.map(\.root), ["/p", "/work"], "the same root under another spelling is not re-tried")
        XCTAssertEqual(log.calls.last?.pids, [8])
    }
}
