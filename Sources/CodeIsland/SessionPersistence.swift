import Foundation
import CodeIslandCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let sessionTitle: String?
    let sessionTitleSource: SessionTitleSource?
    let providerSessionId: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let termApp: String?
    let itermSessionId: String?
    let ttyPath: String?
    let kittyWindowId: String?
    let tmuxPane: String?
    let tmuxClientTty: String?
    let tmuxEnv: String?
    let termBundleId: String?
    // Multiplexer / fork pane hints — preserved across launches so precise jump-back
    // (cmux focus-panel / zellij go-to-tab / wezterm activate-pane) keeps working
    // after an app restart instead of degrading to cwd/tty fallback.
    let cmuxSurfaceId: String?
    let cmuxWorkspaceId: String?
    let zellijPaneId: String?
    let zellijSessionName: String?
    let weztermPaneId: String?
    let herdrPaneId: String?
    let herdrSocketPath: String?
    let herdrBinaryPath: String?
    let cliPid: Int32?
    let cliStartTime: Date?
    let startTime: Date
    let lastActivity: Date
    /// Absolute JSONL path for session fold and transcript tailing.
    let transcriptPath: String?
    /// Closed subagent ids in insertion order (newest last). Legacy files may
    /// still hold a lexicographically sorted list from the pre-cap `Set.sorted()`
    /// encoder — restore keeps all entries (no fake-recency trim).
    let closedSubagentIds: [String]?
    /// The agent's checklist, so a relaunch mid-plan keeps showing progress
    /// before the transcript backfill finishes. nil when empty (and in files
    /// written before the field existed).
    var agentTasks: AgentTaskList? = nil
    // Session recap + reasoning effort. Defaulted so older files (and call
    // sites) without them keep decoding/compiling; restore is re-checked
    // against the transcript by the attach-time backfill.
    var recap: SessionRecap? = nil
    var reasoningEffort: String? = nil
    /// Claude Desktop Code-tab session id, so a restored card still opens its
    /// exact session. Defaulted like the fields above for older files.
    var claudeDesktopSessionId: String? = nil
    /// A Hermes gateway chat (see `SessionSnapshot.hermesChatElsewhere`): its
    /// restored card is bound to the gateway daemon again and must still be
    /// swept like a hook-only one. nil = false, as in older files.
    var hermesChatElsewhere: Bool? = nil
}

enum SessionPersistence {
    static let dirPath = directory(
        environment: ProcessInfo.processInfo.environment,
        isRunningTests: RuntimeEnvironment.isRunningTests
    )
    private static let filePath = dirPath + "/sessions.json"

    /// Where sessions.json lives: `~/.codeisland`, unless `CODEISLAND_SESSIONS_DIR`
    /// names another folder (as `CODEISLAND_SOCKET_PATH` does for the socket).
    /// A test process defaults to a folder of its own under the temp dir: a
    /// test's AppState used to overwrite the user's real session list from its
    /// 2 s save timer, and `startSessionDiscovery` restored it into the test and
    /// then deleted it.
    static func directory(
        environment: [String: String],
        isRunningTests: Bool,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let override = environment["CODEISLAND_SESSIONS_DIR"], !override.isEmpty {
            return override
        }
        if isRunningTests {
            return (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("codeisland-tests-\(getpid())")
        }
        return home + "/.codeisland"
    }

    /// Whether a card is written out for the next launch. Not a remote one,
    /// and not a Claude Desktop Cowork card: those are rebuilt from Claude
    /// Desktop's own store and vouched for by it at launch, and a CodeIsland
    /// that cannot read the store (an older build after a downgrade) would
    /// bring one back as a ghost Claude Code session.
    static func isPersisted(sessionId: String, session: SessionSnapshot) -> Bool {
        !session.isRemote && !sessionId.hasPrefix(AppState.coworkSessionPrefix)
    }

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.compactMap { (id, s) in
            guard isPersisted(sessionId: id, session: s) else { return nil }
            return PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                sessionTitle: s.sessionTitle,
                sessionTitleSource: s.sessionTitleSource,
                providerSessionId: s.providerSessionId,
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                termApp: s.termApp,
                itermSessionId: s.itermSessionId,
                ttyPath: s.ttyPath,
                kittyWindowId: s.kittyWindowId,
                tmuxPane: s.tmuxPane,
                tmuxClientTty: s.tmuxClientTty,
                tmuxEnv: s.tmuxEnv,
                termBundleId: s.termBundleId,
                cmuxSurfaceId: s.cmuxSurfaceId,
                cmuxWorkspaceId: s.cmuxWorkspaceId,
                zellijPaneId: s.zellijPaneId,
                zellijSessionName: s.zellijSessionName,
                weztermPaneId: s.weztermPaneId,
                herdrPaneId: s.herdrPaneId,
                herdrSocketPath: s.herdrSocketPath,
                herdrBinaryPath: s.herdrBinaryPath,
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity,
                transcriptPath: s.transcriptPath,
                closedSubagentIds: s.closedSubagentIds.isEmpty ? nil : s.closedSubagentIds,
                agentTasks: s.agentTasks.isEmpty ? nil : s.agentTasks,
                recap: s.recap,
                reasoningEffort: s.reasoningEffort,
                claudeDesktopSessionId: s.claudeDesktopSessionId,
                hermesChatElsewhere: s.hermesChatElsewhere ? true : nil
            )
        }
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: URL(fileURLWithPath: filePath), options: Data.WritingOptions.atomic)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        return decode(data)
    }

    /// Decode a sessions file entry by entry: one this build cannot read (a
    /// newer version's field values after a downgrade, a hand edit) costs that
    /// session, not every session in the file.
    static func decode(_ data: Data) -> [PersistedSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([LossyPersistedSession].self, from: data)) ?? []
        return entries.compactMap(\.session)
    }

    private struct LossyPersistedSession: Decodable {
        let session: PersistedSession?

        init(from decoder: Decoder) throws {
            session = try? PersistedSession(from: decoder)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
