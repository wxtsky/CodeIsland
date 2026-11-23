import Foundation
import SQLite3
import CodeIslandCore

/// A thread's spawn edge in Codex's state database: its parent, the edge's
/// status and the thread's rollout.
struct CodexSpawnEdgeRecord {
    let metadata: CodexSubagentMetadata
    let status: String?
    let transcriptPath: String?
}

struct CodexDiscoveryIdentity: Equatable, Sendable {
    let sessionId: String
    let providerSessionId: String?
    let termBundleId: String?
}

struct CodexProcessDiscoveryCandidate: Sendable {
    let pid: pid_t
    let cwd: String?
    let startTime: Date?
    let isDesktop: Bool
}

enum CodexTranscriptOrigin: Equatable, Sendable {
    case desktop
    case cli
    case unknown
}

/// A Codex Desktop thread recovered from Codex's local state database.
///
/// Recent Codex Desktop builds run their app-server with `/` as the process CWD,
/// so the CLI discovery path cannot map that process back to a project. Keeping
/// this small value type separate lets discovery hydrate native-app sessions from
/// the authoritative state DB without exposing the private `DiscoveredSession`.
struct CodexDesktopThreadRecord: Sendable {
    let sessionId: String
    let cwd: String
    let model: String?
    let modifiedAt: Date
    let recentMessages: [ChatMessage]
    let transcriptPath: String
    let status: AgentStatus
    let subagentMetadata: CodexSubagentMetadata?
    let subagentStatus: String?
}

/// Codex sessions: CLI processes matched to rollouts under each Codex root's
/// `sessions/`, Codex Desktop threads from the state database
/// (`state_5.sqlite`), the subagent relations rollouts and spawn edges
/// record, and the rollout readers (recent messages, turn status, model).
enum CodexDiscovery {
    static func readModelFromCodexStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let fm = FileManager.default
        guard let path = SessionDiscovery.codexStateRoots().lazy.compactMap({
            findRecentCodexSession(base: "\($0)/sessions", cwd: cwd, after: processStart, fm: fm)
        }).first else {
            return nil
        }
        return readRecentFromCodexTranscript(path: path).0
    }

    static func codexLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        let effectiveSessionId: String
        if let providerSessionId = session.providerSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerSessionId.isEmpty {
            effectiveSessionId = providerSessionId
        } else {
            effectiveSessionId = sessionId
        }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { ProcessTable.liveProcessIdentity(for: $0)?.startTime }

        guard let transcriptPath = codexTranscriptPath(
            sessionId: effectiveSessionId,
            cwd: session.cwd,
            processStart: processStart
        ),
              let tail = SessionDiscovery.readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }

        return codexLatestTerminalTurnTimestamp(in: tail)
    }

    private static func codexTranscriptPath(
        sessionId: String,
        cwd: String?,
        processStart: Date?
    ) -> String? {
        // The thread may belong to any Codex root (CODEX_HOME / account).
        let roots = SessionDiscovery.codexStateRoots()
        for root in roots {
            let statePath = "\(root)/state_5.sqlite"

            if let path: String = SQLiteReader.withSQLiteDatabase(at: statePath, body: { db in
                guard let statement = SQLiteReader.prepareSQLiteStatement(
                    db: db,
                    sql: """
                        SELECT rollout_path
                        FROM threads
                        WHERE id = ?
                        LIMIT 1;
                        """
                ) else {
                    return nil
                }
                defer { sqlite3_finalize(statement) }

                SQLiteReader.bindSQLiteText(sessionId, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return SQLiteReader.sqliteColumnString(statement, index: 0)
            }),
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        guard let cwd else { return nil }
        return roots.lazy.compactMap {
            findRecentCodexSession(base: "\($0)/sessions", cwd: cwd, after: processStart, fm: .default)
        }.first
    }

    /// Codex Desktop's shared app-server is launched with `/` as its cwd. Its
    /// rollout metadata contains the project cwd, so desktop discovery must
    /// use that value instead of comparing every transcript to `/`.
    static func codexDiscoveryUsesTranscriptCwd(processCwd: String?) -> Bool {
        guard let processCwd, !processCwd.isEmpty else { return true }
        return processCwd == "/"
    }

    /// Codex Desktop currently invokes some hooks without a payload, or with
    /// the shared app-server's root cwd. Those events contain no session data
    /// and would overwrite a session discovered from its rollout transcript.
    static func isCodexPlaceholderHook(
        source: String?,
        cwd: String?,
        hasTranscriptPath: Bool
    ) -> Bool {
        guard source?.lowercased() == "codex", !hasTranscriptPath else { return false }
        return cwd == nil || cwd?.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
    }

    /// Keep all three Codex Desktop discovery channels on one stable tracking
    /// key while leaving CLI sessions in the provider's raw namespace.
    static func codexDiscoveryIdentity(
        rawSessionId: String,
        isDesktop: Bool
    ) -> CodexDiscoveryIdentity {
        if isDesktop {
            return CodexDiscoveryIdentity(
                sessionId: AppState.codexAppSessionPrefix + rawSessionId,
                providerSessionId: rawSessionId,
                termBundleId: AppState.codexAppBundleId
            )
        }
        return CodexDiscoveryIdentity(
            sessionId: rawSessionId,
            providerSessionId: nil,
            termBundleId: nil
        )
    }

    /// Upgrade old Desktop hook cards. Misclassified Aperitif hooks may only
    /// have Desktop provenance in the matching rollout's session metadata.
    static func canonicalRestoredCodexSessionId(
        sessionId: String,
        source: String,
        providerSessionId: String?,
        termBundleId: String?,
        transcriptPath: String? = nil
    ) -> String {
        guard source == "codex", !sessionId.hasPrefix(AppState.codexAppSessionPrefix) else { return sessionId }
        let rawId = providerSessionId?.isEmpty == false ? providerSessionId! : sessionId
        if termBundleId == AppState.codexAppBundleId {
            return AppState.codexAppSessionPrefix + rawId
        }
        guard termBundleId == nil || termBundleId == CLIProcessResolver.codexAperitifBundleIdentifier,
              let transcriptPath,
              codexTranscriptOrigin(path: transcriptPath, matchingSessionId: rawId) == .desktop else { return sessionId }
        return AppState.codexAppSessionPrefix + rawId
    }

    /// Read only the rollout's first `session_meta` row to distinguish Desktop
    /// rollouts from CLI rollouts when both exist under `~/.codex/sessions`.
    /// Unknown future shapes remain eligible for the owning process as a
    /// best-effort fallback instead of being dropped.
    static func codexTranscriptOrigin(path: String, matchingSessionId: String? = nil) -> CodexTranscriptOrigin {
        guard let firstLine = SessionDiscovery.readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else {
            return .unknown
        }
        if let matchingSessionId,
           json["type"] as? String != "session_meta" || payload["id"] as? String != matchingSessionId {
            return .unknown
        }

        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        if originator.contains("desktop") {
            return .desktop
        }
        // Codex records every app-server client under `vscode`/`appServer`,
        // and a spawned thread keeps its parent's originator under an object
        // source. A client that names itself something other than Desktop
        // (Claude Code's Codex plugin sends "Claude Code") runs its own
        // `codex app-server`, so the rollout belongs to that process like a
        // CLI one.
        let isAppServerSource = source == "vscode" || source == "appserver"
        let isSubagentSource = payload["source"] is [String: Any]
        if !originator.isEmpty, isAppServerSource || isSubagentSource {
            return .cli
        }
        if isAppServerSource {
            return .desktop
        }
        if originator.contains("cli") || source == "cli" || source == "exec" {
            return .cli
        }
        return .unknown
    }

    /// Scan a rollout backwards in chunks until the latest lifecycle marker is
    /// found. This avoids both a full-file read and a fixed-tail limit while
    /// reusing `JSONLTailer`'s canonical Codex event interpretation.
    static func latestCodexTurnStatus(
        path: String,
        chunkSize: UInt64 = 256 * 1024,
        maxBytesToScan: UInt64 = 64 * 1024 * 1024,
        maxLineBytes: Int = 4 * 1024 * 1024
    ) -> ConversationTurnStatus? {
        guard chunkSize > 0, maxBytesToScan > 0, maxLineBytes > 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let lowerBound = fileSize > maxBytesToScan ? fileSize - maxBytesToScan : 0
        var cursor = fileSize
        var leadingFragment = Data()
        var discardingOversizedLine = false

        while cursor > lowerBound {
            let readSize = min(cursor - lowerBound, chunkSize)
            cursor -= readSize
            handle.seek(toFileOffset: cursor)
            let chunk = handle.readData(ofLength: Int(readSize))
            var combined: Data
            if discardingOversizedLine {
                // We are walking backwards through one over-budget line. Drop
                // its bytes until the previous newline, then resume with older
                // complete lines instead of retaining/copying an unbounded blob.
                guard let newline = chunk.lastIndex(of: 0x0A) else { continue }
                combined = Data(chunk[...newline])
                discardingOversizedLine = false
            } else {
                combined = chunk
                combined.append(leadingFragment)
            }

            var lines: [Data] = []
            var lineStart = combined.startIndex
            for index in combined.indices where combined[index] == 0x0A {
                lines.append(Data(combined[lineStart..<index]))
                lineStart = combined.index(after: index)
            }
            lines.append(Data(combined[lineStart..<combined.endIndex]))
            if cursor > lowerBound, !lines.isEmpty {
                let fragment = lines.removeFirst()
                if fragment.count > maxLineBytes {
                    leadingFragment.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                } else {
                    leadingFragment = fragment
                }
            } else {
                leadingFragment.removeAll(keepingCapacity: true)
                // A capped scan begins in the middle of an unknown line. Never
                // parse that boundary fragment as if it were complete JSON.
                if lowerBound > 0, !lines.isEmpty {
                    lines.removeFirst()
                }
            }

            for line in lines.reversed()
            where !line.isEmpty && line.count <= maxLineBytes {
                if let status = codexTurnStatus(fromCompleteLine: line) {
                    return status
                }
            }
        }

        return nil
    }

    private static func codexTurnStatus(fromCompleteLine line: Data) -> ConversationTurnStatus? {
        var newlineTerminated = line
        newlineTerminated.append(0x0A)
        return JSONLTailer.latestTurnStatus(in: newlineTerminated)
    }

    /// Load recently touched Codex Desktop threads from Codex's own state DB.
    /// Desktop app-server processes use `/` as CWD in current releases, making
    /// the process-to-project matcher insufficient on its own.
    static func recentCodexDesktopThreadRecords(
        statePath overrideStatePath: String? = nil,
        now: Date = Date(),
        freshnessWindow: TimeInterval = 600,
        completionSettleWindow: TimeInterval = 30,
        fileManager: FileManager = .default
    ) -> [CodexDesktopThreadRecord] {
        let statePath = overrideStatePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        // `has_user_event` is not a reliable visibility bit for Desktop threads:
        // current ChatGPT/Codex builds may keep it at 0 while a user turn is
        // actively writing to the rollout. Pull a slightly wider DB candidate
        // window, then enforce the tighter freshness window from DB/file mtimes.
        let candidateWindow = max(freshnessWindow, 60 * 60)
        let cutoff = now.addingTimeInterval(-candidateWindow).timeIntervalSince1970

        return SQLiteReader.withSQLiteDatabase(at: statePath) { db in
            let columns = SQLiteReader.sqliteTableColumns(db: db, tableName: "threads")
            let requiredColumns: Set<String> = [
                "id", "rollout_path", "cwd", "archived", "source",
            ]
            guard requiredColumns.isSubset(of: columns) else { return [] }

            let updatedAtExpression: String
            if columns.contains("updated_at_ms"), columns.contains("updated_at") {
                updatedAtExpression = "COALESCE(NULLIF(updated_at_ms, 0) / 1000.0, updated_at)"
            } else if columns.contains("updated_at_ms") {
                updatedAtExpression = "updated_at_ms / 1000.0"
            } else if columns.contains("updated_at") {
                updatedAtExpression = "updated_at"
            } else {
                return []
            }
            let modelExpression = columns.contains("model") ? "model" : "NULL"
            let spawnColumns = SQLiteReader.sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            let hasSpawnStatus = Set(["child_thread_id", "status"]).isSubset(of: spawnColumns)
            let spawnJoin = hasSpawnStatus
                ? "LEFT JOIN thread_spawn_edges edge ON edge.child_thread_id = thread.id"
                : ""
            let spawnStatusExpression = hasSpawnStatus ? "edge.status" : "NULL"

            guard let statement = SQLiteReader.prepareSQLiteStatement(
                db: db,
                sql: """
                    SELECT thread.id, thread.rollout_path, thread.cwd,
                           \(updatedAtExpression), \(modelExpression),
                           \(spawnStatusExpression), thread.source
                    FROM threads AS thread
                    \(spawnJoin)
                    WHERE thread.archived = 0
                      AND \(updatedAtExpression) >= ?
                      AND (
                        thread.source = 'vscode'
                        OR thread.source = 'appServer'
                        OR thread.source LIKE '{"subagent"%'
                      )
                      ORDER BY \(updatedAtExpression) DESC
                      LIMIT 50;
                    """
            ) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)

            var records: [CodexDesktopThreadRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionId = SQLiteReader.sqliteColumnString(statement, index: 0),
                      let transcriptPath = SQLiteReader.sqliteColumnString(statement, index: 1),
                      let cwd = SQLiteReader.sqliteColumnString(statement, index: 2),
                      fileManager.fileExists(atPath: transcriptPath) else { continue }
                // JSON `source` rows can also belong to a concurrent Codex CLI
                // subagent. Never re-key an explicitly CLI-origin rollout into
                // the Desktop namespace merely because the Desktop host is open.
                let transcriptOrigin = codexTranscriptOrigin(path: transcriptPath)
                let databaseSource = SQLiteReader.sqliteColumnString(statement, index: 6) ?? ""
                if databaseSource.hasPrefix("{\"subagent") {
                    // JSON source alone does not identify the owning surface.
                    // Require positive Desktop provenance before namespacing it.
                    guard transcriptOrigin == .desktop else { continue }
                } else {
                    guard transcriptOrigin != .cli else { continue }
                }

                let dbUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let fileModifiedAt = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
                let modifiedAt = max(dbUpdatedAt, fileModifiedAt ?? dbUpdatedAt)
                guard modifiedAt >= now.addingTimeInterval(-freshnessWindow) else { continue }

                let dbModel = SQLiteReader.sqliteColumnString(statement, index: 4)
                let (transcriptModel, messages) = readRecentFromCodexTranscript(path: transcriptPath)
                let turnStatus = latestCodexTurnStatus(path: transcriptPath)
                let isFresh = now.timeIntervalSince(modifiedAt) <= 300
                let isActive = isFresh && turnStatus == .processing
                if !isActive,
                   now.timeIntervalSince(modifiedAt) > completionSettleWindow {
                    continue
                }

                records.append(CodexDesktopThreadRecord(
                    sessionId: sessionId,
                    cwd: cwd,
                    model: dbModel ?? transcriptModel,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    transcriptPath: transcriptPath,
                    status: isActive ? .processing : .idle,
                    subagentMetadata: codexSubagentMetadata(inTranscriptPath: transcriptPath),
                    subagentStatus: SQLiteReader.sqliteColumnString(statement, index: 5)
                ))
            }
            return records
        } ?? []
    }

    /// Find active Codex sessions by matching running processes to session files
    static func findActiveCodexSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let codexProcesses = AgentProcessFinder.findCodexProcesses(candidatePids: candidatePids)
        guard !codexProcesses.isEmpty else { return [] }

        let processes = codexProcesses.map { process in
            CodexProcessDiscoveryCandidate(
                pid: process.pid,
                cwd: ProcessTable.getCwd(for: process.pid),
                startTime: ProcessTable.getProcessStartTime(process.pid),
                isDesktop: process.isDesktop
            )
        }

        // Each process is matched against the root it runs with (its
        // CODEX_HOME, grouped by identity). One whose environment cannot be
        // read lands in the first fallback root that has a session for it —
        // never in every root. Paused roots are skipped (ConfigRootDiscovery).
        let scan = SessionDiscovery.configRootScan(for: .codex)
        return ConfigRootDiscovery.run(
            processes: processes,
            lookup: { scan.lookup(pid: $0.pid) },
            fallbackRoots: scan.fallbackRoots,
            discover: { root, group, _ in
                discoverCodexSessions(
                    processes: group,
                    sessionsBase: "\(root)/sessions",
                    statePath: "\(root)/state_5.sqlite"
                )
            },
            sessionId: \.sessionId,
            // Desktop threads come from the state DB without a pid.
            belongsTo: { session, process in
                session.pid == process.pid || (session.pid == nil && process.isDesktop)
            }
        )
    }

    /// Filesystem/state-DB portion of Codex discovery, split from process
    /// inspection so root-CWD fallback and DB degradation can be tested without
    /// relying on live PIDs.
    static func discoverCodexSessions(
        processes: [CodexProcessDiscoveryCandidate],
        sessionsBase: String,
        statePath: String,
        now: Date = Date(),
        fileManager fm: FileManager = .default
    ) -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        var seenDiscoveryIds: Set<String> = []
        var seenDesktopSessionIds: Set<String> = []
        var claimedUnknownSessionIds: Set<String> = []

        // Prefer the native host for unknown-origin root rollouts. Explicit CLI
        // and Desktop metadata is filtered below, so concurrent modes remain
        // distinct even when they share a project directory.
        let orderedProcesses = processes.sorted {
            $0.isDesktop && !$1.isDesktop
        }
        for process in orderedProcesses {
            let processCwd = process.cwd
            let useTranscriptCwd = codexDiscoveryUsesTranscriptCwd(processCwd: processCwd)
            if !useTranscriptCwd,
               let processCwd,
               SessionDiscovery.isSubagentWorktree(processCwd) {
                continue
            }

            // Codex stores sessions in date-based dirs: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
            // A terminal process maps to one cwd; the shared Desktop app-server
            // may own several sessions, so inspect all fresh rollouts instead.
            let candidates = fm.fileExists(atPath: sessionsBase)
                ? findRecentCodexSessions(base: sessionsBase, after: process.startTime, fm: fm)
                : []
            let files: [String]
            if useTranscriptCwd {
                files = candidates.filter { file in
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }
            } else if let processCwd {
                files = Array(candidates.filter { file in
                    guard codexSessionMatchesCwd(path: file, cwd: processCwd) else { return false }
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }.prefix(1))
            } else {
                files = []
            }

            for file in files {
                let fileName = (file as NSString).lastPathComponent
                let rawSessionId = extractCodexSessionId(from: fileName)
                guard !rawSessionId.isEmpty else { continue }
                let identity = codexDiscoveryIdentity(
                    rawSessionId: rawSessionId,
                    isDesktop: process.isDesktop
                )
                guard !seenDiscoveryIds.contains(identity.sessionId) else { continue }
                let transcriptOrigin = codexTranscriptOrigin(path: file)
                if transcriptOrigin == .unknown,
                   claimedUnknownSessionIds.contains(rawSessionId) {
                    continue
                }

                let modifiedAt = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? now
                let codexFreshnessLimit: TimeInterval = process.startTime != nil ? -300 : -30
                if modifiedAt.timeIntervalSince(now) < codexFreshnessLimit { continue }

                let transcriptCwd = codexSessionCwd(path: file)
                let sessionCwd = useTranscriptCwd ? transcriptCwd : (transcriptCwd ?? processCwd)
                guard let sessionCwd, !sessionCwd.isEmpty, !SessionDiscovery.isSubagentWorktree(sessionCwd) else { continue }

                let (model, messages) = readRecentFromCodexTranscript(path: file)
                let subagentMetadata = codexSubagentMetadata(inTranscriptPath: file)
                let turnStatus = latestCodexTurnStatus(path: file)

                results.append(DiscoveredSession(
                    sessionId: identity.sessionId,
                    cwd: sessionCwd,
                    tty: nil,
                    model: model,
                    pid: process.pid,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    source: "codex",
                    transcriptPath: file,
                    parentSessionId: subagentMetadata?.parentThreadId,
                    subagentStatus: nil,
                    agentType: subagentMetadata?.agentType,
                    agentNickname: subagentMetadata?.agentNickname,
                    status: turnStatus.map { $0 == .processing ? .processing : .idle },
                    termBundleId: identity.termBundleId,
                    providerSessionId: identity.providerSessionId
                ))
                // Only accepted candidates exclude a matching DB record. A stale
                // or malformed rollout must not hide a valid state-backed thread.
                seenDiscoveryIds.insert(identity.sessionId)
                if transcriptOrigin == .unknown {
                    claimedUnknownSessionIds.insert(rawSessionId)
                }
                if process.isDesktop {
                    seenDesktopSessionIds.insert(rawSessionId)
                }
            }
        }

        // Only actual active subagents need the optional spawn-edge status.
        // Resolve all of them through one read-only SQLite connection; terminal
        // transcript state already wins without consulting the database.
        let activeSubagentIds = Set(results.compactMap { result -> String? in
            guard result.parentSessionId != nil, result.status != .idle else { return nil }
            return result.providerSessionId ?? result.sessionId
        })
        if !activeSubagentIds.isEmpty {
            let spawnRecords = codexSpawnEdgeRecords(
                threadIds: activeSubagentIds,
                statePath: statePath
            )
            for index in results.indices {
                let providerSessionId = results[index].providerSessionId ?? results[index].sessionId
                results[index].subagentStatus = spawnRecords[providerSessionId]?.status
            }
        }

        // Native Codex Desktop / ChatGPT sessions cannot be mapped by process
        // CWD because its app-server runs from `/`. Hydrate recent threads from
        // state_5.sqlite and let transcript activity drive running/idle state.
        if processes.contains(where: { $0.isDesktop }) {
            results.append(contentsOf: findRecentCodexDesktopSessions(
                excluding: seenDesktopSessionIds,
                statePath: statePath,
                now: now,
                fileManager: fm
            ))
        }
        return results
    }

    static func findRecentCodexDesktopSessions(
        excluding excludedSessionIds: Set<String> = [],
        statePath: String? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [DiscoveredSession] {
        let resolvedStatePath = statePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path

        return recentCodexDesktopThreadRecords(
            statePath: resolvedStatePath,
            now: now,
            fileManager: fileManager
        ).compactMap { record in
            guard !excludedSessionIds.contains(record.sessionId) else { return nil }
            let identity = codexDiscoveryIdentity(rawSessionId: record.sessionId, isDesktop: true)
            return DiscoveredSession(
                sessionId: identity.sessionId,
                cwd: record.cwd,
                tty: nil,
                model: record.model,
                pid: nil,
                modifiedAt: record.modifiedAt,
                recentMessages: record.recentMessages,
                source: "codex",
                transcriptPath: record.transcriptPath,
                parentSessionId: record.subagentMetadata?.parentThreadId,
                subagentStatus: record.subagentStatus,
                agentType: record.subagentMetadata?.agentType,
                agentNickname: record.subagentMetadata?.agentNickname,
                status: record.status,
                termBundleId: identity.termBundleId,
                providerSessionId: identity.providerSessionId
            )
        }
    }

    static func inspectCodexSubagentMetadata(
        inTranscriptPath path: String
    ) -> CodexTranscriptSubagentInspection {
        guard let firstLine = SessionDiscovery.readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any] else {
            return .unavailable
        }

        guard let source = payload["source"] as? [String: Any] else {
            return .root
        }
        let threadId = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let payloadParent = (payload["parent_thread_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Unit variants (`review`, `compact`, `memory_consolidation`) serialize as
        // a bare string and only record their parent on the payload. Without
        // one there is no spawn edge to fall back to either.
        if let label = source["subagent"] as? String, !label.isEmpty {
            guard let payloadParent else { return .root }
            return .subagent(CodexSubagentMetadata(
                parentThreadId: payloadParent,
                agentType: label,
                agentNickname: nil,
                threadId: threadId
            ))
        }
        guard let subagent = source["subagent"] as? [String: Any],
              !subagent.isEmpty else {
            return .root
        }
        // Spawned workers nest the parent under `source.subagent.thread_spawn`;
        // auto-review (guardian) threads record it on the payload itself.
        let parent = SessionDiscovery.firstStringRecursively(in: subagent, key: "parent_thread_id")
            ?? payloadParent
        guard let parent, !parent.isEmpty else { return .unavailable }

        let agentType = SessionDiscovery.firstStringRecursively(in: subagent, key: "agent_role")
            ?? subagent["other"] as? String
            ?? subagent.keys.sorted().first
        let nickname = SessionDiscovery.firstStringRecursively(in: subagent, key: "agent_nickname")
        return .subagent(CodexSubagentMetadata(
            parentThreadId: parent,
            agentType: agentType,
            agentNickname: nickname,
            threadId: threadId
        ))
    }

    static func codexSubagentMetadata(inTranscriptPath path: String) -> CodexSubagentMetadata? {
        guard case .subagent(let metadata) = inspectCodexSubagentMetadata(
            inTranscriptPath: path
        ) else {
            return nil
        }
        return metadata
    }

    static func codexSubagentMetadata(
        threadId: String,
        transcriptPath: String?,
        statePath overrideStatePath: String? = nil
    ) -> CodexSubagentMetadata? {
        if let transcriptPath {
            switch inspectCodexSubagentMetadata(inTranscriptPath: transcriptPath) {
            case .subagent(let metadata):
                return metadata
            case .root:
                return nil
            case .unavailable:
                break
            }
        }

        return codexSpawnEdgeRecords(
            threadIds: [threadId],
            statePath: overrideStatePath
        )[threadId]?.metadata
    }

    /// Resolve spawn relations/statuses in one read-only connection. Queries are
    /// chunked to keep SQLite variable counts bounded when restoring many cards.
    static func codexSpawnEdgeRecords(
        threadIds: Set<String>,
        statePath overrideStatePath: String? = nil
    ) -> [String: CodexSpawnEdgeRecord] {
        guard !threadIds.isEmpty else { return [:] }
        guard let statePath = overrideStatePath else {
            // A thread can live in any Codex root; the first root that knows it wins.
            var merged: [String: CodexSpawnEdgeRecord] = [:]
            for root in SessionDiscovery.codexStateRoots() {
                let unresolved = threadIds.subtracting(merged.keys)
                guard !unresolved.isEmpty else { break }
                let found = codexSpawnEdgeRecords(threadIds: unresolved, statePath: "\(root)/state_5.sqlite")
                merged.merge(found) { current, _ in current }
            }
            return merged
        }
        return SQLiteReader.withSQLiteDatabase(at: statePath) { db in
            let edgeColumns = SQLiteReader.sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            guard Set(["parent_thread_id", "child_thread_id", "status"]).isSubset(of: edgeColumns) else {
                return [:]
            }
            let threadColumns = SQLiteReader.sqliteTableColumns(db: db, tableName: "threads")
            let canJoinThreads = threadColumns.contains("id")
            let roleExpression = canJoinThreads && threadColumns.contains("agent_role")
                ? "thread.agent_role" : "NULL"
            let nicknameExpression = canJoinThreads && threadColumns.contains("agent_nickname")
                ? "thread.agent_nickname" : "NULL"
            let sourceExpression = canJoinThreads && threadColumns.contains("source")
                ? "thread.source" : "NULL"
            let transcriptExpression = canJoinThreads && threadColumns.contains("rollout_path")
                ? "thread.rollout_path" : "NULL"
            let join = canJoinThreads
                ? "LEFT JOIN threads AS thread ON thread.id = edge.child_thread_id"
                : ""

            let orderedIds = threadIds.sorted()
            let chunkSize = 200
            var records: [String: CodexSpawnEdgeRecord] = [:]
            for start in stride(from: 0, to: orderedIds.count, by: chunkSize) {
                let end = min(start + chunkSize, orderedIds.count)
                let chunk = Array(orderedIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT edge.child_thread_id, edge.parent_thread_id, edge.status,
                           \(roleExpression), \(nicknameExpression), \(sourceExpression),
                           \(transcriptExpression)
                    FROM thread_spawn_edges AS edge
                    \(join)
                    WHERE edge.child_thread_id IN (\(placeholders))
                    """
                guard let statement = SQLiteReader.prepareSQLiteStatement(db: db, sql: sql) else { continue }
                for (offset, threadId) in chunk.enumerated() {
                    SQLiteReader.bindSQLiteText(threadId, to: statement, index: Int32(offset + 1))
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let child = SQLiteReader.nonEmptySQLiteColumnString(statement, index: 0),
                          let parent = SQLiteReader.nonEmptySQLiteColumnString(statement, index: 1) else {
                        continue
                    }
                    var agentType = SQLiteReader.nonEmptySQLiteColumnString(statement, index: 3)
                    var nickname = SQLiteReader.nonEmptySQLiteColumnString(statement, index: 4)
                    if let source = SQLiteReader.nonEmptySQLiteColumnString(statement, index: 5),
                       let data = source.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        agentType = agentType ?? SessionDiscovery.firstStringRecursively(in: json, key: "agent_role")
                        nickname = nickname ?? SessionDiscovery.firstStringRecursively(in: json, key: "agent_nickname")
                    }
                    records[child] = CodexSpawnEdgeRecord(
                        metadata: CodexSubagentMetadata(
                            parentThreadId: parent,
                            agentType: agentType,
                            agentNickname: nickname,
                            threadId: child
                        ),
                        status: SQLiteReader.nonEmptySQLiteColumnString(statement, index: 2),
                        transcriptPath: SQLiteReader.nonEmptySQLiteColumnString(statement, index: 6)
                    )
                }
                sqlite3_finalize(statement)
            }
            return records
        } ?? [:]
    }

    /// Find the most recent Codex session file matching a CWD
    /// Scans back up to 7 days to cover long-running sessions that span day boundaries
    static func findRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        findRecentCodexSessions(base: base, after: after, fm: fm)
            .first(where: { codexSessionMatchesCwd(path: $0, cwd: cwd) })
    }

    private static func findRecentCodexSessions(base: String, after: Date?, fm: FileManager) -> [String] {
        let cal = Calendar.current
        let now = Date()
        var dirs: [String] = []
        for daysBack in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", cal.component(.year, from: date))
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dir = "\(base)/\(y)/\(m)/\(d)"
            if fm.fileExists(atPath: dir) {
                dirs.append(dir)
            }
        }
        guard !dirs.isEmpty else { return [] }
        return scanCodexDir(dirs: dirs, after: after, fm: fm)
    }

    private static func scanCodexDir(dirs: [String], after: Date?, fm: FileManager) -> [String] {
        var results: [String] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // Sort descending to check newest first
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for file in jsonlFiles.prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let start = after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < start.addingTimeInterval(-10) {
                    continue
                }
                results.append(fullPath)
            }
        }
        return results
    }

    /// Check if a Codex session file's CWD matches the target
    private static func codexSessionMatchesCwd(path: String, cwd: String) -> Bool {
        codexSessionCwd(path: path) == cwd
    }

    static func codexSessionCwd(path: String) -> String? {
        guard let firstLine = SessionDiscovery.readFirstLine(path: path),
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return nil }
        return sessionCwd
    }

    /// Extract session ID from Codex filename: rollout-2026-04-04T20-54-48-{uuid}.jsonl
    private static func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        // The UUID is the last 36 chars (8-4-4-4-12)
        // Pattern: after the datetime portion, everything from the 4th dash group onwards is the UUID
        let parts = name.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}
        // That's: [rollout, YYYY, MM, DDThh, mm, ss, uuid1, uuid2, uuid3, uuid4, uuid5]
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    static func codexLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        let terminalEventTypes: Set<String> = ["task_complete", "turn_aborted", "turn_failed"]
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String,
                  terminalEventTypes.contains(eventType),
                  let timestamp = json["timestamp"] as? String,
                  let date = SessionDiscovery.parseISO8601Timestamp(timestamp) else { continue }

            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    /// Read model and recent messages from a Codex transcript file
    static func readRecentFromCodexTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = SessionDiscovery.readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var turnModel: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            // Extract model from session_meta
            if type == "session_meta", model == nil,
               let payload = json["payload"] as? [String: Any] {
                model = payload["model"] as? String
                    ?? payload["model_provider"] as? String
            }
            // turn_context names the model each turn actually ran on; current
            // session_meta only has the provider ("openai"), which is no label.
            if type == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let observation = ModelObservation.from(model: payload["model"], effort: nil) {
                turnModel = observation.model
            }

            // Prefer event_msg (cleaner user messages from Codex).
            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let msgType = payload["type"] as? String,
               let msg = payload["message"] as? String, !msg.isEmpty {
                if msgType == "user_message" {
                    userMessages.append((index, msg))
                }
            }

            if let assistantText = JSONLTailer.codexPublicAssistantText(from: json),
               assistantMessages.last?.1 != assistantText {
                assistantMessages.append((index, assistantText))
            }

            // response_item user entries often include injected system/tool
            // context, so only use them when no cleaner event_msg was found.
            if type == "response_item", userMessages.isEmpty,
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "input_text" })?["text"] as? String,
               !text.isEmpty {
                userMessages.append((index, text))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (turnModel ?? model, recent)
    }
}
