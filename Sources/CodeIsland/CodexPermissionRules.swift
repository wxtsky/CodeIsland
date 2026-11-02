import Foundation
import CodeIslandCore

struct CodexPermissionRules {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func isCodexEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "codex"
    }

    /// A request from a remote host (`_remote_host_id`, whatever its value:
    /// only this Mac's own hooks leave it out). That Codex reads its config
    /// and rules on its own host, so nothing under this Mac's CODEX_HOME
    /// describes it, and nothing written there reaches it.
    static func isRemoteEvent(_ event: HookEvent) -> Bool {
        event.rawJSON["_remote_host_id"] != nil
    }

    /// Whether "Always allow" saves a Codex rule (persistAlwaysAllowRule) —
    /// what the approval card's link says it does: an MCP tool's approval in
    /// the table of a server config.toml declares, or a command's prefix
    /// rules (``prefixPatterns(for:)``). A remote Codex request's "Always"
    /// holds for its session instead (AppState.approvePermission), and so
    /// does a local one no rule can describe — an apply_patch, a command
    /// with a redirection or an expansion, a tool of a server config.toml
    /// does not declare.
    ///
    /// Either way the island answers the rest of the session itself: Codex
    /// reads its rules and config.toml when a session starts, so a rule
    /// saved now stops only the sessions started after it.
    static func alwaysSavesRule(for event: HookEvent) -> Bool {
        guard isCodexEvent(event), !isRemoteEvent(event) else { return false }
        if mcpToolApprovalTarget(for: event) != nil {
            return declaredMCPToolApprovalTarget(for: event) != nil
        }
        return prefixPatterns(for: event) != nil
    }

    /// The Codex root the event's session runs under — its config.toml and
    /// rules are the ones that apply. A session started with CODEX_HOME set to
    /// an extra root registered in Settings is recognised by the transcript
    /// path Codex reports; everything else belongs to the primary root.
    /// Paths are matched by identity (symlinks, letter case), so a root
    /// registered through a symlink still claims the real transcript path.
    static func codexHome(
        for event: HookEvent,
        roots: [String] = ConfigInstaller.codexHomes(),
        primary: String = ConfigInstaller.codexHome()
    ) -> String {
        ExtraConfigDirs.owningRoot(
            of: event.rawJSON["transcript_path"] as? String,
            among: roots
        ) ?? primary
    }

    static func shouldDeferToCodexAutoReview(for event: HookEvent, fileManager: FileManager = .default) -> Bool {
        guard isCodexEvent(event) else { return false }

        if let reviewer = eventReviewerValue(event.rawJSON) {
            return isAutoReviewReviewer(reviewer)
        }

        // A remote Codex reads its own host's config.toml and writes its
        // rollout there; this Mac's say nothing about it (a remote rollout is
        // never read here either). With no reviewer in the request itself,
        // nothing tells the island that Codex would review it, so the request
        // is not handed back: the user decides on the card. A wrong hand-back
        // would leave it waiting in a terminal on the other machine, while a
        // card can always be answered.
        guard !isRemoteEvent(event) else { return false }

        // Desktop selections and per-turn overrides need not be written to
        // config.toml or included in PermissionRequest. The matching rollout
        // turn_context records the effective reviewer, including an explicit
        // switch back to human review, so it takes precedence over config.
        if let reviewer = transcriptReviewerValue(event.rawJSON) {
            return isAutoReviewReviewer(reviewer)
        }

        let configPath = codexHome(for: event) + "/config.toml"
        guard fileManager.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return false
        }
        return configEnablesAutoReview(contents)
    }

    /// The reviewer recorded by the rollout's newest `turn_context`, when that
    /// context belongs to the hook's turn.
    ///
    /// Codex runs one turn at a time per thread and writes the turn's context
    /// before its first model request, so the newest context is the only one
    /// that can describe the turn now asking. An older one, or a newest one that
    /// omits the reviewer, must not lend its value.
    ///
    /// This runs on the main actor for every Codex PermissionRequest. A long
    /// turn can sit tens of MiB past its context (local rollouts show 1 in 8
    /// turns over 4 MiB), so the file is searched backwards in chunks for the
    /// marker instead of being split into lines: the usual case costs one chunk,
    /// a miss across the whole window ~10 ms.
    static func transcriptReviewerValue(
        _ rawJSON: [String: Any],
        maxBytes: Int = 32 * 1024 * 1024,
        chunkBytes: Int = 256 * 1024
    ) -> String? {
        // A remote rollout path belongs to the SSH host, not this Mac.
        guard rawJSON["_remote_host_id"] == nil,
              let turnId = rawJSON["turn_id"] as? String, !turnId.isEmpty,
              let path = rawJSON["transcript_path"] as? String, !path.isEmpty,
              let payload = latestTurnContextPayload(atPath: path, maxBytes: maxBytes, chunkBytes: chunkBytes),
              payload["turn_id"] as? String == turnId else { return nil }
        return eventReviewerValue(payload)
    }

    private static let turnContextMarker = Data(#""turn_context""#.utf8)
    /// A turn_context line is a few KiB; anything longer is some other record.
    private static let turnContextLineLimit: UInt64 = 64 * 1024

    private static func latestTurnContextPayload(atPath path: String, maxBytes: Int, chunkBytes: Int) -> [String: Any]? {
        guard maxBytes > 0, chunkBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let marker = turnContextMarker
        do {
            let end = try handle.seekToEnd()
            let floor = end - min(end, UInt64(maxBytes))
            var upper = end
            while upper > floor {
                let lower = upper - min(upper - floor, UInt64(chunkBytes))
                // Overlap the next chunk so a marker split across the boundary is seen whole.
                let readEnd = min(end, upper + UInt64(marker.count - 1))
                try handle.seek(toOffset: lower)
                guard let chunk = try handle.read(upToCount: Int(readEnd - lower)) else { return nil }
                var searchEnd = chunk.endIndex
                while let hit = chunk.range(of: marker, options: .backwards, in: chunk.startIndex..<searchEnd) {
                    searchEnd = hit.lowerBound
                    let offset = lower + UInt64(hit.lowerBound - chunk.startIndex)
                    // Starts inside the overlap: already seen with the later chunk.
                    guard offset < upper else { continue }
                    if let payload = try turnContextPayload(handle: handle, around: offset, floor: floor, end: end) {
                        return payload
                    }
                }
                upper = lower
            }
        } catch {
            // Missing/unreadable/rotated rollouts retain the config fallback.
        }
        return nil
    }

    /// Decodes the line holding the marker at `offset`, provided the whole line
    /// lies inside the window: a line cut by the window's start could begin in
    /// the middle of JSON or UTF-8, and one still being written is incomplete.
    private static func turnContextPayload(
        handle: FileHandle,
        around offset: UInt64,
        floor: UInt64,
        end: UInt64
    ) throws -> [String: Any]? {
        let start = offset - min(offset - floor, turnContextLineLimit)
        let stop = min(end, offset + turnContextLineLimit)
        try handle.seek(toOffset: start)
        // A rollout rewritten since the chunk was read can come back short.
        guard let data = try handle.read(upToCount: Int(stop - start)),
              Int(offset - start) < data.count else { return nil }
        let hit = data.startIndex + Int(offset - start)

        let lineStart: Data.Index
        if let newline = data[..<hit].lastIndex(of: 0x0A) {
            lineStart = newline + 1
        } else if start == 0 {
            lineStart = data.startIndex
        } else {
            return nil
        }
        let lineEnd: Data.Index
        if let newline = data[hit...].firstIndex(of: 0x0A) {
            lineEnd = newline
        } else if stop == end {
            lineEnd = data.endIndex
        } else {
            return nil
        }

        guard let record = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
              record["type"] as? String == "turn_context" else { return nil }
        return record["payload"] as? [String: Any]
    }

    static func configEnablesAutoReview(_ contents: String) -> Bool {
        var currentSection: String?
        var selectedProfile: String?
        var topLevelReviewer: String?
        var profileReviewers: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let section = tomlTableName(from: line) {
                currentSection = section
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = tomlScalarString(String(line[line.index(after: equals)...]))

            if currentSection == nil {
                if key == "profile" {
                    selectedProfile = value
                } else if key == "approvals_reviewer" {
                    topLevelReviewer = value
                }
            } else if let profileName = profileName(fromSection: currentSection),
                      key == "approvals_reviewer" {
                profileReviewers[profileName] = value
            }
        }

        if let selectedProfile,
           let profileReviewer = profileReviewers[selectedProfile] {
            return isAutoReviewReviewer(profileReviewer)
        }

        if let topLevelReviewer {
            return isAutoReviewReviewer(topLevelReviewer)
        }

        return false
    }

    /// Most prefix rules one "Always" saves — one per command of the script.
    /// The link names every rule it saves, and a longer list is not one a
    /// glance takes in: such a script's "Always" holds for the session.
    static let maxPrefixRulesPerApproval = 4

    /// The prefix rules "Always" saves for a command: for each command of
    /// the script, its first words, up to three — what the card's link
    /// spells out, and nothing else. Nil when no prefix rule can describe
    /// the script: Codex checks a rule only against the commands of a script
    /// it reads as plain words (``plainCommands(in:)``), each of them, so a
    /// rule from a redirected or expanded command never matched it, and one
    /// from the first command of `cd app && make` alone left `make` asking.
    ///
    /// Only the command is read. Codex's PermissionRequest hook input carries
    /// no rule of its own to save (codex-rs/hooks/schema/generated/
    /// permission-request.command.input.schema.json has no such field, and
    /// allows no other), and a command's `tool_input` is just `command` and
    /// `description`. A `prefix_rule` anywhere in the payload was written by
    /// the model — an MCP tool's arguments are its own — or by whoever sent
    /// the hook; Codex itself screens the one its model suggests to it. Taken
    /// from there, `["bash"]` was saved for a card that showed `ls -la`, and
    /// allowed every command after it.
    static func prefixPatterns(for event: HookEvent) -> [[String]]? {
        guard let commands = shellCommands(of: event) else { return nil }
        var patterns: [[String]] = []
        for command in commands {
            let pattern = Array(command.prefix(3))
            if !patterns.contains(pattern) { patterns.append(pattern) }
        }
        guard patterns.count <= maxPrefixRulesPerApproval else { return nil }
        return patterns
    }

    /// Whether every command of `event`'s script starts with one of
    /// `patterns`, as Codex matches a prefix rule (codex-rs/execpolicy/src/
    /// rule.rs `matches_prefix`): the rules an "Always" of this session
    /// saved, which the session itself never loads (``alwaysSavesRule(for:)``).
    /// A script Codex would not split into plain commands matches none.
    static func commandsStart(_ event: HookEvent, withAnyOf patterns: Set<[String]>) -> Bool {
        guard !patterns.isEmpty, let commands = shellCommands(of: event) else { return false }
        return commands.allSatisfy { command in
            patterns.contains { !$0.isEmpty && command.starts(with: $0) }
        }
    }

    /// The commands of a shell request's script (``plainCommands(in:)``).
    private static func shellCommands(of event: HookEvent) -> [[String]]? {
        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String else {
            return nil
        }
        return plainCommands(in: command)
    }

    @discardableResult
    func persistAlwaysAllowRule(for event: HookEvent) -> Bool {
        if let mcpTool = Self.mcpToolApprovalTarget(for: event) {
            // A remote tool must never become an approval for this Mac's Codex.
            guard !Self.isRemoteEvent(event) else { return false }
            return persistMCPToolApproval(serverID: mcpTool.serverID, toolName: mcpTool.toolName, codexHome: Self.codexHome(for: event))
        }
        guard let patterns = Self.prefixPatterns(for: event) else { return false }
        return persistPrefixRules(patterns, for: event)
    }

    /// Saves `patterns` — the ones the card's link named — as allow rules in
    /// the event's Codex root.
    @discardableResult
    func persistPrefixRules(_ patterns: [[String]], for event: HookEvent) -> Bool {
        // A remote command must never become a rule for this Mac's Codex.
        guard !Self.isRemoteEvent(event) else { return false }
        let patterns = patterns.filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return false }

        let rulesDirectory = Self.codexHome(for: event) + "/rules"
        let rulesPath = rulesDirectory + "/codeisland.rules"

        do {
            try fileManager.createDirectory(atPath: rulesDirectory, withIntermediateDirectories: true)

            let existing = (try? String(contentsOfFile: rulesPath, encoding: .utf8)) ?? ""
            var updated = existing
            for pattern in patterns where !updated.contains(Self.patternLine(for: pattern)) {
                if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
                updated += Self.ruleBlock(for: pattern)
            }
            guard updated != existing else { return true }
            // A symlinked rules file (dotfiles) is written at its target.
            return ConfigPathIdentity.write(Data(updated.utf8), to: rulesPath, fileManager: fileManager)
        } catch {
            return false
        }
    }

    /// An MCP tool's approval target under the server config.toml declares
    /// for its namespace (``declaredMCPServerID(in:forToolNamespace:)``);
    /// nil when it declares none — the built-in `codex_apps`, a plugin's
    /// server — and nothing can be saved for the tool.
    static func declaredMCPToolApprovalTarget(
        for event: HookEvent,
        fileManager: FileManager = .default
    ) -> (serverID: String, toolName: String)? {
        guard let target = mcpToolApprovalTarget(for: event) else { return nil }
        let configPath = codexHome(for: event) + "/config.toml"
        guard let data = fileManager.contents(atPath: configPath),
              let contents = String(data: data, encoding: .utf8),
              let declaredID = declaredMCPServerID(in: contents, forToolNamespace: target.serverID) else {
            return nil
        }
        return (declaredID, target.toolName)
    }

    private func persistMCPToolApproval(serverID: String, toolName: String, codexHome: String) -> Bool {
        let configPath = codexHome + "/config.toml"
        let configDirectory = (configPath as NSString).deletingLastPathComponent

        do {
            try fileManager.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
            let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            // Codex rejects the whole config.toml when a `mcp_servers.*` table has
            // no transport, so a tools table under a server we never declared (the
            // built-in `codex_app` namespace, say) would break every unrelated
            // setting. The card said "this session" for such a tool
            // (alwaysSavesRule); were config.toml changed since, nothing is saved.
            guard let declaredID = Self.declaredMCPServerID(in: existing, forToolNamespace: serverID) else {
                return false
            }
            let updated = Self.configWithMCPToolApproval(
                existing,
                tablePath: ["mcp_servers", declaredID, "tools", toolName],
                comment: String(Self.mcpToolApprovalComment.dropFirst(2))
            )
            // A symlinked config.toml (dotfiles) is written at its target.
            return ConfigPathIdentity.write(Data(updated.utf8), to: configPath, fileManager: fileManager)
        } catch {
            return false
        }
    }

    static func mcpToolApprovalTarget(for event: HookEvent) -> (serverID: String, toolName: String)? {
        guard isCodexEvent(event),
              let rawToolName = event.toolName,
              rawToolName.hasPrefix("mcp__") else {
            return nil
        }

        let rest = String(rawToolName.dropFirst("mcp__".count))
        guard let separator = rest.range(of: "__") else { return nil }
        let serverID = String(rest[..<separator.lowerBound])
        let toolName = String(rest[separator.upperBound...])
        guard !serverID.isEmpty, !toolName.isEmpty else { return nil }
        return (serverID, toolName)
    }

    /// The exact comment CodeIsland stamps above every approval table it writes.
    /// Only tables carrying it are considered ours to repair.
    static let mcpToolApprovalComment =
        #"# Added by CodeIsland when "Always Allow" is clicked for a Codex MCP tool."#

    /// Heals config.toml files already broken by the #316 write.
    ///
    /// Versions before this fix wrote `[mcp_servers.<namespace>.tools.<tool>]`
    /// using the sanitised namespace from the tool name. When no server is
    /// declared under that exact key, the table is implicitly created without a
    /// transport and Codex rejects the entire file — so the user stays broken
    /// after upgrading unless the stale table is cleaned up for them.
    ///
    /// Only tables stamped with `mcpToolApprovalComment` are touched: an
    /// approval the user wrote by hand is theirs, however it is spelled. A table
    /// whose namespace maps unambiguously onto a declared server is re-pointed
    /// at the real key rather than dropped, so the approval survives the repair.
    ///
    /// Returns nil when there is nothing to change, so callers never rewrite a
    /// healthy file.
    static func repairingOrphanedMCPToolTables(_ contents: String) -> String? {
        var lines = contents.components(separatedBy: .newlines)
        let hadTrailingNewline = contents.hasSuffix("\n")
        if hadTrailingNewline { lines.removeLast() }

        var changed = false
        var index = 0
        while index < lines.count {
            guard let segments = tomlTableSegments(from: lines[index]),
                  segments.count == 4,
                  segments[0] == "mcp_servers",
                  segments[2] == "tools",
                  index > 0,
                  isOurApprovalComment(lines[index - 1]),
                  !configDeclaresMCPServerTransport(contents, serverID: segments[1]) else {
                index += 1
                continue
            }

            let namespace = segments[1]
            let candidates = declaredMCPServerIDs(in: contents)
                .filter { sanitizedToolNamespace($0) == namespace }

            if candidates.count == 1 {
                lines[index] = "[" + ([ "mcp_servers", candidates[0], "tools", segments[3] ])
                    .map(tomlKeySegment)
                    .joined(separator: ".") + "]"
                changed = true
                index += 1
                continue
            }

            // Nothing to re-point it at: drop the comment, the header, and the
            // table body up to the next header.
            var end = index + 1
            while end < lines.count, tomlTableSegments(from: lines[end]) == nil {
                end += 1
            }
            lines.removeSubrange((index - 1)..<end)
            index -= 1
            changed = true
        }

        guard changed else { return nil }
        // Collapse the blank runs a removal can leave behind, without touching
        // spacing the user wrote elsewhere.
        var collapsed: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                continue
            }
            collapsed.append(line)
        }
        while collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            collapsed.removeLast()
        }
        return collapsed.joined(separator: "\n") + "\n"
    }

    private static func isOurApprovalComment(_ line: String?) -> Bool {
        guard let line else { return false }
        return line.trimmingCharacters(in: .whitespaces) == mcpToolApprovalComment
    }

    /// The config.toml table key to write a tool approval under, for the server
    /// namespace that appears in an `mcp__<namespace>__<tool>` tool name.
    ///
    /// The namespace is not always the server key. A tool name uses `__` as its
    /// separator, so Codex sanitises the server name into it — `davinci-resolve`
    /// arrives as `davinci_resolve` (#316). Writing the namespace verbatim then
    /// creates a *second*, transport-less `[mcp_servers.davinci_resolve]` table
    /// and Codex refuses to load the file at all, which surfaces as unrelated
    /// settings failing to save days after the click that caused it.
    ///
    /// Returns nil when nothing declared matches, so the caller approves in
    /// session rather than persisting a table that would invalidate the config.
    static func declaredMCPServerID(in contents: String, forToolNamespace namespace: String) -> String? {
        if configDeclaresMCPServerTransport(contents, serverID: namespace) {
            return namespace
        }

        // Only a sanitisation difference is worth recovering. An ambiguous match
        // (two declared servers collapsing to the same namespace) is left alone:
        // approving the wrong server is worse than not persisting.
        let candidates = declaredMCPServerIDs(in: contents)
            .filter { sanitizedToolNamespace($0) == namespace }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Every `[mcp_servers.<id>]` that declares a transport.
    static func declaredMCPServerIDs(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: .newlines)
        var ids: [String] = []
        for (index, line) in lines.enumerated() {
            guard let segments = tomlTableSegments(from: line),
                  segments.count == 2,
                  segments[0] == "mcp_servers" else {
                continue
            }
            let endIndex = lines[(index + 1)...].firstIndex(where: { tomlTableSegments(from: $0) != nil })
                ?? lines.endIndex
            let declaresTransport = lines[(index + 1)..<endIndex].contains { body in
                guard let key = tomlKey(from: body) else { return false }
                return key == "command" || key == "url"
            }
            if declaresTransport, !ids.contains(segments[1]) {
                ids.append(segments[1])
            }
        }
        return ids
    }

    /// How a server name reaches us inside a tool name: anything that isn't a
    /// TOML bare-key character becomes `_`, since `__` is the field separator.
    static func sanitizedToolNamespace(_ serverID: String) -> String {
        String(serverID.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        })
    }

    static func configDeclaresMCPServerTransport(_ contents: String, serverID: String) -> Bool {
        let lines = contents.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: {
            tomlTableSegments(from: $0) == ["mcp_servers", serverID]
        }) else {
            return false
        }

        let endIndex = lines[(headerIndex + 1)...].firstIndex(where: { tomlTableSegments(from: $0) != nil })
            ?? lines.endIndex
        return lines[(headerIndex + 1)..<endIndex].contains { line in
            guard let key = tomlKey(from: line) else { return false }
            return key == "command" || key == "url"
        }
    }

    static func configWithMCPToolApproval(_ contents: String, tablePath: [String], comment: String) -> String {
        var lines = contents.components(separatedBy: .newlines)
        if contents.hasSuffix("\n") {
            lines.removeLast()
        }

        if let headerIndex = lines.firstIndex(where: { tomlTableSegments(from: $0) == tablePath }) {
            let endIndex = lines[(headerIndex + 1)...].firstIndex(where: { tomlTableSegments(from: $0) != nil })
                ?? lines.endIndex
            if let approvalIndex = lines[(headerIndex + 1)..<endIndex].firstIndex(where: { tomlKey(from: $0) == "approval_mode" }) {
                lines[approvalIndex] = #"approval_mode = "approve""#
            } else {
                lines.insert(#"approval_mode = "approve""#, at: headerIndex + 1)
            }
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("# \(comment)")
            lines.append("[\(tablePath.map(tomlKeySegment).joined(separator: "."))]")
            lines.append(#"approval_mode = "approve""#)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func patternLine(for pattern: [String]) -> String {
        "pattern = [\(pattern.map(quotedRuleString).joined(separator: ", "))]"
    }

    private static func ruleBlock(for pattern: [String]) -> String {
        """
        # Added by CodeIsland when "Always Allow" is clicked for Codex.
        prefix_rule(
            \(patternLine(for: pattern)),
            decision = "allow",
            justification = "Allowed from CodeIsland Always Allow",
        )

        """
    }

    private static func quotedRuleString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func eventReviewerValue(_ rawJSON: [String: Any]) -> String? {
        for key in ["approvals_reviewer", "approvalsReviewer", "_approvals_reviewer"] {
            if let value = rawJSON[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func isAutoReviewReviewer(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return normalized == "auto_review" || normalized == "guardian_subagent"
    }

    private static func stripTomlComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaping = false

        for ch in line {
            if let activeQuote = quote {
                result.append(ch)
                if escaping {
                    escaping = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaping = true
                } else if ch == activeQuote {
                    quote = nil
                }
                continue
            }

            if ch == "#" {
                break
            }
            if ch == "\"" || ch == "'" {
                quote = ch
            }
            result.append(ch)
        }

        return result
    }

    private static func tomlTableName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]"),
              !trimmed.hasPrefix("[[") else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func profileName(fromSection section: String?) -> String? {
        guard let section, section.hasPrefix("profiles.") else { return nil }
        let raw = String(section.dropFirst("profiles.".count))
        let name = tomlScalarString(raw)
        return name.isEmpty ? nil : name
    }

    private static func tomlScalarString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" || first == "'"),
              first == last else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
    }

    private static func tomlKey(from line: String) -> String? {
        let stripped = stripTomlComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = stripped.firstIndex(of: "=") else { return nil }
        return String(stripped[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tomlTableSegments(from line: String) -> [String]? {
        let trimmed = stripTomlComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]"),
              !trimmed.hasPrefix("[[") else {
            return nil
        }

        let body = String(trimmed.dropFirst().dropLast())
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func appendSegment() {
            let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }
            current = ""
        }

        for ch in body {
            if let activeQuote = quote {
                if escaping {
                    current.append(ch)
                    escaping = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaping = true
                } else if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                appendSegment()
            } else {
                current.append(ch)
            }
        }
        appendSegment()
        return segments.isEmpty ? nil : segments
    }

    private static func tomlKeySegment(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The commands of a shell script as Codex reads it for its rules
    /// (codex-rs/shell-command/src/bash.rs `parse_shell_script_into_commands`,
    /// which codex-rs/core/src/exec_policy.rs applies to `bash -lc <script>`):
    /// plain commands joined by `&&`, `||`, `;`, `|` or newlines, each word
    /// literal — bare, '…', or "…" with no expansion or escape in it. Nil
    /// for any other script — a redirection, a substitution, a variable, a
    /// glob, `~`, a subshell, a comment, an assignment, control flow: Codex
    /// then checks the whole `bash -lc` command, which no rule made of the
    /// script's words matches. Where the two readings differ (`!`, a reserved
    /// word, a line continuation) this one refuses, so a script it accepts is
    /// one Codex splits into the same commands.
    static func plainCommands(in script: String) -> [[String]]? {
        let scalars = Array(script.unicodeScalars)
        var commands: [[String]] = []
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        // An unquoted stretch of the word has begun: `=` may not open one
        // (zsh's `=cmd` expansion).
        var inUnquotedRun = false
        // Codex reads a command's name only from a bare word.
        var nameIsQuoted = false
        // After `&&`, `||` or `|`: a command must follow.
        var awaitingCommand = false
        // The quoted and bare stretches the word is made of: Codex refuses
        // several that make an empty word (`''""`).
        var wordParts = 0
        var madeEmptyConcatenation = false

        func endWord() {
            guard inWord else { return }
            if wordParts > 1, word.isEmpty { madeEmptyConcatenation = true }
            words.append(String(word))
            word = String.UnicodeScalarView()
            inWord = false
            inUnquotedRun = false
            wordParts = 0
        }
        func endCommand() -> Bool {
            endWord()
            guard let name = words.first, !nameIsQuoted, isPlainCommandName(name) else { return false }
            commands.append(words)
            words = []
            nameIsQuoted = false
            return true
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch scalar {
            case " ", "\t":
                endWord()
            case "\n":
                // A line may end in `&&`, `||` or `|`; the command follows.
                if !awaitingCommand, inWord || !words.isEmpty {
                    guard endCommand() else { return nil }
                }
            case ";":
                // `;;` belongs to `case`.
                guard !awaitingCommand, next != ";", endCommand() else { return nil }
            case "&":
                // A lone `&` runs in the background; `&>` redirects.
                guard next == "&", !awaitingCommand, endCommand() else { return nil }
                awaitingCommand = true
                index += 1
            case "|":
                guard next != "&", !awaitingCommand, endCommand() else { return nil }
                awaitingCommand = true
                if next == "|" { index += 1 }
            case "'":
                guard let close = scalars[(index + 1)...].firstIndex(of: "'") else { return nil }
                if words.isEmpty { nameIsQuoted = true }
                word.append(contentsOf: scalars[(index + 1)..<close])
                wordParts += 1
                inWord = true
                inUnquotedRun = false
                awaitingCommand = false
                index = close
            case "\"":
                var close = index + 1
                while close < scalars.count, scalars[close] != "\"" {
                    let inner = scalars[close]
                    // Expansions run, and escapes change, what the shell passes.
                    if inner == "$" || inner == "`" { return nil }
                    if inner == "\\", close + 1 < scalars.count,
                       escapedInDoubleQuotes.contains(scalars[close + 1]) {
                        return nil
                    }
                    close += 1
                }
                guard close < scalars.count else { return nil }
                if words.isEmpty { nameIsQuoted = true }
                word.append(contentsOf: scalars[(index + 1)..<close])
                wordParts += 1
                inWord = true
                inUnquotedRun = false
                awaitingCommand = false
                index = close
            default:
                if nonLiteralUnquoted.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F {
                    return nil
                }
                if !inUnquotedRun {
                    if scalar == "=" { return nil }
                    wordParts += 1
                }
                word.append(scalar)
                inWord = true
                inUnquotedRun = true
                awaitingCommand = false
            }
            index += 1
        }

        guard !awaitingCommand else { return nil }
        if inWord || !words.isEmpty {
            guard endCommand() else { return nil }
        }
        return commands.isEmpty || madeEmptyConcatenation ? nil : commands
    }

    /// Unquoted, these make a word something other than its spelling (a glob,
    /// an expansion, an escape, a comment — Codex's `is_literal_word_or_number`)
    /// or make the script more than plain commands (a subshell, a
    /// redirection, history or negation).
    private static let nonLiteralUnquoted: Set<Unicode.Scalar> = [
        "{", "}", "*", "?", "[", "]", "\\", "~", "^", "#", "$", "`",
        "(", ")", "<", ">", "!",
    ]

    /// What a backslash escapes inside double quotes.
    private static let escapedInDoubleQuotes: Set<Unicode.Scalar> = ["$", "`", "\"", "\\", "\n"]

    /// Words that open shell syntax rather than name a program.
    private static let shellReservedWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while",
        "until", "do", "done", "in", "function", "time", "coproc",
    ]

    /// A command's first word names a program: not a reserved word, and not
    /// a variable assignment (`FOO=1 make` sets FOO for `make`).
    private static func isPlainCommandName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("=") && !shellReservedWords.contains(name)
    }
}
