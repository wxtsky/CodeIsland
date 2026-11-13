import Foundation
import CodeIslandCore

/// A session a discovery scan found running, as AppState integrates it into
/// the cards (`AppState.integrateDiscovered`).
struct DiscoveredSession {
    let sessionId: String
    let cwd: String
    let tty: String?
    let model: String?
    let pid: pid_t?
    let modifiedAt: Date
    let recentMessages: [ChatMessage]
    var source: String = "claude"
    /// Absolute path to the JSONL transcript this session was discovered from.
    /// When non-nil and the session is still live, AppState registers a JSONLTailer
    /// so incremental assistant appends reach the UI without another full scan.
    var transcriptPath: String? = nil
    var parentSessionId: String? = nil
    var subagentStatus: String? = nil
    var agentType: String? = nil
    var agentNickname: String? = nil
    /// Optional status inferred by a provider-specific discovery path.
    var status: AgentStatus? = nil
    /// Native host bundle when discovery represents an app session.
    var termBundleId: String? = nil
    /// Provider's raw thread ID when the tracking key uses a namespace prefix.
    var providerSessionId: String? = nil
}

/// Session discovery: finds the agent sessions already running on this Mac,
/// from the process table and each agent's own session store, for sessions
/// whose hooks were missed or that started before CodeIsland. Every read
/// here is synchronous disk or process-table I/O, callable from any thread;
/// discovery scans run it off the main actor, and AppState integrates what
/// they find (`integrateDiscovered`).
///
/// Each agent family's scanner and transcript readers live in its own
/// namespace (`ClaudeDiscovery`, `CodexDiscovery`, …). This one holds the
/// scan over every enabled source, the roots the discovery watcher follows,
/// the reads made for one known session (its model, a native app's finished
/// turn) and the transcript helpers the families share.
enum SessionDiscovery {
    static func readModelForSession(sessionId: String, session: SessionSnapshot) -> String? {
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return nil }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { ProcessTable.liveProcessIdentity(for: $0)?.startTime }

        switch source {
        case "claude":
            return ClaudeDiscovery.readModelFromTranscript(sessionId: sessionId, cwd: session.cwd)
        case "qoder", "qoder-cli":
            // ~/.qoder for the international build, ~/.qoder-cn for 国行 (#289).
            return FlatStoreDiscovery.qoderConfigRoots.lazy.compactMap { root in
                readModelFromProjectTranscript(
                    sessionId: sessionId,
                    cwd: session.cwd,
                    basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/\(root)/projects",
                    projectEncoder: { $0.claudeProjectDirEncoded() },
                    reader: ClaudeDiscovery.readRecentFromTranscript(path:)
                )
            }.first

        case "droid":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.factory/sessions",
                projectEncoder: { $0.claudeProjectDirEncoded() },
                reader: FlatStoreDiscovery.readRecentFromFactoryTranscript(path:)
            )
        case "codebuddy":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.codebuddy/projects",
                projectEncoder: { $0.appProjectDirEncoded() },
                reader: FlatStoreDiscovery.readRecentFromCodeBuddyTranscript(path:)
            )
        case "codex":
            return CodexDiscovery.readModelFromCodexStore(cwd: session.cwd, processStart: processStart)
        case "gemini":
            return GeminiDiscovery.readModelFromGeminiStore(cwd: session.cwd, processStart: processStart)
        case "cursor", "cursor-cli":
            return CursorDiscovery.readModelFromCursorStore(cwd: session.cwd, processStart: processStart)
        case "copilot":
            return CopilotDiscovery.readModelFromCopilotStore(cwd: session.cwd, processStart: processStart)
        case "opencode":
            return OpenCodeDiscovery.readModelFromOpenCodeStore(cwd: session.cwd, processStart: processStart)
        case "mimo":
            // The plugin keys cards `mimo-<store session id>`. Read that row:
            // the desktop holds several conversations per folder, and a
            // subagent's card is a child row the cwd match skips.
            return OpenCodeDiscovery.readModelFromOpenCodeStore(
                cwd: session.cwd, processStart: processStart,
                dbPath: OpenCodeDiscovery.mimoDatabasePath(), rootSessionsOnly: true,
                storeSessionId: sessionId.hasPrefix("mimo-") ? String(sessionId.dropFirst("mimo-".count)) : nil
            )
        case "grok":
            return GrokDiscovery.readModelFromGrokStore(cwd: session.cwd, processStart: processStart)
        case "kiro":
            return KiroDiscovery.readModelFromKiroStore(cwd: session.cwd, processStart: processStart)
        default:
            return nil
        }
    }

    private static func readModelFromProjectTranscript(
        sessionId: String,
        cwd: String?,
        basePath: String,
        projectEncoder: (String) -> String,
        reader: (String) -> (String?, [ChatMessage])
    ) -> String? {
        guard let cwd else { return nil }
        let path = "\(basePath)/\(projectEncoder(cwd))/\(sessionId).jsonl"
        return reader(path).0
    }

    static func nativeAppFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        switch session.source {
        case "codex":
            return CodexDiscovery.codexLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "qoder", "qoder-cli":
            return FlatStoreDiscovery.qoderLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "codebuddy":
            return FlatStoreDiscovery.codeBuddyLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        default:
            return nil
        }
    }

    static func findDiscoveredSessions() -> [DiscoveredSession] {
        let candidatePids = ProcessTable.allProcessIds()
        var discovered: [DiscoveredSession] = []
        if ConfigInstaller.isEnabled(source: "claude") {
            discovered.append(contentsOf: ClaudeDiscovery.findActiveClaudeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codex") {
            discovered.append(contentsOf: CodexDiscovery.findActiveCodexSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "gemini") {
            discovered.append(contentsOf: GeminiDiscovery.findActiveGeminiSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "qoder") {
            discovered.append(contentsOf: FlatStoreDiscovery.findActiveQoderSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codebuddy") {
            discovered.append(contentsOf: FlatStoreDiscovery.findActiveCodeBuddySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "droid") {
            discovered.append(contentsOf: FlatStoreDiscovery.findActiveFactorySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "cursor") {
            discovered.append(contentsOf: CursorDiscovery.findActiveCursorSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "copilot") {
            discovered.append(contentsOf: CopilotDiscovery.findActiveCopilotSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "opencode") {
            discovered.append(contentsOf: OpenCodeDiscovery.findActiveOpenCodeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "mimo") {
            discovered.append(contentsOf: OpenCodeDiscovery.findActiveMimoSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "kimi") {
            discovered.append(contentsOf: KimiDiscovery.findActiveKimiSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "grok") {
            discovered.append(contentsOf: GrokDiscovery.findActiveGrokSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "cline") {
            discovered.append(contentsOf: ClineDiscovery.findActiveClineSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "kiro") {
            discovered.append(contentsOf: KiroDiscovery.findActiveKiroSessions(candidatePids: candidatePids))
        }
        return discovered
    }

    static func discoveryWatchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String)] = [
            ("claude", ClaudeConfigPaths.projectsDir()),
            ("codex", "\(home)/.codex/sessions"),
            // $CODEX_HOME when CodeIsland itself was launched with one; the
            // same path as above otherwise (duplicates are dropped below).
            ("codex", "\(ConfigInstaller.codexHome())/sessions"),
            ("gemini", "\(home)/.gemini/tmp"),
            ("qoder", "\(home)/.qoder/projects"),
            ("codebuddy", "\(home)/.codebuddy/projects"),
            ("droid", "\(home)/.factory/sessions"),
            ("cursor", "\(home)/.cursor/projects"),
            ("copilot", "\(home)/.copilot/session-state"),
            ("opencode", "\(home)/.local/share/opencode"),
            ("mimo", "\(home)/.local/share/mimocode"),
            ("kimi", "\(home)/.kimi-code/sessions"),
            ("kimi", "\(home)/.kimi/sessions"),
            ("grok", "\(ConfigInstaller.grokHome())/sessions"),
            ("kiro", "\(home)/.kiro/sessions"),
            ("kiro", "\(home)/.kiro/session-leases"),
        ] + CustomAgentCommandStore.activeConfigDirs(forAgent: "claude").map { ("claude", "\($0)/projects") }
        let fm = FileManager.default
        // By identity: an extra dir that is a primary one under another
        // spelling (symlink, case) must not be watched twice.
        var seenRoots = Set<String>()
        var roots = (candidates + extraConfigDirWatchRoots()).compactMap { source, path -> String? in
            guard ConfigInstaller.isEnabled(source: source), fm.fileExists(atPath: path),
                  seenRoots.insert(ExtraConfigDirs.identity(of: path)).inserted else { return nil }
            return path
        }
        if ConfigInstaller.isEnabled(source: "cline") {
            let clineBase = ClineDiscovery.clineStorageRoot()
            for sub in ["state", "tasks"] {
                let p = "\(clineBase)/\(sub)"
                if fm.fileExists(atPath: p) { roots.append(p) }
            }
        }
        return roots
    }

    static func isSubagentWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-")
    }

    static func findMostRecentJSONLFile(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    static func readFirstLine(path: String, maxBytes: Int = 2_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var data = Data()
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(chunk[..<newline])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func firstStringRecursively(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let string = dict[key] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
            for child in dict.values {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        }
        return nil
    }

    static func extractTextContent(from rawContent: Any?) -> String? {
        if let text = rawContent as? String, !text.isEmpty {
            return text
        }
        if let items = rawContent as? [[String: Any]] {
            for item in items {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                if let output = item["output"] as? [String: Any],
                   let text = output["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    static func readTranscriptTail(path: String, maxBytes: UInt64 = 65536) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, maxBytes)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func parseISO8601Timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
