import Foundation
import CodeIslandCore

/// Kiro CLI sessions (Amazon Q Developer / Kiro CLI):
/// Discovers sessions from `~/.kiro/session-leases` and `~/.kiro/sessions`,
/// matching running processes to their workspace transcripts.
enum KiroDiscovery {
    static func kiroRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.kiro"
    }

    static func readModelFromKiroStore(cwd: String?, processStart: Date?, root: String? = nil) -> String? {
        guard let cwd else { return nil }
        let fm = FileManager.default
        guard let session = findRecentKiroSession(cwd: cwd, after: processStart, root: root, fm: fm) else { return nil }
        return session.model
    }

    static func findActiveKiroSessions(
        candidatePids: [pid_t]? = nil,
        root: String? = nil,
        isProcessAlive: ((pid_t) -> Bool)? = nil
    ) -> [DiscoveredSession] {
        let baseRoot = root ?? kiroRoot()
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseRoot) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds = Set<String>()

        let checkAlive: (pid_t) -> Bool = isProcessAlive ?? { pid in
            pid > 0 && kill(pid, 0) == 0
        }

        // 1. Check ~/.kiro/session-leases for actively leased sessions
        let leasesDir = "\(baseRoot)/session-leases"
        if let leaseFiles = try? fm.contentsOfDirectory(atPath: leasesDir) {
            for file in leaseFiles where file.hasSuffix(".lease") {
                let leasePath = "\(leasesDir)/\(file)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: leasePath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = json["pid"] as? pid_t else { continue }

                let parentPid = json["parentPid"] as? pid_t
                let isAlive = checkAlive(pid) || (parentPid != nil && checkAlive(parentPid!))
                guard isAlive else { continue }

                let sessionId = String(file.dropLast(".lease".count))
                guard !seenSessionIds.contains(sessionId) else { continue }

                // Resolve root interactive CLI pid (walk up parentPid if available)
                let effectivePid = resolveRootKiroPid(workerPid: pid, parentPid: parentPid)

                if let discovered = sessionFromDirectory(root: baseRoot, sessionId: sessionId, pid: effectivePid, fm: fm) {
                    seenSessionIds.insert(sessionId)
                    results.append(discovered)
                }
            }
        }

        // 2. Also check running kiro-cli processes against recent sessions in ~/.kiro/sessions
        let kiroPids = AgentProcessFinder.findKiroPids(candidatePids: candidatePids)
        for pid in kiroPids {
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty, !SessionDiscovery.isSubagentWorktree(cwd) else { continue }
            let processStart = ProcessTable.getProcessStartTime(pid)
            guard let match = findRecentKiroSession(cwd: cwd, after: processStart, root: baseRoot, fm: fm) else { continue }
            guard !seenSessionIds.contains(match.sessionId) else { continue }
            seenSessionIds.insert(match.sessionId)

            results.append(DiscoveredSession(
                sessionId: match.sessionId,
                cwd: cwd,
                tty: nil,
                model: match.model,
                pid: pid,
                modifiedAt: match.modifiedAt,
                recentMessages: match.recentMessages,
                source: "kiro",
                transcriptPath: match.transcriptPath,
                status: match.status
            ))
        }

        return results
    }

    /// Walk up from worker / TUI pid to locate the root interactive `kiro-cli` process.
    static func resolveRootKiroPid(workerPid: pid_t, parentPid: pid_t?) -> pid_t {
        var current = parentPid ?? workerPid
        while let parent = ProcessTable.parentPID(for: current), parent > 1 {
            if let path = ProcessTable.executablePath(for: parent),
               CLIProcessResolver.sourceMatchesExecutablePath(path, source: "kiro") {
                current = parent
            } else if let args = ProcessTable.getProcessArgs(parent),
                      args.contains(where: { $0.contains("kiro-cli") || $0.hasSuffix("/kiro") }) {
                current = parent
            } else {
                break
            }
        }
        return current
    }

    /// Construct DiscoveredSession from known sessionId and directory
    static func sessionFromDirectory(root: String, sessionId: String, pid: pid_t, fm: FileManager) -> DiscoveredSession? {
        let sessionsDir = "\(root)/sessions"
        guard let subdirs = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return nil }

        // V3 layout: ~/.kiro/sessions/<workspaceHash>/<sessionId>/session.json
        for subdir in subdirs where subdir != "cli" {
            let sessionJsonPath = "\(sessionsDir)/\(subdir)/\(sessionId)/session.json"
            if fm.fileExists(atPath: sessionJsonPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: sessionJsonPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let cwd = (json["workspacePaths"] as? [String])?.first
                    ?? (json["rootPaths"] as? [String])?.first
                    ?? ProcessTable.getCwd(for: pid)
                    ?? ""
                let model = json["modelId"] as? String
                let statusStr = json["status"] as? String
                let status: AgentStatus? = (statusStr == "in_progress" || statusStr == "running") ? .running : .idle
                let transcriptPath = "\(sessionsDir)/\(subdir)/\(sessionId)/messages.jsonl"
                let (transcriptModel, messages) = readRecentFromKiroTranscript(path: transcriptPath)

                let fileDate: Date
                if let lastModStr = json["lastModifiedAt"] as? String,
                   let parsed = SessionDiscovery.parseISO8601Timestamp(lastModStr) {
                    fileDate = parsed
                } else if let attrs = try? fm.attributesOfItem(atPath: sessionJsonPath),
                          let mtime = attrs[.modificationDate] as? Date {
                    fileDate = mtime
                } else {
                    fileDate = Date()
                }

                return DiscoveredSession(
                    sessionId: sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: model ?? transcriptModel,
                    pid: pid,
                    modifiedAt: fileDate,
                    recentMessages: messages,
                    source: "kiro",
                    transcriptPath: fm.fileExists(atPath: transcriptPath) ? transcriptPath : nil,
                    status: status
                )
            }
        }

        // V2 legacy layout: ~/.kiro/sessions/cli/<sessionId>.json
        let legacyJsonPath = "\(sessionsDir)/cli/\(sessionId).json"
        if fm.fileExists(atPath: legacyJsonPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: legacyJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let cwd = json["cwd"] as? String ?? ProcessTable.getCwd(for: pid) ?? ""
            let transcriptPath = "\(sessionsDir)/cli/\(sessionId).jsonl"
            let (transcriptModel, messages) = readRecentFromKiroTranscript(path: transcriptPath)

            let fileDate: Date
            if let updatedAtStr = json["updated_at"] as? String,
               let parsed = SessionDiscovery.parseISO8601Timestamp(updatedAtStr) {
                fileDate = parsed
            } else if let attrs = try? fm.attributesOfItem(atPath: legacyJsonPath),
                      let mtime = attrs[.modificationDate] as? Date {
                fileDate = mtime
            } else {
                fileDate = Date()
            }

            return DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: transcriptModel,
                pid: pid,
                modifiedAt: fileDate,
                recentMessages: messages,
                source: "kiro",
                transcriptPath: fm.fileExists(atPath: transcriptPath) ? transcriptPath : nil,
                status: .running
            )
        }

        return nil
    }

    /// Search for recent sessions matching `cwd` across V3 and V2 session roots.
    static func findRecentKiroSession(
        cwd: String,
        after processStart: Date?,
        root: String? = nil,
        fm: FileManager
    ) -> (sessionId: String, model: String?, modifiedAt: Date, recentMessages: [ChatMessage], transcriptPath: String?, status: AgentStatus?)? {
        let baseRoot = root ?? kiroRoot()
        let sessionsDir = "\(baseRoot)/sessions"
        guard let subdirs = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return nil }

        let normalizedCwd = (cwd as NSString).standardizingPath
        var bestMatch: (sessionId: String, model: String?, modifiedAt: Date, recentMessages: [ChatMessage], transcriptPath: String?, status: AgentStatus?)? = nil

        // Scan V3 workspaces
        for subdir in subdirs where subdir != "cli" {
            let workspaceDir = "\(sessionsDir)/\(subdir)"
            guard let sessionDirs = try? fm.contentsOfDirectory(atPath: workspaceDir) else { continue }
            for sDir in sessionDirs {
                let sessionJsonPath = "\(workspaceDir)/\(sDir)/session.json"
                guard fm.fileExists(atPath: sessionJsonPath),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: sessionJsonPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let paths = ((json["workspacePaths"] as? [String]) ?? []) + ((json["rootPaths"] as? [String]) ?? [])
                let matchesCwd = paths.contains { ($0 as NSString).standardizingPath == normalizedCwd }
                guard matchesCwd else { continue }

                let fileDate: Date
                if let lastModStr = json["lastModifiedAt"] as? String,
                   let parsed = SessionDiscovery.parseISO8601Timestamp(lastModStr) {
                    fileDate = parsed
                } else if let attrs = try? fm.attributesOfItem(atPath: sessionJsonPath),
                          let mtime = attrs[.modificationDate] as? Date {
                    fileDate = mtime
                } else {
                    fileDate = Date()
                }

                if let processStart, fileDate.timeIntervalSince(processStart) < -300 {
                    continue
                } else if processStart == nil, fileDate.timeIntervalSinceNow < -600 {
                    continue
                }

                if bestMatch == nil || fileDate > bestMatch!.modifiedAt {
                    let sessionId = json["id"] as? String ?? sDir
                    let model = json["modelId"] as? String
                    let statusStr = json["status"] as? String
                    let status: AgentStatus? = (statusStr == "in_progress" || statusStr == "running") ? .running : .idle
                    let transcriptPath = "\(workspaceDir)/\(sDir)/messages.jsonl"
                    let (transcriptModel, messages) = readRecentFromKiroTranscript(path: transcriptPath)

                    bestMatch = (
                        sessionId: sessionId,
                        model: model ?? transcriptModel,
                        modifiedAt: fileDate,
                        recentMessages: messages,
                        transcriptPath: fm.fileExists(atPath: transcriptPath) ? transcriptPath : nil,
                        status: status
                    )
                }
            }
        }

        // Scan V2 legacy directory
        let legacyDir = "\(sessionsDir)/cli"
        if bestMatch == nil, let files = try? fm.contentsOfDirectory(atPath: legacyDir) {
            for file in files where file.hasSuffix(".json") && !file.hasSuffix(".jsonl") {
                let jsonPath = "\(legacyDir)/\(file)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessionCwd = json["cwd"] as? String,
                      (sessionCwd as NSString).standardizingPath == normalizedCwd else { continue }

                let fileDate: Date
                if let updatedAtStr = json["updated_at"] as? String,
                   let parsed = SessionDiscovery.parseISO8601Timestamp(updatedAtStr) {
                    fileDate = parsed
                } else if let attrs = try? fm.attributesOfItem(atPath: jsonPath),
                          let mtime = attrs[.modificationDate] as? Date {
                    fileDate = mtime
                } else {
                    fileDate = Date()
                }

                if let processStart, fileDate.timeIntervalSince(processStart) < -300 {
                    continue
                } else if processStart == nil, fileDate.timeIntervalSinceNow < -600 {
                    continue
                }

                if bestMatch == nil || fileDate > bestMatch!.modifiedAt {
                    let sessionId = json["session_id"] as? String ?? String(file.dropLast(".json".count))
                    let transcriptPath = "\(legacyDir)/\(sessionId).jsonl"
                    let (transcriptModel, messages) = readRecentFromKiroTranscript(path: transcriptPath)

                    bestMatch = (
                        sessionId: sessionId,
                        model: transcriptModel,
                        modifiedAt: fileDate,
                        recentMessages: messages,
                        transcriptPath: fm.fileExists(atPath: transcriptPath) ? transcriptPath : nil,
                        status: .running
                    )
                }
            }
        }

        return bestMatch
    }

    static func readRecentFromKiroTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let tail = SessionDiscovery.readTranscriptTail(path: path, maxBytes: 131072) else {
            return (nil, [])
        }
        return parseKiroTranscriptTail(tail)
    }

    static func parseKiroTranscriptTail(_ content: String) -> (String?, [ChatMessage]) {
        let lines = content.components(separatedBy: .newlines)

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var detectedModel: String? = nil
        var index = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Check V3 payload format
            if let payload = json["payload"] as? [String: Any] {
                let type = payload["type"] as? String
                if type == "user", let text = payload["content"] as? String, !text.isEmpty {
                    userMessages.append((index, text))
                } else if type == "assistant", let text = payload["content"] as? String, !text.isEmpty {
                    assistantMessages.append((index, text))
                } else if let reason = payload["reasoningModelId"] as? String {
                    detectedModel = reason.replacingOccurrences(of: "qdev::", with: "")
                }
            } else if let type = json["type"] as? String {
                // Direct user / assistant format
                let msg = (json["message"] as? [String: Any]) ?? json
                if type == "user", let text = SessionDiscovery.extractTextContent(from: msg["content"]) {
                    userMessages.append((index, text))
                } else if type == "assistant", let text = SessionDiscovery.extractTextContent(from: msg["content"]) {
                    assistantMessages.append((index, text))
                }
            } else if let kind = json["kind"] as? String, kind == "Prompt",
                      let dataDict = json["data"] as? [String: Any],
                      let contentList = dataDict["content"] as? [[String: Any]] {
                // Legacy V2 format
                for item in contentList {
                    if let text = item["data"] as? String, !text.isEmpty {
                        userMessages.append((index, text))
                    }
                }
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
        return (detectedModel, Array(combined.suffix(3).map(\.1)))
    }
}
