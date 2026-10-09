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

    static func prefixPattern(for event: HookEvent) -> [String]? {
        if let suggested = findSuggestedPrefixRule(in: event.rawJSON) {
            return suggested
        }

        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String else {
            return nil
        }

        return shellPrefix(from: command, maxTokens: 3)
    }

    @discardableResult
    func persistAlwaysAllowRule(for event: HookEvent) -> Bool {
        let codexHome = Self.codexHome(for: event)
        if let mcpTool = Self.mcpToolApprovalTarget(for: event) {
            return persistMCPToolApproval(serverID: mcpTool.serverID, toolName: mcpTool.toolName, codexHome: codexHome)
        }

        guard let pattern = Self.prefixPattern(for: event), !pattern.isEmpty else {
            return false
        }

        let rulesDirectory = codexHome + "/rules"
        let rulesPath = rulesDirectory + "/codeisland.rules"
        let block = Self.ruleBlock(for: pattern)
        let patternLine = Self.patternLine(for: pattern)

        do {
            try fileManager.createDirectory(atPath: rulesDirectory, withIntermediateDirectories: true)

            let existing = (try? String(contentsOfFile: rulesPath, encoding: .utf8)) ?? ""
            if existing.contains(patternLine), existing.contains(#"decision = "allow""#) {
                return true
            }

            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let updated = existing + separator + block
            // A symlinked rules file (dotfiles) is written at its target.
            return ConfigPathIdentity.write(Data(updated.utf8), to: rulesPath, fileManager: fileManager)
        } catch {
            return false
        }
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
            // setting. Approve the call in-session instead of persisting it.
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

    private static func findSuggestedPrefixRule(in value: Any) -> [String]? {
        if let dictionary = value as? [String: Any] {
            for key in ["prefix_rule", "prefixRule"] {
                if let pattern = stringArray(from: dictionary[key]) {
                    return pattern
                }
            }

            for nested in dictionary.values {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        }
        return nil
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let pattern = value as? [String], !pattern.isEmpty {
            return pattern
        }
        if let dictionary = value as? [String: Any],
           let pattern = dictionary["pattern"] as? [String],
           !pattern.isEmpty {
            return pattern
        }
        return nil
    }

    private static func shellPrefix(from command: String, maxTokens: Int) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var index = command.startIndex

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        while index < command.endIndex {
            let char = command[index]
            let next = command.index(after: index)

            if escaping {
                current.append(char)
                escaping = false
                index = next
                continue
            }

            if char == "\\" {
                escaping = true
                index = next
                continue
            }

            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                index = next
                continue
            }

            if char == "'" || char == "\"" {
                quote = char
                index = next
                continue
            }

            if char == "$", next < command.endIndex, command[next] == "(" {
                appendCurrentToken()
                break
            }

            if char == "\n" || char == "|" || char == ";" || char == "<" || char == ">" || char == "&" {
                appendCurrentToken()
                break
            }

            if char.isWhitespace {
                appendCurrentToken()
                if tokens.count >= maxTokens {
                    break
                }
            } else {
                current.append(char)
            }

            index = next
        }

        appendCurrentToken()

        let prefix = Array(tokens.prefix(maxTokens))
        guard !prefix.isEmpty, !looksLikeEnvironmentAssignment(prefix[0]) else {
            return nil
        }
        return prefix
    }

    private static func looksLikeEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
