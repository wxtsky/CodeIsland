import Foundation

/// One process in an agent's ancestry, nearest first.
///
/// Everything the harness matchers need, captured once so the matching itself
/// stays a pure function over plain values (and is testable without spawning
/// anything).
public struct ProcessAncestor: Sendable, Equatable {
    public let pid: Int32
    /// Resolved executable (`proc_pidpath`) — symlinks already followed.
    public let executablePath: String?
    /// argv, including argv[0].
    public let arguments: [String]
    /// Only the variables a matcher asks for; empty when unreadable.
    public let environment: [String: String]
    /// CFBundleIdentifier of the outermost `.app` containing `executablePath`.
    public let bundleIdentifier: String?

    public init(
        pid: Int32,
        executablePath: String?,
        arguments: [String] = [],
        environment: [String: String] = [:],
        bundleIdentifier: String? = nil
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.bundleIdentifier = bundleIdentifier
    }
}

/// A UI harness that runs the real agent CLI as its own child process — the
/// agent's hooks still fire, so the card already exists, but the conversation
/// lives in the harness, not in the terminal the environment variables point
/// at. The card names the harness next to the terminal (like the multiplexer
/// chip), and click-to-jump goes to the harness instead of that terminal. (#321)
public struct HostHarness: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// T3 Code (pingdotgg/t3code): drives claude / codex / opencode / cursor-agent / grok.
        case t3Code
    }

    public enum Surface: Sendable, Equatable {
        /// The Electron desktop app. It registers no deep link that opens an
        /// existing thread, so the best jump is bringing the app forward.
        case desktopApp(bundleId: String)
        /// A `t3` server (CLI, npx, or the launchd service) used from a browser.
        case browser
    }

    public let kind: Kind
    public let surface: Surface
    /// The harness server process the agent descends from.
    public let serverPid: Int32
    /// Candidate T3 state directories for `.browser`, most likely first.
    public var stateDirectories: [String]
    /// Verified browser origin (e.g. `http://localhost:3773`) for `.browser`;
    /// nil when the server's runtime file could not be matched to `serverPid`.
    public var browserOrigin: String?

    public init(
        kind: Kind,
        surface: Surface,
        serverPid: Int32,
        stateDirectories: [String] = [],
        browserOrigin: String? = nil
    ) {
        self.kind = kind
        self.surface = surface
        self.serverPid = serverPid
        self.stateDirectories = stateDirectories
        self.browserOrigin = browserOrigin
    }

    /// Product name for the card chip. Not localized — it is a brand.
    public var label: String {
        switch kind {
        case .t3Code: return "T3 Code"
        }
    }

    /// Whether a click has somewhere real to go. A browser-hosted server whose
    /// URL could not be verified keeps the affordance hidden rather than
    /// jumping to the terminal the server happens to have been started from —
    /// the same rule remote sessions follow.
    public var canJump: Bool {
        switch surface {
        case .desktopApp: return true
        case .browser: return browserOrigin != nil
        }
    }
}

public enum HostHarnessResolver {
    /// T3 Code desktop's `appId` (electron-builder). Nightly/Alpha builds only
    /// change the product name, never the id — which is why the bundle id is
    /// matched instead of the `.app` name.
    public static let t3DesktopBundleId = "com.t3tools.t3code"

    /// Deepest ancestry walk worth doing. T3 spawns agents directly (no shell),
    /// so the server is normally the parent; a handful of hops covers a shell
    /// in T3's integrated terminal or an SDK wrapper in between.
    public static let maxAncestryDepth = 12

    /// First harness found walking up from the agent, or nil.
    ///
    /// Nearest match wins: with the npm launcher or the launchd service there
    /// are two `t3` processes in the chain, and the nearer one is the server
    /// that actually spawned the agent (and wrote the runtime file).
    public static func detect(ancestry: [ProcessAncestor], homeDirectory: String) -> HostHarness? {
        for ancestor in ancestry.prefix(maxAncestryDepth) {
            if let harness = t3Harness(for: ancestor, homeDirectory: homeDirectory) {
                return harness
            }
        }
        return nil
    }

    // MARK: - T3 Code

    static func t3Harness(for ancestor: ProcessAncestor, homeDirectory: String) -> HostHarness? {
        // Desktop: the Electron main process and the backend it spawns with
        // ELECTRON_RUN_AS_NODE share the app's main executable, so both carry
        // the app's bundle id. Helpers (`com.t3tools.t3code.helper`) never
        // spawn agents but are harmless to accept.
        if let bid = ancestor.bundleIdentifier?.lowercased(),
           bid == t3DesktopBundleId || bid.hasPrefix(t3DesktopBundleId + ".") {
            return HostHarness(
                kind: .t3Code,
                surface: .desktopApp(bundleId: t3DesktopBundleId),
                serverPid: ancestor.pid
            )
        }
        guard isT3ServerProcess(ancestor) else { return nil }
        return HostHarness(
            kind: .t3Code,
            surface: .browser,
            serverPid: ancestor.pid,
            stateDirectories: t3StateDirectories(
                arguments: ancestor.arguments,
                environment: ancestor.environment,
                homeDirectory: homeDirectory
            )
        )
    }

    /// Is this the `t3` server (CLI / npx / launchd service)?
    ///
    /// Deliberately narrow. A bare `t3` / `t3code` substring would match a
    /// clone of the t3code repo, its dev runner, or any unrelated tool named
    /// t3; `bin.mjs` and `--bootstrap-fd` alone are generic Node/Electron
    /// shapes. What is matched instead:
    /// - the single-executable build, whose basename is exactly `t3` and which
    ///   lives under `<T3CODE_HOME>/runtime/versions/<ver>/` (install script)
    ///   or `node_modules/@t3code/t3-<platform>/` (the npm `t3` launcher);
    /// - releases before 0.0.41, which ran `node …/node_modules/t3/dist/bin.mjs`.
    static func isT3ServerProcess(_ ancestor: ProcessAncestor) -> Bool {
        if let path = ancestor.executablePath?.lowercased() {
            let basename = (path as NSString).lastPathComponent
            if basename == "t3",
               path.contains("/runtime/versions/") || path.contains("/@t3code/t3-") {
                return true
            }
        }
        // The legacy build ran under node/bun, so the script path is in argv.
        // Skip argv[0]: it is the interpreter (or a symlinked `t3`, which the
        // executable-path check above already resolved).
        for argument in ancestor.arguments.dropFirst() {
            let lower = argument.lowercased()
            if lower.hasSuffix("/node_modules/t3/dist/bin.mjs") {
                return true
            }
        }
        return false
    }

    /// Where a T3 server keeps `server-runtime.json` and `state.sqlite`, in
    /// T3's own precedence: `--base-dir`, then `T3CODE_HOME`, then `~/.t3`.
    /// The state lives in `userdata/`, or `dev/` for a dev-server build.
    static func t3StateDirectories(
        arguments: [String],
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let base = baseDirArgument(arguments)
            ?? environment["T3CODE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (homeDirectory as NSString).appendingPathComponent(".t3")
        let expanded = expandHome(base, homeDirectory: homeDirectory)
        return [
            (expanded as NSString).appendingPathComponent("userdata"),
            (expanded as NSString).appendingPathComponent("dev"),
        ]
    }

    private static func baseDirArgument(_ arguments: [String]) -> String? {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--base-dir" {
                if let value = iterator.next(), !value.isEmpty { return value }
                return nil
            }
            if argument.hasPrefix("--base-dir=") {
                let value = String(argument.dropFirst("--base-dir=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func expandHome(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    /// Browser origin from `server-runtime.json`, accepted only when the file
    /// was written by `expectedPid`. The desktop app and a CLI server share the
    /// default state directory and overwrite each other's file, so an
    /// unchecked read could point at the wrong server.
    ///
    /// Host follows T3's own pairing URL: loopback, unset, and wildcard binds
    /// are reached at `localhost` (where the browser's pairing cookie lives);
    /// an explicit host is used as given.
    public static func t3BrowserOrigin(runtimeJSON: Data, expectedPid: Int32) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: runtimeJSON) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid == expectedPid,
              let port = (object["port"] as? NSNumber)?.intValue, (1...65535).contains(port) else {
            return nil
        }
        let host = (object["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlHost: String
        if host.isEmpty || isLoopbackOrWildcard(host) {
            urlHost = "localhost"
        } else if host.contains(":"), !host.hasPrefix("[") {
            urlHost = "[\(host)]"
        } else {
            urlHost = host
        }
        return "http://\(urlHost):\(port)"
    }

    private static func isLoopbackOrWildcard(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "::1" || lower == "[::1]"
            || lower.hasPrefix("127.")
            || lower == "0.0.0.0" || lower == "::" || lower == "[::]"
    }

    /// The thread route in T3's web app: `/<environmentId>/<threadId>`
    /// (`apps/web/src/routes/_chat.$environmentId.$threadId.tsx`). Falls back
    /// to the app root — T3's thread list — when either id is unknown.
    public static func t3BrowserURL(origin: String, environmentId: String?, threadId: String?) -> URL? {
        guard var components = URLComponents(string: origin) else { return nil }
        if let environmentId = pathSegment(environmentId), let threadId = pathSegment(threadId) {
            components.path = "/\(environmentId)/\(threadId)"
        } else {
            components.path = "/"
        }
        return components.url
    }

    /// Ids T3 generates are UUIDs; anything that is not a plain token is
    /// rejected rather than escaped into a path.
    private static func pathSegment(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// The ids a harness may have recorded for this agent session, for the
    /// thread lookup: the hook's session id, minus CodeIsland's own
    /// `opencode-` prefix for OpenCode, plus any provider session id.
    public static func providerSessionIdCandidates(
        sessionId: String,
        source: String,
        providerSessionId: String?
    ) -> [String] {
        var candidates: [String] = []
        func add(_ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }
        if source == "opencode", sessionId.hasPrefix("opencode-") {
            add(String(sessionId.dropFirst("opencode-".count)))
        } else {
            add(sessionId)
        }
        add(providerSessionId)
        return candidates
    }

    /// Outermost `.app` bundle in an executable path — the app itself, not a
    /// nested helper (`…/T3 Code.app/Contents/Frameworks/T3 Code Helper.app/…`).
    public static func outermostAppBundlePath(forExecutable path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...index]))
    }
}

/// Parser for the `KERN_PROCARGS2` sysctl buffer: `argc` (Int32), the exec
/// path, NUL padding, `argc` NUL-terminated argv strings, then the environment
/// as NUL-terminated `KEY=VALUE` strings up to an empty string.
public enum ProcArgsParser {
    public static func parse(
        _ buffer: [UInt8],
        environmentKeys: Set<String> = []
    ) -> (arguments: [String], environment: [String: String])? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = intSize
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }  // exec path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }  // padding

        func nextString() -> String? {
            guard offset < buffer.count else { return nil }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            let value = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return value
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }

        var environment: [String: String] = [:]
        if !environmentKeys.isEmpty {
            while let entry = nextString(), !entry.isEmpty {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<separator])
                if environmentKeys.contains(key) {
                    environment[key] = String(entry[entry.index(after: separator)...])
                }
            }
        }
        return (arguments, environment)
    }

    /// The `keys` variables of a process — or nil when its environment block
    /// cannot be trusted to be whole: argv ends before `argc` strings, the
    /// block holds no entry at all (the kernel withheld it; a real CLI process
    /// always has PATH, HOME…), or its last entry runs off the end of the
    /// buffer. `parse` returns whatever it got in those cases, which a caller
    /// that must tell "variable unset" from "environment unknown" cannot use:
    /// a missing `CODEX_HOME` would read as "uses the default root".
    public static func completeEnvironment(_ buffer: [UInt8], keys: Set<String>) -> [String: String]? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = intSize
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }  // exec path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }  // padding

        enum Token { case string(String), end, truncated }
        func next() -> Token {
            guard offset < buffer.count else { return .end }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            guard offset < buffer.count else { return .truncated }
            let value = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return .string(value)
        }

        for _ in 0..<argc {
            guard case .string = next() else { return nil }
        }

        // A process that rewrites its argv (Node sets its own title: pi is
        // "pi", not the node invocation) leaves the old argv bytes behind as
        // NUL padding between argv and the environment. The environment has no
        // empty entries, so the gap is not one: skip it instead of reading it
        // as "the kernel withheld the block".
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }

        var environment: [String: String] = [:]
        var entryCount = 0
        scan: while true {
            switch next() {
            case .string(let entry):
                if entry.isEmpty { break scan }
                entryCount += 1
                guard let separator = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<separator])
                if keys.contains(key) {
                    environment[key] = String(entry[entry.index(after: separator)...])
                }
            case .end:
                break scan
            case .truncated:
                return nil
            }
        }
        return entryCount > 0 ? environment : nil
    }
}

extension SessionSnapshot {
    /// Chip text for the harness hosting this agent (e.g. "T3 Code"), shown
    /// next to — never instead of — the terminal badge.
    public var hostHarnessLabel: String? {
        hostHarness?.label
    }

    /// Whether click-to-jump has a real target. Remote sessions and
    /// harness-hosted sessions whose harness URL is unknown hide the
    /// affordance instead of offering a dead or misleading click.
    public var canJumpFromNotch: Bool {
        if isRemote { return false }
        if let hostHarness { return hostHarness.canJump }
        return true
    }
}
