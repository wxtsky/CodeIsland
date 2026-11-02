import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStatePermissionFlowTests: XCTestCase {
    private var savedCodexHome: String?
    private var savedSmartSuppress: Any?
    private var savedAutoExpandOnPermission: Any?

    override func setUp() {
        super.setUp()
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        savedAutoExpandOnPermission = UserDefaults.standard.object(forKey: SettingsKey.autoExpandOnPermission)
    }

    override func tearDown() {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        if let savedAutoExpandOnPermission {
            UserDefaults.standard.set(savedAutoExpandOnPermission, forKey: SettingsKey.autoExpandOnPermission)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.autoExpandOnPermission)
        }
        super.tearDown()
    }

    /// #292 — Smart Suppress only covers "the agent's own terminal is in front".
    /// Working in any other app still got the panel thrown in your face on every
    /// approval, so auto-expand is now its own switch.
    func testAutoExpandOffKeepsIslandCollapsedButLeavesTheRequestActionable() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-no-expand", toolName: "Bash")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .collapsed, "auto-expand off must not steal focus")
        XCTAssertEqual(appState.permissionQueue.count, 1, "the request still waits for a decision")
        XCTAssertEqual(appState.sessions["s-no-expand"]?.status, .waitingApproval)
        XCTAssertEqual(appState.activeSessionId, "s-no-expand")

        // Still resolvable — the card is one click away in the session list.
        appState.approvePermission(expectedSessionId: "s-no-expand")
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
    }

    func testAutoExpandOnStillOpensTheApprovalCard() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-expand", toolName: "Bash")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-expand"))
        appState.approvePermission(expectedSessionId: "s-expand")
        _ = try await awaitValue(of: responseTask)
    }

    func testSmartSuppressKeepsPendingSurfaceCollapsedWhenTerminalIsFrontmost() {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        appState.sessions["s-smart"] = session

        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: "s-smart") { _ in true })
        XCTAssertTrue(appState.shouldAutoOpenPendingSurface(for: "s-smart") { _ in false })
    }

    func testPendingSurfaceAutoOpensWhenSmartSuppressIsOff() {
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        appState.sessions["s-smart-off"] = session

        XCTAssertTrue(appState.shouldAutoOpenPendingSurface(for: "s-smart-off") { _ in true })
    }

    func testDismissPermissionSkipsAlreadyDismissedSessions() async throws {
        let appState = AppState()

        let eventA = try makePermissionRequestEvent(sessionId: "s1", toolName: "Bash")
        let eventB = try makePermissionRequestEvent(sessionId: "s2", toolName: "Read")

        let responseTaskA = await startHookRequest { appState.handlePermissionRequest(eventA, continuation: $0) }
        let responseTaskB = await startHookRequest { appState.handlePermissionRequest(eventB, continuation: $0) }

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s1"))

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s2"))
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 2)

        await assertStillPending(responseTaskA)
        await assertStillPending(responseTaskB)

        appState.handlePeerDisconnect(sessionId: "s1")
        appState.handlePeerDisconnect(sessionId: "s2")

        let responseA = try await awaitValue(of: responseTaskA)
        let responseB = try await awaitValue(of: responseTaskB)

        XCTAssertEqual(responseA, AppState.noDecisionAnswer)
        XCTAssertEqual(responseB, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testDismissSinglePermissionCollapsesAndKeepsPending() async throws {
        let appState = AppState()
        let sessionId = "s-single"
        let event = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Bash")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        await assertStillPending(responseTask)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(response, AppState.noDecisionAnswer)
    }

    func testDismissedSessionGetsShownAgainWhenNewPermissionArrivesAfterDrain() async throws {
        let appState = AppState()
        let sessionId = "s-reappear"

        let firstEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Edit")
        let firstResponseTask = await startHookRequest { appState.handlePermissionRequest(firstEvent, continuation: $0) }
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let firstResponse = try await awaitValue(of: firstResponseTask)
        XCTAssertEqual(firstResponse, AppState.noDecisionAnswer)
        XCTAssertEqual(appState.permissionQueue.count, 0)

        let secondEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Write")
        let secondResponseTask = await startHookRequest { appState.handlePermissionRequest(secondEvent, continuation: $0) }

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()

        let secondResponse = try await awaitValue(of: secondResponseTask)
        XCTAssertEqual(try extractPermissionBehavior(from: secondResponse), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testBuddyApproveCommandResolvesPendingPermission() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-buddy-approve", toolName: "Bash")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleBuddyControlCommand(.approveCurrentPermission)

        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testBuddyDenyCommandResolvesPendingPermission() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-buddy-deny", toolName: "Bash")

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleBuddyControlCommand(.denyCurrentPermission)

        let response = try await awaitValue(of: responseTask)
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPendingApprovalPreviewSplitsLongDescriptionAcrossMultipleWatchFrames() async throws {
        let appState = AppState()
        let sessionId = "s-buddy-preview"
        let description = "Allow npm run build --filter watch package and update generated artifacts before merge"
        let command = "npm run build --filter watch -- --mode production"
        let expectedDetail = "\(description)\nCommand:\n\(command)"
        let event = try makePermissionRequestEvent(
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: [
                "description": description,
                "command": command
            ]
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        let previews = appState.esp32MessagePreviewPayloads()
        XCTAssertGreaterThan(previews.count, 1)
        XCTAssertTrue(previews.allSatisfy { ($0.text ?? "").utf8.count <= ESP32Protocol.maxMessagePreviewBytes })
        XCTAssertEqual(previews.map(\.total).last, UInt8(previews.count))
        XCTAssertEqual(previews.compactMap(\.text).joined(), expectedDetail)

        appState.handlePeerDisconnect(sessionId: sessionId)
        _ = try await awaitValue(of: responseTask)
    }

    func testMessagePreviewStopsAtTheFramesTheBuddyCanNumber() {
        let appState = AppState()
        let limit = ESP32Protocol.maxMessagePreviewSegments
        let long = String(repeating: "abcdefghijklmnop", count: 64 * 1024)  // 1 MB
        let segments = appState.esp32MessagePreviewSegments(text: long)
        XCTAssertEqual(segments.count, limit)
        XCTAssertEqual(segments.joined(), String(long.prefix(limit * ESP32Protocol.maxMessagePreviewBytes)))

        // Characters too wide for one frame add two segments at once.
        let wide = String(repeating: "x👨‍👩‍👧‍👦", count: 400)
        XCTAssertEqual(appState.esp32MessagePreviewSegments(text: wide).count, limit)
    }

    func testInteractiveDeliveryKeyChangesWhenApprovalDescriptionChanges() {
        let appState = AppState()
        let first = appState.esp32MessagePreviewSegments(text: "Need approval for npm run build --filter watch")
        let second = appState.esp32MessagePreviewSegments(text: "Need approval for npm run build --filter watch and package")

        XCTAssertNotEqual(first.joined(separator: "|"), second.joined(separator: "|"))
    }

    func testCodexAlwaysAllowPersistsRuleWithoutUnsupportedUpdatedPermissions() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-always-allow",
            toolName: "Bash",
            toolInput: [
                "command": "php vendor/bin/phpstan analyse src tests --memory-limit=1G"
            ],
            source: "codex"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)

        let decision = try extractPermissionDecision(from: await awaitValue(of: responseTask))
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])

        let rules = try readCodeIslandRules(in: codexHome)
        XCTAssertTrue(rules.contains(#"pattern = ["php", "vendor/bin/phpstan", "analyse"]"#))
        XCTAssertTrue(rules.contains(#"decision = "allow""#))
    }

    func testCodexAlwaysAllowEscapesMultilineRuleArguments() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-multiline-rule",
            toolName: "Bash",
            toolInput: [
                "command": "node -e 'console.log(\"a\")\nconsole.log(\"b\")\r\n'"
            ],
            source: "codex"
        )

        let rules = CodexPermissionRules()
        XCTAssertTrue(rules.persistAlwaysAllowRule(for: event))

        let contents = try readCodeIslandRules(in: codexHome)
        XCTAssertTrue(contents.contains(#"pattern = ["node", "-e", "console.log(\"a\")\nconsole.log(\"b\")\r\n"]"#))
        XCTAssertFalse(contents.contains("console.log(\\\"a\\\")\nconsole.log(\\\"b\\\")\r\n"))
    }

    func testCodexAlwaysAllowMCPToolPersistsApprovalModeWithoutUnsupportedUpdatedPermissions() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try writeCodexConfig(
            """
            [mcp_servers.sh_wiki]
            command = "sh-wiki-mcp"

            """,
            in: codexHome
        )

        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-mcp-always",
            toolName: "mcp__sh_wiki__fetch_page",
            toolInput: ["page_id": "432458668"],
            source: "codex"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)

        let decision = try extractPermissionDecision(from: await awaitValue(of: responseTask))
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])

        let config = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("[mcp_servers.sh_wiki.tools.fetch_page]"))
        XCTAssertTrue(config.contains(#"approval_mode = "approve""#))
    }

    /// #224: "Always allow" for an MCP tool (`mcp__server__tool`) must emit a
    /// bare-tool-name rule with NO `ruleContent` specifier. Claude Code's MCP
    /// permission rules don't take a specifier; sending `ruleContent: "*"`
    /// assembles `mcp__server__tool(*)`, which never matches a real MCP call, so
    /// the rule silently fails to persist and the same approval re-prompts.
    func testAlwaysAllowMCPToolOmitsRuleSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-mcp-always",
            toolName: "mcp__sh_wiki__fetch_page",
            toolInput: ["page_id": "432458668"]
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await awaitValue(of: responseTask))
        XCTAssertEqual(rule["toolName"] as? String, "mcp__sh_wiki__fetch_page")
        XCTAssertNil(rule["ruleContent"], "MCP tool rules must not carry a specifier (#224)")
    }

    /// Non-MCP tools keep the wildcard specifier so "always allow" still applies
    /// to every future call of that tool. The #224 fix must not change them.
    func testAlwaysAllowNonMCPToolKeepsWildcardSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-bash-always",
            toolName: "Bash"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await awaitValue(of: responseTask))
        XCTAssertEqual(rule["toolName"] as? String, "Bash")
        XCTAssertEqual(rule["ruleContent"] as? String, "*")
    }

    /// #258: ZCode validates hook stdout with a STRICT schema — Claude's
    /// `updatedPermissions` would void the whole decision and ZCode would
    /// re-prompt in its own dialog. #380: its own `permissionUpdates` is saved
    /// to the project for good, more than the card's "this session", so
    /// "Always" sends the decision alone and the island holds the rest.
    func testZcodeAlwaysAllowSendsOnlyTheDecision() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-zcode-always",
            toolName: "Bash",
            toolInput: ["command": "npm run build"],
            source: "zcode"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)

        let decision = try extractPermissionDecision(from: await awaitValue(of: responseTask))
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])
        XCTAssertNil(decision["permissionUpdates"])
        XCTAssertEqual(appState.sessions["s-zcode-always"]?.alwaysAllowedTools, ["Bash"])
    }

    /// MiniMax Code reads a Claude-format plugin's `updatedPermissions` into
    /// its session rules, but matches a file tool's `ruleContent` as a path:
    /// `Read(*)` never matched, and the next read asked again. It gets the
    /// bare tool name, which covers every call.
    func testMiniMaxAlwaysAllowSendsABareToolRule() async throws {
        for tool in ["Read", "Bash", "mcp__docs__search"] {
            let appState = AppState()
            let event = try makePermissionRequestEvent(
                sessionId: "s-minimax-always",
                toolName: tool,
                toolInput: ["file_path": "/tmp/a.txt"],
                source: "minimax"
            )

            let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
            appState.approvePermission(always: true)

            let rule = try firstAlwaysAllowRule(from: await awaitValue(of: responseTask))
            XCTAssertEqual(rule["toolName"] as? String, tool)
            XCTAssertNil(rule["ruleContent"], tool)
            XCTAssertTrue(appState.sessions["s-minimax-always"]?.alwaysAllowedTools.isEmpty ?? true, "MiniMax keeps it itself")
        }
    }

    /// Plain (one-time) allow and deny for ZCode use the shared minimal shape,
    /// which is already strict-schema-valid — lock that in so a future refactor
    /// doesn't leak Claude-only keys into zcode responses.
    func testZcodeSingleAllowStaysMinimal() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-zcode-once",
            toolName: "Bash",
            source: "zcode"
        )

        let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission()

        let decision = try extractPermissionDecision(from: await awaitValue(of: responseTask))
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["permissionUpdates"])
        XCTAssertNil(decision["updatedPermissions"])
    }

    func testCodexAlwaysAllowDoesNotDuplicateExistingCodeIslandRule() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-dedupe",
            toolName: "Bash",
            toolInput: ["command": "npm run build -- --mode production"],
            source: "codex"
        )

        let rules = CodexPermissionRules()
        XCTAssertTrue(rules.persistAlwaysAllowRule(for: event))
        XCTAssertTrue(rules.persistAlwaysAllowRule(for: event))

        let contents = try readCodeIslandRules(in: codexHome)
        XCTAssertEqual(contents.components(separatedBy: #"pattern = ["npm", "run", "build"]"#).count - 1, 1)
    }

    func testCodexAlwaysAllowPersistsMCPToolForDeclaredServer() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let configURL = try writeCodexConfig(
            """
            [mcp_servers.github]
            command = "github-mcp-server"

            """,
            in: codexHome
        )

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-mcp-known",
            toolName: "mcp__github__get_me",
            source: "codex"
        )

        XCTAssertTrue(CodexPermissionRules().persistAlwaysAllowRule(for: event))

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[mcp_servers.github.tools.get_me]"))
        XCTAssertTrue(contents.contains(#"approval_mode = "approve""#))
    }

    /// A tools table under a server that declares no transport makes Codex reject
    /// the entire config.toml, which surfaces as unrelated settings failing to save.
    func testCodexAlwaysAllowLeavesConfigUntouchedForUndeclaredMCPServer() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let original = """
        [mcp_servers.github]
        command = "github-mcp-server"

        """
        let configURL = try writeCodexConfig(original, in: codexHome)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-mcp-unknown",
            toolName: "mcp__codex_app__send_message_to_thread",
            source: "codex"
        )

        XCTAssertFalse(CodexPermissionRules().persistAlwaysAllowRule(for: event))

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(contents, original)
        XCTAssertFalse(contents.contains("codex_app"))
    }

    func testConfigDeclaresMCPServerTransportRecognisesURLAndRejectsToolsOnlyTable() {
        let contents = """
        [mcp_servers.remote]
        url = "https://example.com/mcp"

        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        XCTAssertTrue(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "remote"))
        XCTAssertFalse(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "codex_app"))
        XCTAssertFalse(CodexPermissionRules.configDeclaresMCPServerTransport(contents, serverID: "absent"))
    }

    /// #316 — a hyphenated MCP server reaches us as `mcp__davinci_resolve__…`,
    /// because `__` is the tool-name separator. Writing that namespace verbatim
    /// created a second, transport-less table and Codex then refused to load the
    /// whole config; the approval must land under the declared key instead.
    func testCodexAlwaysAllowWritesUnderTheDeclaredHyphenatedServerKey() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let configURL = try writeCodexConfig(
            """
            [mcp_servers.davinci-resolve]
            command = "/opt/venv/bin/python"

            """,
            in: codexHome
        )

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-mcp-hyphen",
            toolName: "mcp__davinci_resolve__project_manager",
            source: "codex"
        )

        XCTAssertTrue(CodexPermissionRules().persistAlwaysAllowRule(for: event))

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[mcp_servers.davinci-resolve.tools.project_manager]"))
        XCTAssertFalse(contents.contains("[mcp_servers.davinci_resolve"),
                       "the underscore namespace must never become its own table")
    }

    func testDeclaredMCPServerIDPrefersAnExactMatchOverASanitisedOne() {
        let contents = """
        [mcp_servers.davinci_resolve]
        command = "exact"

        [mcp_servers.davinci-resolve]
        command = "hyphenated"
        """

        XCTAssertEqual(
            CodexPermissionRules.declaredMCPServerID(in: contents, forToolNamespace: "davinci_resolve"),
            "davinci_resolve"
        )
    }

    /// Two declared servers can sanitise to the same namespace. Guessing which
    /// one the user meant would grant a standing approval on the wrong server,
    /// so nothing is persisted and the call is approved for this session only.
    func testDeclaredMCPServerIDRefusesToGuessBetweenAmbiguousServers() {
        let contents = """
        [mcp_servers.davinci-resolve]
        command = "one"

        [mcp_servers."davinci resolve"]
        command = "two"
        """

        XCTAssertNil(CodexPermissionRules.declaredMCPServerID(in: contents, forToolNamespace: "davinci_resolve"))
    }

    func testDeclaredMCPServerIDIgnoresTransportlessTables() {
        let contents = """
        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        XCTAssertNil(CodexPermissionRules.declaredMCPServerID(in: contents, forToolNamespace: "codex_app"))
        XCTAssertEqual(CodexPermissionRules.declaredMCPServerIDs(in: contents), [])
    }

    // MARK: - #316 repair of already-broken configs

    func testRepairRepointsAnOrphanedApprovalAtTheDeclaredServer() throws {
        let contents = """
        [mcp_servers.davinci-resolve]
        command = "/opt/venv/bin/python"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.davinci_resolve.tools.project_manager]
        approval_mode = "approve"
        """

        let repaired = try XCTUnwrap(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
        XCTAssertTrue(repaired.contains("[mcp_servers.davinci-resolve.tools.project_manager]"))
        XCTAssertFalse(repaired.contains("[mcp_servers.davinci_resolve"))
        XCTAssertTrue(repaired.contains(#"approval_mode = "approve""#),
                      "re-pointing must keep the approval the user actually granted")
        XCTAssertTrue(repaired.contains(#"command = "/opt/venv/bin/python""#))
    }

    func testRepairDropsAnApprovalWithNoServerToRepointAt() throws {
        let contents = """
        [mcp_servers.github]
        command = "github-mcp-server"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        let repaired = try XCTUnwrap(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
        XCTAssertFalse(repaired.contains("codex_app"))
        XCTAssertFalse(repaired.contains(CodexPermissionRules.mcpToolApprovalComment),
                       "the stamp must go with the table it introduced")
        XCTAssertTrue(repaired.contains("[mcp_servers.github]"))
        XCTAssertTrue(repaired.contains(#"command = "github-mcp-server""#))
    }

    /// An approval the user typed themselves is theirs, however it is spelled.
    func testRepairLeavesUnstampedTablesAlone() {
        let contents = """
        [mcp_servers.codex_app.tools.send_message_to_thread]
        approval_mode = "approve"
        """

        XCTAssertNil(CodexPermissionRules.repairingOrphanedMCPToolTables(contents))
    }

    func testRepairLeavesAHealthyConfigUntouched() {
        let contents = """
        [mcp_servers.github]
        command = "github-mcp-server"

        \(CodexPermissionRules.mcpToolApprovalComment)
        [mcp_servers.github.tools.get_me]
        approval_mode = "approve"

        """

        XCTAssertNil(CodexPermissionRules.repairingOrphanedMCPToolTables(contents),
                     "a healthy file must never be rewritten")
    }

    // MARK: - Remote Codex "Always"

    /// A remote Codex runs under its own host's config and rules. "Always"
    /// on its card used to write a rule built from the remote command (or an
    /// MCP approval) into this Mac's CODEX_HOME — one this Mac's Codex then
    /// honoured.
    func testRemoteCodexAlwaysAllowWritesNothingUnderThisMacsCodexHome() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = try writeCodexConfig(
            """
            [mcp_servers.sh_wiki]
            command = "sh-wiki-mcp"

            """,
            in: codexHome
        )
        let configBefore = try String(contentsOf: config, encoding: .utf8)
        let appState = AppState()
        let requests: [(tool: String, input: [String: Any])] = [
            ("Bash", ["command": "git push --force origin main"]),
            ("mcp__sh_wiki__fetch_page", ["page_id": "432458668"]),
        ]

        for request in requests {
            let event = try makePermissionRequestEvent(
                sessionId: "s-remote-\(request.tool)",
                toolName: request.tool,
                toolInput: request.input,
                source: "codex",
                remoteHostId: "devbox"
            )
            XCTAssertTrue(CodexPermissionRules.isCodexEvent(event))
            XCTAssertFalse(CodexPermissionRules().persistAlwaysAllowRule(for: event), request.tool)

            let responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
            appState.approvePermission(always: true, expectedSessionId: event.sessionId)
            let decision = try extractPermissionDecision(from: await awaitValue(of: responseTask))
            XCTAssertEqual(decision["behavior"] as? String, "allow", request.tool)
            XCTAssertNil(decision["updatedPermissions"], request.tool)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: codeIslandRulesPath(in: codexHome).path),
            "no rule for this Mac's Codex"
        )
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), configBefore, "no MCP approval either")
    }

    /// What the card promised instead: this tool, for the rest of the
    /// session — and nothing more.
    func testRemoteCodexAlwaysAllowHoldsForTheRestOfItsSessionOnly() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let appState = AppState()
        func remoteRequest(_ sessionId: String, _ tool: String, _ command: String = "make test") throws -> HookEvent {
            try makePermissionRequestEvent(
                sessionId: sessionId,
                toolName: tool,
                toolInput: ["command": command],
                source: "codex",
                remoteHostId: "devbox"
            )
        }

        let first = try remoteRequest("s-remote", "Bash")
        let firstTask = await startHookRequest { appState.handlePermissionRequest(first, continuation: $0) }
        appState.approvePermission(always: true, expectedSessionId: first.sessionId)
        try await assertBehavior(of: firstTask, "allow")

        let again = try remoteRequest("s-remote", "Bash", "make lint")
        let againTask = await startHookRequest { appState.handlePermissionRequest(again, continuation: $0) }
        XCTAssertTrue(appState.permissionQueue.isEmpty, "the session's Always answers it, no card")
        try await assertBehavior(of: againTask, "allow")

        let otherTool = try remoteRequest("s-remote", "mcp__docs__search")
        let otherSession = try remoteRequest("s-remote-2", "Bash")
        let otherToolTask = await startHookRequest { appState.handlePermissionRequest(otherTool, continuation: $0) }
        let otherSessionTask = await startHookRequest { appState.handlePermissionRequest(otherSession, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 2, "another tool, or another session, still asks")
        appState.denyPermission(expectedSessionId: otherSession.sessionId)
        appState.denyPermission(expectedSessionId: otherTool.sessionId)
        try await assertBehavior(of: otherToolTask, "deny")
        try await assertBehavior(of: otherSessionTask, "deny")

        // A new session under the same id starts asking again.
        appState.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SessionStart", "session_id": "s-remote", "cwd": "/home/me/project",
            "transcript_path": "/home/me/.codex/sessions/rollout.jsonl",
            "_source": "codex", "_remote_host_id": "devbox",
        ]))))
        let afterRestart = try remoteRequest("s-remote", "Bash")
        let afterRestartTask = await startHookRequest { appState.handlePermissionRequest(afterRestart, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        appState.denyPermission(expectedSessionId: afterRestart.sessionId)
        try await assertBehavior(of: afterRestartTask, "deny")

        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome.path), "nothing written under CODEX_HOME")
    }

    /// #380: Codex loads ~/.codex/rules when a session starts and never
    /// again, so the rule "Always" saved reached only the sessions started
    /// after it; the one the user clicked in asked again for the same
    /// command. The island answers that session's covered commands itself.
    func testLocalCodexAlwaysAllowSavesARuleAndHoldsItForTheRunningSession() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-local-codex",
            toolName: "Bash",
            toolInput: ["command": "make test"],
            source: "codex"
        )
        XCTAssertTrue(CodexPermissionRules.alwaysSavesRule(for: event))

        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true, expectedSessionId: "s-local-codex")
        try await assertBehavior(of: task, "allow")
        XCTAssertTrue(try readCodeIslandRules(in: codexHome).contains(#"pattern = ["make", "test"]"#))

        let again = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertTrue(appState.permissionQueue.isEmpty, "the running session never reads the rule; the island holds it")
        try await assertBehavior(of: again, "allow")

        // Codex asks in another session only when it started before the
        // rule was saved: the user answers that card.
        let other = try makePermissionRequestEvent(
            sessionId: "s-local-codex-2",
            toolName: "Bash",
            toolInput: ["command": "make test"],
            source: "codex"
        )
        let otherTask = await startHookRequest { appState.handlePermissionRequest(other, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        appState.denyPermission(expectedSessionId: "s-local-codex-2")
        try await assertBehavior(of: otherTask, "deny")
    }

    func testCodexAutoReviewConfigDefersPermissionRequestToCodex() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "auto_review""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-auto-review",
            toolName: "Bash",
            source: "codex"
        )

        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexAutoReviewConfigDoesNotDeferAskUserQuestion() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "guardian_subagent""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-question",
            toolName: "AskUserQuestion",
            toolInput: ["question": "Continue?", "options": ["Yes", "No"]],
            source: "codex"
        )

        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexProfileAutoReviewConfigIsDetected() throws {
        let config = """
        profile = "work"
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertTrue(CodexPermissionRules.configEnablesAutoReview(config))
    }

    func testCodexUserReviewerConfigDoesNotDefer() throws {
        let config = """
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertFalse(CodexPermissionRules.configEnablesAutoReview(config))
    }

    // MARK: - Helpers

    private func makeTemporaryCodexHome() -> URL {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        return codexHome
    }

    private func codeIslandRulesPath(in codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("rules", isDirectory: true)
            .appendingPathComponent("codeisland.rules")
    }

    private func readCodeIslandRules(in codexHome: URL) throws -> String {
        try String(contentsOf: codeIslandRulesPath(in: codexHome), encoding: .utf8)
    }

    @discardableResult
    private func writeCodexConfig(_ contents: String, in codexHome: URL) throws -> URL {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let configURL = codexHome.appendingPathComponent("config.toml")
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    /// #309 — a dismissed request stays queued so the CLI stays blocked, which
    /// used to make `permissionQueue.count == 1` false forever and swallow every
    /// later request, from every session, with no card and no sound.
    func testDismissedPermissionDoesNotSilenceALaterSessionsRequest() async throws {
        let appState = AppState()
        let dismissed = try makePermissionRequestEvent(sessionId: "s-dismissed", toolName: "Bash")
        let later = try makePermissionRequestEvent(sessionId: "s-later", toolName: "Edit")

        let dismissedTask = await startHookRequest { appState.handlePermissionRequest(dismissed, continuation: $0) }
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-dismissed"))

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1, "dismiss must keep the request queued")

        let laterTask = await startHookRequest { appState.handlePermissionRequest(later, continuation: $0) }

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-later"),
            "a different session's approval must still raise a card while a dismissed one sits in the queue"
        )
        // Stop here on failure: under the bug, approvePermission() below resolves
        // the dismissed request instead, so the await on `laterTask` never
        // completes and the test would report a timeout rather than by name. The
        // head check matters as much as the surface one — an implementation that
        // points the card at this session by hand shows "s-later" while the
        // dismissed request still leads the queue, so the surface assertion
        // alone passes and the await still times out.
        XCTAssertEqual(
            appState.permissionQueue.first?.event.sessionId,
            "s-later",
            "the card on screen must be backed by the head of the queue, which is what approve resolves"
        )
        guard appState.surface == .approvalCard(sessionId: "s-later"),
              appState.permissionQueue.first?.event.sessionId == "s-later" else {
            appState.handlePeerDisconnect(sessionId: "s-dismissed")
            appState.handlePeerDisconnect(sessionId: "s-later")
            _ = try await awaitValue(of: dismissedTask)
            _ = try await awaitValue(of: laterTask)
            return
        }

        appState.approvePermission()
        let laterResponse = try await awaitValue(of: laterTask)
        XCTAssertEqual(try extractPermissionBehavior(from: laterResponse), "allow")

        await assertStillPending(dismissedTask)
        appState.handlePeerDisconnect(sessionId: "s-dismissed")
        _ = try await awaitValue(of: dismissedTask)
    }

    /// A dismissal is cleared by that session's NEXT request arriving
    /// (`handlePermissionRequest` removes it from `dismissedPermissionSessionIds`
    /// on entry — "session needs user decision again"), not by the dismissed
    /// request resolving. So the session's next request must bring its card back.
    ///
    /// This is also the state that silenced everything else: the un-dismiss makes
    /// the still-queued earlier request count as visible while nothing is on
    /// screen, so a queue-derived "is a card showing" proxy reads true forever.
    func testDismissedSessionsNextRequestReRaisesItsCard() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-same", toolName: "Bash")
        let second = try makePermissionRequestEvent(sessionId: "s-same", toolName: "Edit")

        let firstTask = await startHookRequest { appState.handlePermissionRequest(first, continuation: $0) }
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)

        let secondTask = await startHookRequest { appState.handlePermissionRequest(second, continuation: $0) }

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-same"),
            "the session un-dismissed itself by asking again, so its card must come back"
        )
        XCTAssertEqual(appState.permissionQueue.count, 2)
        // Pins queue order, not the promotion mechanism: the card renders the
        // head, so the user is asked about the earlier request rather than the
        // one that just arrived. Both requests here are from one session, so no
        // assertion at this level can tell showNextPending's promotion from a
        // hand-pointed surface — the cross-session test's head check is what
        // covers that.
        XCTAssertEqual(
            appState.pendingPermission?.event.toolName,
            "Bash",
            "the card must show the earlier queued request, not the one that just arrived"
        )

        appState.handlePeerDisconnect(sessionId: "s-same")
        _ = try await awaitValue(of: firstTask)
        _ = try await awaitValue(of: secondTask)
    }

    /// `drainPermissions` (process exit, or a question arriving for the session)
    /// empties the queue without clearing `surface`, and the card renders nothing
    /// when there is no head request. A gate that trusts `.approvalCard` alone
    /// would block on that phantom card and swallow the next request.
    func testRequestArrivingUnderAStaleApprovalSurfaceStillRaisesACard() async throws {
        let appState = AppState()

        // The phantom state itself: an .approvalCard surface with an empty queue.
        // Production reaches it through the drainPermissions callers that do not
        // touch `surface` (process exit; a question arriving for the session).
        // Set here directly because those callers are private.
        appState.surface = .approvalCard(sessionId: "s-gone")
        XCTAssertTrue(appState.permissionQueue.isEmpty)

        let next = try makePermissionRequestEvent(sessionId: "s-next", toolName: "Read")
        let nextTask = await startHookRequest { appState.handlePermissionRequest(next, continuation: $0) }

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-next"),
            "a phantom card must not block the next request from being shown"
        )

        appState.approvePermission()
        let response = try await awaitValue(of: nextTask)
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
    }

    /// The state F1 described: a dismissed session asking again must not leave
    /// the panel silent for everyone else.
    func testDismissedSessionAskingAgainDoesNotSilenceOtherSessions() async throws {
        let appState = AppState()
        let firstA = try makePermissionRequestEvent(sessionId: "s-a", toolName: "Bash")
        let secondA = try makePermissionRequestEvent(sessionId: "s-a", toolName: "Edit")
        let fromB = try makePermissionRequestEvent(sessionId: "s-b", toolName: "Read")

        let firstATask = await startHookRequest { appState.handlePermissionRequest(firstA, continuation: $0) }
        appState.dismissPermissionPrompt()

        let secondATask = await startHookRequest { appState.handlePermissionRequest(secondA, continuation: $0) }

        let fromBTask = await startHookRequest { appState.handlePermissionRequest(fromB, continuation: $0) }

        // The panel must be showing *something* — under the incomplete gate the
        // un-dismiss left A's card unopened and B arrived to a silent, collapsed
        // panel. (Without this the rest of the test passes either way, because
        // resolving A's requests surfaces B regardless.)
        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-a"),
            "A's card must be up — a silent collapsed panel is the bug, and it must be A's card since A's request leads the queue"
        )

        // B queues behind A's card rather than stealing it — but it must not be
        // lost: as A's requests clear, B's card has to come up.
        XCTAssertEqual(appState.permissionQueue.count, 3)
        appState.approvePermission()
        appState.approvePermission()
        _ = try await awaitValue(of: firstATask)
        _ = try await awaitValue(of: secondATask)

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-b"),
            "B's request must surface once A's are resolved, not sit silently forever"
        )
        appState.approvePermission()
        let bResponse = try await awaitValue(of: fromBTask)
        XCTAssertEqual(try extractPermissionBehavior(from: bResponse), "allow")
    }

    private func makePermissionRequestEvent(
        sessionId: String,
        toolName: String,
        toolInput: [String: Any] = ["command": "echo test"],
        source: String? = nil,
        remoteHostId: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": toolInput
        ]
        if let source {
            payload["_source"] = source
        }
        if let remoteHostId {
            payload["_remote_host_id"] = remoteHostId
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 1)
        }
        return event
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let decision = try extractPermissionDecision(from: responseData)
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func assertBehavior(
        of task: Task<Data, Never>,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let behavior = try extractPermissionBehavior(from: await awaitValue(of: task, file: file, line: line))
        XCTAssertEqual(behavior, expected, file: file, line: line)
    }

    private func extractPermissionDecision(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        return try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
    }

    private func firstAlwaysAllowRule(from responseData: Data) throws -> [String: Any] {
        let decision = try extractPermissionDecision(from: responseData)
        let updated = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let first = try XCTUnwrap(updated.first)
        let rules = try XCTUnwrap(first["rules"] as? [[String: Any]])
        return try XCTUnwrap(rules.first)
    }
}
