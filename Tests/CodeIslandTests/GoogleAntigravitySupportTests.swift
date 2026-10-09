import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Locks in the wire-level pieces of Google Antigravity support (#215). Google
/// Antigravity is a Gemini-based IDE/CLI and a SEPARATE product from the existing
/// "antigravity" source (a Claude-Code fork reading .antigravity/settings.json).
/// These assertions guard the parts that don't need a live Antigravity install:
/// source recognition + aliasing (must NOT collide with the fork), the new
/// `.antigravityNamed` HookFormat, the Claude-style PascalCase event list, and the
/// named-config wrapper the installer writes to ~/.gemini/config/hooks.json.
final class GoogleAntigravitySupportTests: XCTestCase {

    // MARK: - Source recognition / aliasing (no collision with the Claude fork)

    func testGoogleAntigravityIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google-antigravity"), "google-antigravity")
    }

    func testGoogleAntigravityAliasesNormalizeToGoogleAntigravity() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("googleantigravity"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google antigravity"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-ide"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-cli"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("agy"), "google-antigravity")
        // Prefix-match path: any future "google-antigravity-*" sub-brand folds in.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google-antigravity-pro"), "google-antigravity")
    }

    func testExistingAntigravityForkAliasesStayPointedAtTheFork() {
        // CRITICAL: retargeting these would break existing AntiGravity-fork users.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity"), "antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("ag"), "antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("anti-gravity"), "antigravity")
        // A bare "antigravity-something" still resolves to the fork, NOT Google's.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-pro"), "antigravity")
    }

    func testGoogleAntigravityDisplayLabel() {
        var snapshot = SessionSnapshot()
        snapshot.source = "google-antigravity"
        XCTAssertEqual(snapshot.sourceLabel, "Google Antigravity")
    }

    // MARK: - EventNormalizer (Antigravity uses Claude-style PascalCase)

    func testAntigravityEventNamesPassThroughNormalizerUnchanged() {
        // Antigravity hooks.json uses PreToolUse/PostToolUse/Stop — already internal
        // names — so they must survive normalize() verbatim (NOT the Gemini
        // Before/After mapping, which targets settings.json, not hooks.json).
        XCTAssertEqual(EventNormalizer.normalize("PreToolUse"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("PostToolUse"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("Stop"), "Stop")
    }

    func testBeforeToolNormalizesToPermissionRequest() {
        XCTAssertEqual(EventNormalizer.normalize("BeforeTool"), "PermissionRequest")
    }

    // MARK: - HookFormat round-trip

    func testHookFormatAntigravityNamedRoundTripsThroughStorageValue() {
        XCTAssertEqual(HookFormat.antigravityNamed.storageValue, "antigravityNamed")
        XCTAssertEqual(HookFormat(storageValue: "antigravityNamed"), .antigravityNamed)
        XCTAssertEqual(HookFormat(storageValue: "antigravitynamed"), .antigravityNamed) // case-insensitive
    }

    // MARK: - Default events

    func testAntigravityDefaultEventsAreClaudeStylePascalCase() {
        let names = ConfigInstaller.defaultEvents(for: .antigravityNamed).map { $0.0 }
        XCTAssertEqual(names, ["PreToolUse", "PostToolUse", "Stop"])
    }

    // MARK: - Named-config writer (~/.gemini/config/hooks.json shape)

    func testAntigravityNamedWriterEmitsNamedConfigWrapperWithEventFlag() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("hooks.json").path
        let cli = CLIConfig(
            name: "Google Antigravity",
            source: "google-antigravity",
            configPath: configPath,
            configKey: "codeisland",
            format: .antigravityNamed,
            events: ConfigInstaller.defaultEvents(for: .antigravityNamed)
        )

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))

        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Outer object MUST be keyed by the named-config wrapper "codeisland"
        // (NOT a bare "hooks" key — Antigravity would not recognize that).
        let wrapper = try XCTUnwrap(root["codeisland"] as? [String: Any])
        XCTAssertNil(root["hooks"], "Antigravity must NOT use the bare hooks root key")

        // Tool events nest {matcher, hooks:[{type,command,timeout}]}; model events
        // (Stop / Pre|PostInvocation) are a DIRECT handler list. Antigravity
        // silently ignores a model event wrapped in `hooks`, which is how every
        // session ended up stuck on "thinking" — Stop never fired (#297).
        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(wrapper[event] as? [[String: Any]], "missing event \(event)")
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry["matcher"] as? String, "*")
            let hookList = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            let hook = try XCTUnwrap(hookList.first)
            XCTAssertEqual(hook["type"] as? String, "command")
            XCTAssertNotNil(hook["timeout"])
            let command = try XCTUnwrap(hook["command"] as? String)
            // stdin lacks hook_event_name, so the command MUST carry --event.
            XCTAssertTrue(command.contains("codeisland-bridge --source google-antigravity"))
            XCTAssertTrue(command.contains("--event \(event)"))
        }

        let stopEntries = try XCTUnwrap(wrapper["Stop"] as? [[String: Any]], "missing event Stop")
        let stopEntry = try XCTUnwrap(stopEntries.first)
        XCTAssertNil(stopEntry["hooks"], "Stop takes a direct handler, not a hooks array")
        XCTAssertNil(stopEntry["matcher"], "Stop ignores matcher; we must not emit one")
        XCTAssertEqual(stopEntry["type"] as? String, "command")
        XCTAssertNotNil(stopEntry["timeout"])
        let stopCommand = try XCTUnwrap(stopEntry["command"] as? String)
        XCTAssertTrue(stopCommand.contains("codeisland-bridge --source google-antigravity"))
        XCTAssertTrue(stopCommand.contains("--event Stop"))
    }

    /// A config written before #297 (Stop wrapped in a `hooks` array) must read
    /// as "needs repair" so verifyAndRepair rewrites it — `containsOurHook`
    /// accepts both shapes, so without the shape check it looked healthy forever.
    func testLegacyNestedStopEntryIsReportedAsNeedingRepair() throws {
        let legacy: [String: Any] = [
            "Stop": [[
                "hooks": [[
                    "type": "command",
                    "command": "\(NSHomeDirectory())/.codeisland/codeisland-bridge --source google-antigravity --event Stop",
                    "timeout": 5,
                ]],
            ]],
        ]
        XCTAssertTrue(ConfigInstaller.hasNestedAntigravityModelEvent(legacy))

        let fixed: [String: Any] = [
            "Stop": [[
                "type": "command",
                "command": "\(NSHomeDirectory())/.codeisland/codeisland-bridge --source google-antigravity --event Stop",
                "timeout": 5,
            ]],
        ]
        XCTAssertFalse(ConfigInstaller.hasNestedAntigravityModelEvent(fixed))
    }

    // MARK: - PreToolUse is observed, never held for an island card (#339)

    /// Antigravity ignores a hook's `allow` (it prompts natively anyway) and
    /// runs PreToolUse for every tool, so an island card here only stacked a
    /// second, useless approval in front of each call.
    func testGoogleAntigravityPreToolUseRoutesAsActivityNotPermission() async throws {
        let event = try makeAgyEvent(["hook_event_name": "PreToolUse", "_source": "google-antigravity"])
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .event)
    }

    func testGeminiTaggedPreToolUseFromAgyRoutesAsActivityNotPermission() async throws {
        // agy reading hooks wired with --source gemini names the event
        // PreToolUse on stdin; Gemini CLI itself never does.
        let event = try makeAgyEvent(["hook_event_name": "PreToolUse", "_source": "gemini"])
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .event)
    }

    func testGeminiCLIBeforeToolStillRoutesToPermission() async throws {
        let payload: [String: Any] = [
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-cli-sess",
            "_source": "gemini",
            "tool_name": "run_shell_command",
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .permission, "Gemini CLI's own approval hook keeps its card")
    }

    /// The whole Antigravity tool round trip leaves nothing to click: the call
    /// shows as running, and whatever the user answers in Antigravity, the next
    /// tool/model event moves the session on by itself.
    @MainActor
    func testAntigravityToolCallShowsRunningWithoutACardAndClearsOnTheNextEvent() throws {
        let appState = AppState()
        let sessionId = "agy-conv-339"

        appState.handleEvent(try makeAgyEvent([
            "hook_event_name": "PreToolUse",
            "_source": "google-antigravity",
            "conversationId": sessionId,
            "session_id": sessionId,
        ]))
        XCTAssertTrue(appState.permissionQueue.isEmpty, "no approval card for Antigravity")
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .running)
        XCTAssertEqual(appState.sessions[sessionId]?.currentTool, "run_command")
        XCTAssertEqual(appState.sessions[sessionId]?.toolDescription, "npm test")

        // Approved in Antigravity → the tool ran → PostToolUse.
        appState.handleEvent(try makeAgyEvent([
            "hook_event_name": "PostToolUse",
            "_source": "google-antigravity",
            "session_id": sessionId,
        ]))
        XCTAssertEqual(appState.sessions[sessionId]?.status, .processing)
        XCTAssertNil(appState.sessions[sessionId]?.currentTool)

        // A call denied in Antigravity never reaches PostToolUse; the turn's
        // Stop settles the session instead of leaving it on the tool.
        appState.handleEvent(try makeAgyEvent([
            "hook_event_name": "PreToolUse",
            "_source": "google-antigravity",
            "session_id": sessionId,
        ]))
        XCTAssertEqual(appState.sessions[sessionId]?.status, .running)
        let stop: [String: Any] = [
            "hook_event_name": "Stop",
            "_source": "google-antigravity",
            "session_id": sessionId,
            "fullyIdle": true,
        ]
        appState.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: stop))))
        XCTAssertEqual(appState.sessions[sessionId]?.status, .idle)
        XCTAssertNil(appState.sessions[sessionId]?.currentTool)
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    /// The hook no longer waits on the island, and a PreToolUse hook Antigravity
    /// has to kill counts as a denial — no day-long ceiling.
    func testAntigravityPreToolUseTimeoutIsNotABlockingCeiling() throws {
        let preToolUse = try XCTUnwrap(
            ConfigInstaller.defaultEvents(for: .antigravityNamed).first { $0.0 == "PreToolUse" }
        )
        XCTAssertLessThanOrEqual(preToolUse.1, 30)
        XCTAssertGreaterThanOrEqual(preToolUse.1, 10, "must outlast the bridge's own ~9s self-deadline")
    }

    // MARK: - Bridge stdout (the real binary, never the user's live socket)

    /// Antigravity denies the tool call when PreToolUse prints no decision, so
    /// the answer must be on stdout even when CodeIsland is not running.
    func testBridgeAnswersAskEvenWhenTheIslandIsNotRunning() throws {
        let bridge = try bridgeBinary()
        let socketPath = NSTemporaryDirectory() + "no-island-\(UUID().uuidString).sock"
        let result = try runBridge(bridge, args: ["--source", "google-antigravity", "--event", "PreToolUse"],
                                   env: ["CODEISLAND_SOCKET_PATH": socketPath])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, #"{"decision":"ask"}"#)

        let skipped = try runBridge(bridge, args: ["--source", "google-antigravity", "--event", "PreToolUse"],
                                    env: ["CODEISLAND_SOCKET_PATH": socketPath, "CODEISLAND_SKIP": "1"])
        XCTAssertEqual(skipped.stdout, #"{"decision":"ask"}"#, "CODEISLAND_SKIP must not refuse tools")

        let post = try runBridge(bridge, args: ["--source", "google-antigravity", "--event", "PostToolUse"],
                                 env: ["CODEISLAND_SOCKET_PATH": socketPath])
        XCTAssertEqual(post.stdout, "", "only PreToolUse owes Antigravity a decision")
    }

    /// With the island up, the event is still forwarded (so the notch shows the
    /// tool) but the bridge neither waits for a decision nor relays one: an
    /// island `allow` would be ignored by Antigravity anyway.
    func testBridgeForwardsWithoutWaitingOrRelayingAnIslandDecision() throws {
        let bridge = try bridgeBinary()
        let allow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        let server = try XCTUnwrap(OneShotUnixServer(reply: allow))

        let result = try runBridge(bridge, args: ["--source", "google-antigravity", "--event", "PreToolUse"],
                                   env: ["CODEISLAND_SOCKET_PATH": server.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, #"{"decision":"ask"}"#)

        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        let forwarded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: server.received) as? [String: Any]
        )
        XCTAssertEqual(forwarded["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(forwarded["session_id"] as? String, "agy-conv-bridge")
        XCTAssertEqual(forwarded["_source"] as? String, "google-antigravity")
    }

    func testAgyToolCallParsing() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "conversationId": "3ff64dc8-11bd-4f7e-9a97-495badd58069",
            "_source": "gemini",
            "toolCall": [
                "name": "run_command",
                "args": [
                    "CommandLine": "ls -la"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        XCTAssertEqual(event.toolName, "run_command")
        XCTAssertEqual(event.toolInput?["CommandLine"] as? String, "ls -la")
        XCTAssertEqual(event.toolDescription, "ls -la")
    }

    // MARK: - Helpers

    private func makeAgyEvent(_ overrides: [String: Any]) throws -> HookEvent {
        var payload: [String: Any] = [
            "conversationId": "agy-conv",
            "session_id": "agy-conv",
            "stepIdx": 4,
            "toolCall": ["name": "run_command", "args": ["CommandLine": "npm test"]],
        ]
        payload.merge(overrides) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func bridgeBinary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        return url
    }

    private func runBridge(
        _ bridge: URL,
        args: [String],
        env: [String: String]
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = bridge
        process.arguments = args
        // The bridge's debug log goes to a temp file, not the shared
        // /tmp/codeisland-bridge.log the user's real hooks write.
        let log = NSTemporaryDirectory() + "codeisland-bridge-test-\(getpid()).log"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: log) }
        process.environment = env.merging([
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_BRIDGE_LOG": log,
        ]) { current, _ in current }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let payload: [String: Any] = [
            "conversationId": "agy-conv-bridge",
            "stepIdx": 1,
            "toolCall": ["name": "run_command", "args": ["CommandLine": "npm test"]],
        ]
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// Minimal Unix-socket stand-in for HookServer: accepts one bridge connection,
/// reads the event to EOF, answers with `reply`, closes.
final class OneShotUnixServer {
    let path: String
    private let listener: Int32
    private let served = DispatchSemaphore(value: 0)
    private(set) var received = Data()

    init?(reply: Data) {
        // sun_path is 104 bytes; NSTemporaryDirectory() can be too long for it.
        path = "/tmp/ci-bridge-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { _ = strcpy(ptr, $0) }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            return nil
        }
        DispatchQueue.global().async { [self] in
            let client = accept(listener, nil, nil)
            if client >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while true {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[..<n])
                }
                received = data
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                close(client)
            }
            served.signal()
        }
    }

    func waitUntilServed(timeout: TimeInterval) -> Bool {
        served.wait(timeout: .now() + timeout) == .success
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

