import Foundation

/// What a diagnostics export may take off this Mac (DiagnosticsExporter). A
/// bug report's zip is attached to an issue anyone can read, so what goes
/// into it is what Settings says it holds, and no more:
///
/// - A CLI's config file keeps its shape and its hooks, without its secrets:
///   an `env` block keeps its variable names and loses their values; text
///   under a key that names a key, token, secret, password or authorization
///   is replaced, however deep; and a secret that only looks like one —
///   a provider key, a bearer token, `NAME_TOKEN=…` or `--api-key …` in a
///   hook command, a password in a URL — is replaced wherever it is.
/// - The saved session list keeps what each session was (ids, sources,
///   folders, terminals, times) and not what was said in it: a prompt is
///   its first 80 characters, and replies, titles, recaps and task lists
///   are only their length.
enum DiagnosticsRedaction {
    static let redacted = "<redacted>"
    static let promptPreviewLength = 80

    // MARK: - CLI configs

    /// A config file as exported, or nil when it is not JSON (comments and
    /// trailing commas allowed): such a file is left out, not copied as it is.
    static func redactedConfig(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed]) else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: redact(object),
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        )
    }

    /// `value` with its secrets replaced; `key` is the name it was found under.
    static func redact(_ value: Any, key: String? = nil) -> Any {
        if let key {
            if isEnvironmentKey(key) { return redactEnvironment(value) }
            if isSecretKey(key) { return redactAll(value) }
        }
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { $0[$1.key] = redact($1.value, key: $1.key) }
        case let array as [Any]:
            return redactArguments(array)
        case let string as String:
            return redactSecrets(in: string)
        default:
            return value
        }
    }

    /// An `env` block: the variables it sets, without their values.
    private static func redactEnvironment(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { _ in redacted }
        case let array as [Any]:
            // ["NAME=value", …]
            return array.map { item -> Any in
                guard let entry = item as? String else { return redactAll(item) }
                guard let equals = entry.firstIndex(of: "=") else { return redacted }
                return String(entry[..<equals]) + "=" + redacted
            }
        default:
            return redactAll(value)
        }
    }

    /// Every string under a secret's key; its shape, numbers and true/false
    /// stay (`"maxTokens": 8192`).
    private static func redactAll(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(redactAll)
        case let array as [Any]: return array.map(redactAll)
        case is String: return redacted
        default: return value
        }
    }

    /// A list, with the value after a secret's flag (`["--token", "…"]`)
    /// replaced too.
    private static func redactArguments(_ array: [Any]) -> [Any] {
        var result: [Any] = []
        var afterSecretFlag = false
        for item in array {
            if afterSecretFlag, item is String {
                result.append(redacted)
                afterSecretFlag = false
                continue
            }
            afterSecretFlag = false
            if let flag = item as? String, isSecretFlag(flag) {
                afterSecretFlag = true
            }
            result.append(redact(item))
        }
        return result
    }

    private static let environmentKeys: Set<String> = ["env", "environment", "envvars", "env_vars", "environmentvariables"]
    private static let secretWords: Set<String> = [
        "key", "keys", "apikey", "token", "tokens", "secret", "secrets", "password", "passwd", "passphrase",
        "auth", "authorization", "credential", "credentials", "cookie", "cookies", "bearer", "jwt",
    ]
    private static let secretFragments = ["apikey", "api_key", "api-key", "token", "secret", "password", "passwd", "authorization", "credential"]

    static func isEnvironmentKey(_ key: String) -> Bool {
        environmentKeys.contains(key.lowercased())
    }

    /// A key that names a secret: one of its words (`apiKeyHelper`,
    /// `x-api-key`, `GITHUB_TOKEN`) is key, token, secret, password,
    /// authorization and the like.
    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        if secretFragments.contains(where: lowered.contains) { return true }
        return words(of: key).contains(where: secretWords.contains)
    }

    private static func isSecretFlag(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.contains("=") else { return false }
        return isSecretKey(String(argument.drop(while: { $0 == "-" })))
    }

    /// `apiKeyHelper` → api, key, helper; `X-API-Key` → x, api, key.
    private static func words(of key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in key {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    // MARK: - Secrets inside text

    private static let secretPatterns: [(NSRegularExpression, String)] = [
        // NAME_TOKEN=… / API_KEY="…" in a command line
        (#"(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|CREDENTIALS?)[A-Z0-9_]*)=("[^"]*"|'[^']*'|[^\s"']+)"#, "$1=\(redacted)"),
        // --api-key … / --token=…, a flag of its own (not `sk-…-key` or `my-auth-service`)
        (#"(?i)(?<![^\s"'(=])(--?[A-Z0-9_-]*(?:key|token|secret|password|passwd|auth)[A-Z0-9_-]*)(=|\s+)("[^"]*"|'[^']*'|[^\s"'-][^\s"']*)"#, "$1$2\(redacted)"),
        // Authorization: … / X-API-Key: … headers
        (#"(?i)\b(authorization|proxy-authorization|x-api-key|api-key|cookie)(\s*:\s*)(?:(?:bearer|basic|token)\s+)?[^\s"',;]+"#, "$1$2\(redacted)"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 \(redacted)"),
        // A password in a URL
        (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1\(redacted)@"),
        // Provider keys and tokens by their form
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, redacted),
        (#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, redacted),
        (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, redacted),
        (#"\bAKIA[0-9A-Z]{16}\b"#, redacted),
        (#"\bAIza[0-9A-Za-z_-]{30,}"#, redacted),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, redacted),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// `text` with anything that looks like a secret replaced.
    static func redactSecrets(in text: String) -> String {
        secretPatterns.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    // MARK: - The saved session list

    /// sessions.json as exported, or nil when it is not a list.
    static func redactedPersistedSessions(_ data: Data) -> Data? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let redactedEntries = entries.map { entry -> Any in
            guard let session = entry as? [String: Any] else { return contentFree(entry) }
            return session.reduce(into: [String: Any]()) { result, field in
                result[field.key] = redactSessionField(field.key, field.value)
            }
        }
        return try? JSONSerialization.data(
            withJSONObject: redactedEntries,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// What a session was, kept: ids, sources, folders, terminal and
    /// multiplexer routing, times.
    private static let sessionStructureKeys: Set<String> = [
        "sessionId", "cwd", "source", "model", "sessionTitleSource", "providerSessionId",
        "termApp", "itermSessionId", "ttyPath", "kittyWindowId", "kittyListenOn", "tmuxPane", "tmuxClientTty", "tmuxEnv",
        "termBundleId", "cmuxSurfaceId", "cmuxWorkspaceId", "zellijPaneId", "zellijSessionName",
        "weztermPaneId", "herdrPaneId", "herdrSocketPath", "herdrBinaryPath", "cliPid", "cliStartTime",
        "startTime", "lastActivity", "transcriptPath", "closedSubagentIds", "reasoningEffort",
        "claudeDesktopSessionId", "hermesChatElsewhere", "parentSessionId",
    ]
    /// Inside what was said (a task list, a recap): its state, kept.
    private static let nestedStructureKeys: Set<String> = ["id", "status", "state", "kind", "type", "source"]

    private static func redactSessionField(_ key: String, _ value: Any) -> Any {
        if key == "lastUserPrompt", let prompt = value as? String { return promptPreview(prompt) }
        if sessionStructureKeys.contains(key) { return redact(value) }
        return contentFree(value)
    }

    /// A prompt's first 80 characters, as the hook events in the same export
    /// show it, with anything in them that looks like a secret replaced.
    static func promptPreview(_ prompt: String) -> String {
        redactSecrets(in: String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(promptPreviewLength)))
    }

    /// What was said, as its shape: text becomes its length; keys, counts,
    /// numbers, true/false and the state of what it lists stay.
    private static func contentFree(_ value: Any, key: String? = nil) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { $0[$1.key] = contentFree($1.value, key: $1.key) }
        case let array as [Any]:
            return array.map { contentFree($0) }
        case let string as String:
            if let key, nestedStructureKeys.contains(key) { return redactSecrets(in: String(string.prefix(64))) }
            return "<\(string.count) characters>"
        default:
            return value
        }
    }
}
