import Foundation
import CodeIslandCore

/// Which local processes are which agent: per-source pid scans over the
/// process table (executable paths, argv) and the bundle-path rules that tell
/// an IDE or desktop host from a CLI. Whole-table scans read every process,
/// so they run off the main actor (discovery scans, `tryMonitorSession`'s
/// CWD fallback); the path rules are pure.
enum AgentProcessFinder {
    /// Both bundle names the Qoder IDE has shipped under, lowercased.
    ///
    /// Qoder IDE 1.25.1 (2026-08-19) renamed the macOS bundle from `Qoder.app`
    /// to `Qoder IDE.app` and its executable from `Electron` to `Qoder` — so
    /// matching on `/qoder.app/contents/` alone stopped recognising the IDE
    /// entirely (#327). Both names stay listed: the rename doesn't reach
    /// installs that haven't updated. `com.qoder.ide` is unchanged, so
    /// activation and badge labels were never affected — only the
    /// process-ancestry matching that runs off executable paths.
    ///
    /// Qoder App (`com.qoder.app`) also uses `Qoder.app` and the `qoder` hook
    /// source, so it shares this process-path protection. Session bundle IDs
    /// distinguish it from the IDE. Neither prefix matches QoderWork.
    static let qoderIDEBundlePrefixes = [
        "/qoder.app/contents/",
        "/qoder ide.app/contents/",
    ]

    /// Is `executablePath` inside a Qoder IDE bundle, under either name?
    static func isQoderIDEBundlePath(_ executablePath: String) -> Bool {
        let path = executablePath.lowercased()
        return qoderIDEBundlePrefixes.contains { path.contains($0) }
    }

    /// Is `executablePath` inside the Trae CN IDE bundle, under any name it
    /// ships as? It never matches the international `Trae.app`: the two
    /// editions are separate installs and must not keep each other's
    /// sessions alive. The markers live in CodeIslandCore so the bridge's
    /// `_ppid` resolution uses the same list.
    static func isTraeCNIDEBundlePath(_ executablePath: String) -> Bool {
        CLIProcessResolver.isTraeCNBundlePath(executablePath)
    }

    static func isNativeAppProcess(
        _ pid: pid_t,
        source: String,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) }
    ) -> Bool {
        guard let executable = executablePath(pid) else { return false }
        let path = executable.lowercased()
        switch source {
        case "cursor":     return path.contains("/cursor.app/contents/")
        case "trae":       return path.contains("/trae.app/contents/")
        case "traecn":     return isTraeCNIDEBundlePath(path)
        case "qoder":      return isQoderIDEBundlePath(path)
        // QoderWork desktop app (#249) — bundle id undocumented; the standard
        // /Applications/QoderWork.app layout is assumed, pending real-install
        // verification.
        case "qoderwork":  return path.contains("/qoderwork.app/contents/")
        case "droid":      return path.contains("/factory.app/contents/")
        case "codebuddy":  return path.contains("/codebuddy.app/contents/")
        case "codybuddycn": return path.contains("/codebuddycn.app/contents/") || path.contains("/codebuddy.app/contents/")
        case "stepfun":    return path.contains("/stepfun.app/contents/")
        case "codex":      return isCodexExecutablePath(executable)
        case "opencode":   return path.contains("/opencode.app/contents/")
        // Xiaomi MiMo desktop runs MiMo Code inside its own main process.
        case "mimo":       return CLIProcessResolver.isMimoDesktopBundlePath(path)
        case "antigravity": return path.contains("/antigravity.app/contents/")
        // Google Antigravity IDE — host app is Antigravity.app. Same .app path as
        // the fork, but the check is per-source so a "google-antigravity" session
        // (whose host genuinely IS Antigravity.app) never collides with the fork's
        // "antigravity" CLI sessions (#215).
        case "google-antigravity": return path.contains("/antigravity.app/contents/")
        case "workbuddy":   return path.contains("/workbuddy.app/contents/")
        case "hermes":      return path.contains("/hermes.app/contents/")
        // Claude Code Desktop (#211): local Code-tab sessions live inside Claude.app.
        case "claude":      return path.contains("/claude.app/contents/")
        case "zcode":       return path.contains("/zcode.app/contents/")
        default:           return false
        }
    }

    /// Find a CLI process PID by matching CWD, scoped to the correct source.
    /// Never guesses across sources: a missing/unknown source returns no PID instead of
    /// accidentally binding a session to the wrong process family.
    static func findPidForCwd(_ cwd: String, source: String? = nil) -> pid_t? {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source) else { return nil }
        let pids = findPids(forSource: normalizedSource)
        for pid in pids {
            if ProcessTable.getCwd(for: pid) == cwd { return pid }
        }
        return nil
    }

    private static func findPids(forSource source: String, candidatePids: [pid_t]? = nil) -> [pid_t] {
        switch source {
        case "claude":     return findClaudePids(candidatePids: candidatePids)
        case "codex":      return findCodexPids(candidatePids: candidatePids)
        case "gemini":     return findGeminiPids(candidatePids: candidatePids)
        case "cursor":     return findCursorPids(candidatePids: candidatePids)
        case "cursor-cli": return findCursorCliPids(candidatePids: candidatePids)
        case "trae":       return findTraePids(candidatePids: candidatePids)
        case "traecn":     return findTraeCNPids(candidatePids: candidatePids)
        case "traecli":   return findTraeCliPids(candidatePids: candidatePids)
        case "copilot":    return findCopilotPids(candidatePids: candidatePids)
        case "qoder":      return findQoderPids(candidatePids: candidatePids)
        case "qoder-cli":  return findQoderCliPids(candidatePids: candidatePids)
        case "qoderwork":  return findQoderWorkPids(candidatePids: candidatePids)
        case "droid":      return findFactoryPids(candidatePids: candidatePids)
        case "codebuddy":  return findCodeBuddyPids(candidatePids: candidatePids)
        case "codybuddycn": return findCodyBuddyCNPids(candidatePids: candidatePids)
        case "stepfun":    return findStepFunPids(candidatePids: candidatePids)
        case "opencode":   return findOpenCodePids(candidatePids: candidatePids)
        case "mimo":       return findMimoPids(candidatePids: candidatePids)
        case "antigravity": return findAntiGravityPids(candidatePids: candidatePids)
        case "google-antigravity": return findGoogleAntigravityPids(candidatePids: candidatePids)
        case "workbuddy":  return findWorkBuddyPids(candidatePids: candidatePids)
        case "hermes":     return findHermesPids(candidatePids: candidatePids)
        case "grok":       return findGrokPids(candidatePids: candidatePids)
        case "qwen":       return findQwenPids(candidatePids: candidatePids)
        case "kimi":       return findKimiPids(candidatePids: candidatePids)
        case "kiro":       return findKiroPids(candidatePids: candidatePids)
        case "pi":         return findPiPids(candidatePids: candidatePids)
        case "cline":      return findClinePids(candidatePids: candidatePids)
        case "zcode":      return findZcodePids(candidatePids: candidatePids)
        case "minimax":    return findMinimaxPids(candidatePids: candidatePids)
        default:           return []
        }
    }

    private static func findPids(
        matchingPathSubstrings pathSubstrings: [String],
        pathSuffixes: [String] = [],
        argSubstrings: [String] = [],
        candidatePids: [pid_t]? = nil,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) },
        arguments: (pid_t) -> [String]? = { ProcessTable.getProcessArgs($0) }
    ) -> [pid_t] {
        let loweredPaths = pathSubstrings.map { $0.lowercased() }
        let loweredSuffixes = pathSuffixes.map { $0.lowercased() }
        let loweredArgs = argSubstrings.map { $0.lowercased() }
        guard !loweredPaths.isEmpty || !loweredSuffixes.isEmpty || !loweredArgs.isEmpty else { return [] }

        var matched: [pid_t] = []
        for pid in candidatePids ?? ProcessTable.allProcessIds() {
            guard let path = executablePath(pid)?.lowercased() else { continue }
            if loweredPaths.contains(where: { path.contains($0) })
                || loweredSuffixes.contains(where: { path.hasSuffix($0) }) {
                matched.append(pid)
                continue
            }
            guard !loweredArgs.isEmpty,
                  let args = arguments(pid)?.map({ $0.lowercased() }) else { continue }
            if args.contains(where: { arg in loweredArgs.contains(where: { arg.contains($0) }) }) {
                matched.append(pid)
            }
        }
        return matched
    }

    /// Get PIDs of running Claude Code processes
    /// Claude's binary is named by version (e.g. "2.1.91") under ~/.local/share/claude/versions/
    ///
    /// Only the processes that run it as Claude Code's CLI
    /// (`isClaudeCodeCLIInvocation`): the same file is also the grep / find /
    /// ripgrep its shell and Grep tool run, and its background machinery.
    /// Matched by cwd, one of those would claim a session's transcript, so the
    /// card would go when a grep ended — and once its shell went away first,
    /// the orphan sweep would SIGTERM it.
    static func findClaudePids(
        candidatePids: [pid_t]? = nil,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) },
        arguments: (pid_t) -> [String]? = { ProcessTable.getProcessArgs($0) }
    ) -> [pid_t] {
        let claudeVersionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path

        let customCommands = CustomAgentCommandStore.activeCommandNames(forAgent: "claude")
        let customDirs = Set(CustomAgentCommandStore.activeConfigDirs(forAgent: "claude").map { ExtraConfigDirs.identity(of: $0) })

        var claudePids: [pid_t] = []

        for pid in candidatePids ?? ProcessTable.allProcessIds() {
            guard let path = executablePath(pid) else { continue }
            let lowerPath = path.lowercased()
            let args = arguments(pid) ?? []
            let lowerArgs = args.map { $0.lowercased() }

            var isMatch = false
            if path.hasPrefix(claudeVersionsDir) {
                isMatch = true
            } else if lowerPath.hasSuffix("/claude") || lowerPath.contains("/claude ") {
                isMatch = true
            } else if customCommands.contains(where: { cmd in
                lowerPath.hasSuffix("/\(cmd)") || lowerPath.contains("/\(cmd) ") || lowerArgs.contains(where: { $0.contains(cmd) })
            }) {
                isMatch = true
            }

            // Also match if process environment CLAUDE_CONFIG_DIR matches one of our custom dirs
            if !isMatch && !customDirs.isEmpty {
                if let env = SessionDiscovery.configRootEnvironment(for: pid),
                   let rawDir = env["CLAUDE_CONFIG_DIR"],
                   customDirs.contains(ExtraConfigDirs.identity(of: rawDir)) {
                    isMatch = true
                }
            }

            guard isMatch else { continue }
            if !args.isEmpty, !isClaudeCodeCLIInvocation(arguments: args) { continue }
            claudePids.append(pid)
        }
        return claudePids
    }

    /// argv[0] names Claude Code's native binary runs under as a tool, not as
    /// Claude Code: the binary is multicall, and the shell it gives its Bash
    /// tool defines `grep`, `find` and `rg` as `exec -a ugrep|bfs|rg <binary>`
    /// (its Grep tool starts `rg` the same way). `apply-seccomp` is its Linux
    /// sandbox helper.
    static let claudeCodeToolNames: Set<String> = ["ugrep", "bfs", "rg", "apply-seccomp"]

    /// Arguments that start the binary as Claude Code's own machinery rather
    /// than a session: the detached terminal host and the spare worker inside
    /// it (argv[0] `claude bg-pty-host`, `claude bg-spare`), daemon workers,
    /// preloading, the `gh` shim, and the MCP servers and browser native host
    /// it serves to Chrome or its own sessions. No user passes them.
    static let claudeCodeHelperFlags: Set<String> = [
        "--bg-pty-host", "--bg-spare", "--daemon-worker", "--preload", "--gh-standin",
        "--chrome-native-host", "--claude-in-chrome-mcp", "--computer-use-mcp", "--eval-mock-server",
    ]

    /// Subcommands that run no session: `claude mcp serve` is an MCP server
    /// for another client, the rest change settings or the install and exit.
    static let claudeCodeNonSessionSubcommands: Set<String> = [
        "mcp", "config", "doctor", "update", "install", "uninstall", "setup-token", "plugin", "auth",
    ]

    /// Whether argv starts Claude Code's CLI — interactive, `-p`, `--resume`,
    /// `--continue` — rather than a tool, a background helper or a settings
    /// subcommand that runs the same binary. An argv that can't be read counts
    /// as the CLI.
    static func isClaudeCodeCLIInvocation(arguments: [String]) -> Bool {
        guard let argv0 = arguments.first else { return true }
        // Background roles name themselves in argv[0]: `claude bg-pty-host`.
        if argv0.hasPrefix("claude ") { return false }
        if claudeCodeToolNames.contains((argv0 as NSString).lastPathComponent) { return false }
        let rest = arguments.dropFirst()
        if rest.contains(where: { claudeCodeHelperFlags.contains($0) }) { return false }
        if let first = rest.first, claudeCodeNonSessionSubcommands.contains(first) { return false }
        return true
    }

    /// A live process running a Claude Code executable as something other
    /// than its CLI (`isClaudeCodeCLIInvocation`).
    static func isClaudeCodeNonCLIProcess(
        _ pid: pid_t,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) },
        arguments: (pid_t) -> [String]? = { ProcessTable.getProcessArgs($0) }
    ) -> Bool {
        guard let path = executablePath(pid),
              CLIProcessResolver.sourceMatchesExecutablePath(path, source: "claude"),
              let args = arguments(pid) else { return false }
        return !isClaudeCodeCLIInvocation(arguments: args)
    }

    static func findGeminiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/gemini-cli/bundle/gemini.js",
                "/opt/homebrew/bin/gemini",
            ],
            candidatePids: candidatePids
        )
    }

    static func findCursorPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/cursor.app/contents/macos/cursor",
                "/cursor.app/contents/frameworks/cursor helper",
                "/.local/share/cursor-agent/versions/",
            ],
            argSubstrings: ["/cursor-agent/index.js"],
            candidatePids: candidatePids
        )
    }

    /// Standalone Cursor CLI agent — must not match the desktop IDE/helper
    /// processes that `findCursorPids` also covers (#248).
    private static func findCursorCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/share/cursor-agent/versions/",
            ],
            argSubstrings: ["/cursor-agent/index.js"],
            candidatePids: candidatePids
        )
    }

    /// The IDE's main and helper processes, under either bundle name (#327).
    /// The executable was renamed alongside the bundle (`Electron` → `Qoder`),
    /// so the main process is matched by its `MacOS/` directory rather than by
    /// a binary name that also changed.
    static func findQoderPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: qoderIDEBundlePrefixes.flatMap {
                ["\($0)macos/", "\($0)frameworks/qoder helper"]
            } + ["/.qoder/bin/qodercli/"],
            candidatePids: candidatePids
        )
    }

    /// Standalone Qoder CLI — must not match the desktop IDE/helper (#248).
    /// Both Qoder CLI builds: the international `qodercli` under ~/.qoder and the
    /// China build `qoderclicn` under ~/.qoder-cn. Same hook contract, one source
    /// (#289) — the CN binary is a separate build, so its own paths are needed.
    private static func findQoderCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.qoder/bin/qodercli/",
                "/@qoder-ai/qodercli",
                "/.qoder-cn/bin/qoderclicn/",
                "/@qoder-ai/qoderclicn",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/qodercli",
                "/usr/local/bin/qodercli",
                "/.local/bin/qodercli",
                "/opt/homebrew/bin/qoderclicn",
                "/usr/local/bin/qoderclicn",
                "/.local/bin/qoderclicn",
            ],
            candidatePids: candidatePids
        )
    }

    /// QoderWork desktop app (#249). Bundle layout is assumed from the standard
    /// /Applications/QoderWork.app install — no public bundle id / binary name
    /// docs, pending real-install verification. "/qoderwork.app/" never collides
    /// with the IDE's "/qoder.app/" substrings.
    private static func findQoderWorkPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/qoderwork.app/contents/",
            ],
            candidatePids: candidatePids
        )
    }

    static func findFactoryPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/factory.app/contents/macos/electron",
                "/factory.app/contents/frameworks/factory helper",
                "/.local/bin/droid",
            ],
            candidatePids: candidatePids
        )
    }

    static func findCodeBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddy.app/contents/macos/electron",
                "/codebuddy.app/contents/frameworks/codebuddy helper",
            ],
            argSubstrings: [
                "/@tencent-ai/codebuddy-code/bin/codebuddy",
                "/opt/homebrew/bin/codebuddy",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findCodyBuddyCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddycn.app/contents/macos/electron",
                "/codebuddycn.app/contents/frameworks/codebuddycn helper",
                "/.codybuddycn/",
                "/.codebuddycn/",
            ],
            argSubstrings: [
                "/.codybuddycn/",
                "/.codebuddycn/",
                "/opt/homebrew/bin/codybuddycn",
                "/opt/homebrew/bin/codebuddycn",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findStepFunPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/stepfun.app/contents/macos/stepfun",
                "/.stepfun/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/stepfun",
                "/.stepfun/",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findTraePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/trae.app/contents/macos/trae",
                "/trae.app/contents/frameworks/trae helper",
                "/.trae/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/trae",
                "/.trae/",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findTraeCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: CLIProcessResolver.traeCNBundlePathMarkers + [
                "/trae-cn.app/contents/macos/trae",
                "/.traecn/",
                "/.trae-cn/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/traecn",
                "/opt/homebrew/bin/trae-cn",
                "/.traecn/",
                "/.trae-cn/",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findTraeCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findAntiGravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
                "/antigravity.app/contents/macos/antigravity",
            ],
            argSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
            ],
            candidatePids: candidatePids
        )
    }

    /// Google Antigravity (Gemini-based IDE/CLI, #215). The actionable agent is the
    /// `agy` CLI (pypi google-antigravity) launched from the IDE's integrated
    /// terminal; the IDE itself is Antigravity.app (com.google.antigravity).
    /// We match the IDE app *only* via the Google-specific .app path component to
    /// avoid colliding with the existing "antigravity" Claude-fork CLI (which lives
    /// under ~/.antigravity, never in an .app named exactly "antigravity").
    private static func findGoogleAntigravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/antigravity.app/contents/macos/",
                "/bin/agy",
            ],
            argSubstrings: [
                "/google-antigravity/",
                "/antigravity-cli/",
                "/bin/agy",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findWorkBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/workbuddy.app/contents/macos/workbuddy",
                "/.workbuddy/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/workbuddy",
                "/.workbuddy/",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findHermesPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/hermes",
                "/hermes.app/contents/macos/hermes",
                "/.hermes/hermes-agent/",
            ],
            argSubstrings: [
                "/.local/bin/hermes",
                "/.hermes/",
            ],
            candidatePids: candidatePids
        )
    }

    // Electron app (.dmg distribution) — packaged executable path unverified
    // on a real machine; best-effort guess pending field report (#245).
    private static func findZcodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/zcode.app/contents/",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findQwenPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/qwen",
                "/.bun/bin/qwen",
            ],
            argSubstrings: [
                "/@qwen-code/qwen-code/",
                "/.qwen/",
            ],
            candidatePids: candidatePids
        )
    }

    static func findKimiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.kimi-code/bin/kimi",
                "/.local/bin/kimi",
                "/.local/share/uv/tools/kimi-cli/",
            ],
            argSubstrings: [
                "/kimi-cli/",
                "kimi_cli",
                "/.kimi-code/",
            ],
            candidatePids: candidatePids
        )
    }

    static func findGrokPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        (candidatePids ?? ProcessTable.allProcessIds()).filter { pid in
            guard let path = ProcessTable.executablePath(for: pid) else { return false }
            return CLIProcessResolver.sourceMatchesExecutablePath(path, source: "grok")
        }
    }

    private static func findMinimaxPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        // mcode is a Node script, so proc_pidpath is the node binary; the
        // Node runtime renames its process title to `minimax-code`, which is
        // what argv carries. Match whole arguments, not substrings: helpers
        // mcode spawns in the session's cwd live under the same package
        // (bundled ripgrep in .../@minimax-ai/code/node_modules/, the
        // `mcode-tools` bin), and binding the card to one of those would end
        // it when the helper exits.
        (candidatePids ?? ProcessTable.allProcessIds()).filter { pid in
            ProcessTable.getProcessArgs(pid).map(isMinimaxProcessArgs) ?? false
        }
    }

    static func isMinimaxProcessArgs(_ args: [String]) -> Bool {
        args.contains { arg in
            let lowered = arg.lowercased()
            return lowered == "minimax-code"
                || lowered.hasSuffix("/bin/mcode")
                || lowered.hasSuffix("/@minimax-ai/code/cli.js")
        }
    }

    /// pi and Oh My Pi. A `bin` entry is the program's whole name: as a
    /// substring, `/bin/pi` also took pinentry (which gpg starts to sign a
    /// commit), pigz, pico and any other program whose name starts with "pi".
    static func findPiPids(
        candidatePids: [pid_t]? = nil,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) },
        arguments: (pid_t) -> [String]? = { ProcessTable.getProcessArgs($0) }
    ) -> [pid_t] {
        findPids(
            matchingPathSubstrings: ["/pi-coding-agent/"],
            pathSuffixes: ["/bin/pi", "/bin/omp"],
            argSubstrings: [
                "pi-coding-agent",
                "/.local/bin/omp",
            ],
            candidatePids: candidatePids,
            executablePath: executablePath,
            arguments: arguments
        )
    }

    static func findKiroPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        let pids = findPids(
            matchingPathSubstrings: [
                "/Application Support/kiro-cli/",
                "/kiro-cli",
            ],
            pathSuffixes: [
                "/bin/kiro",
                "/bin/kiro-cli",
                "/kiro",
                "/kiro-cli",
            ],
            argSubstrings: [
                "kiro-cli",
                "/kiro-cli",
            ],
            candidatePids: candidatePids
        )
        let pidSet = Set(pids)
        return pids.filter { pid in
            guard let parent = ProcessTable.parentPID(for: pid) else { return true }
            return !pidSet.contains(parent)
        }
    }

    static func findCopilotPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/@github/copilot/npm-loader.js",
                "/opt/homebrew/bin/copilot",
            ],
            candidatePids: candidatePids
        )
    }

    private static func findClinePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        // Cline is a VSCode extension — it has no standalone CLI process.
        // Do NOT monitor VSCode main process as that causes crashes.
        // Session discovery still works via file-based scanning (taskHistory.json).
        return []
    }

    static func findOpenCodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opencode.app/contents/macos/opencode",
                "/opencode.app/contents/macos/opencode-cli",
                "/.opencode/bin/opencode",
            ],
            candidatePids: candidatePids
        ).filter { pid in
            // OpenCode 2's shared background service is the same executable as
            // the TUI and inherits the first client's cwd, so a cwd match can
            // land on it. It is not a session's process: it outlives the client
            // that spawned it, and once reparented to launchd the orphan sweep
            // would SIGTERM it — every session with it (#332).
            guard let args = ProcessTable.getProcessArgs(pid) else { return true }
            return !isOpenCodeSharedService(arguments: args)
        }
    }

    /// The `mimo` CLI (MiMo Code). The Xiaomi MiMo desktop app is left out on
    /// purpose: its engine shares the app's main process, whose cwd is `/`, so
    /// a cwd match could never pick one of its sessions — its plugin reports
    /// the process instead.
    static func findMimoPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        (candidatePids ?? ProcessTable.allProcessIds()).filter { pid in
            guard let path = ProcessTable.executablePath(for: pid) else { return false }
            return CLIProcessResolver.isMimoCLIPath(path)
        }
    }

    /// `opencode serve --service` — OpenCode 2's per-user shared server.
    static func isOpenCodeSharedService(arguments: [String]) -> Bool {
        arguments.contains("serve") && arguments.contains("--service")
    }

    /// Find running Codex processes.
    /// Checks both executable path (Desktop app) and command-line args (npm/Homebrew: node script).
    static func isCodexExecutablePath(_ path: String) -> Bool {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        let lowerPath = executableURL.path.lowercased()
        let resourceSuffix = "/contents/resources/codex"
        guard lowerPath.hasSuffix(resourceSuffix) else { return false }

        let appURL = executableURL
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.app
        return isCodexHostAppBundle(appURL)
    }

    /// The Codex binary newer ChatGPT releases bundle in place of
    /// `Contents/Resources/codex`. Desktop's app-server, ChatGPT's terminal
    /// launcher (`codex-cli/bin/codex`) and its cloud `exec-server` all run
    /// this one file, so the path says Codex, not Desktop.
    static func isBundledCodexCLIPath(_ path: String) -> Bool {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        let suffix = "/" + AppState.bundledCodexCLIRelativePath.lowercased()
        guard executableURL.path.lowercased().hasSuffix(suffix) else { return false }
        var appURL = executableURL
        for _ in AppState.bundledCodexCLIRelativePath.split(separator: "/") {
            appURL.deleteLastPathComponent()
        }
        return isCodexHostAppBundle(appURL)
    }

    private static func isCodexHostAppBundle(_ appURL: URL) -> Bool {
        // Since Codex was folded into ChatGPT Desktop, the same com.openai.codex
        // bundle can now be installed as ChatGPT.app instead of Codex.app. Read
        // the bundle identifier first so future app renames continue to work.
        if Bundle(url: appURL)?.bundleIdentifier == AppState.codexAppBundleId {
            return true
        }

        // Keep the legacy path check for synthetic/test bundles without an
        // Info.plist and for older installations whose bundle cannot be read.
        let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
        return appName == "codex" || appName == "chatgpt"
    }

    private static func findCodexPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findCodexProcesses(candidatePids: candidatePids).map(\.pid)
    }

    /// Running Codex processes discovery maps rollouts to, and whether each
    /// is Codex Desktop's shared app-server.
    static func findCodexProcesses(candidatePids: [pid_t]? = nil) -> [(pid: pid_t, isDesktop: Bool)] {
        var processes: [(pid: pid_t, isDesktop: Bool)] = []

        for pid in candidatePids ?? ProcessTable.allProcessIds() {
            guard let path = ProcessTable.executablePath(for: pid) else { continue }
            let pathLower = path.lowercased()

            // Match 1: Codex Desktop app (native binary). The executable may
            // live under Codex.app or ChatGPT.app depending on the release.
            if isCodexExecutablePath(path) {
                processes.append((pid, true))
                continue
            }

            // Match 2: the binary newer ChatGPT releases bundle, shared by
            // Desktop's app-server and Codex CLI; argv and parent tell them apart.
            if isBundledCodexCLIPath(path) {
                if let role = bundledCodexProcessRole(pid: pid, executablePath: path) {
                    processes.append((pid, role == .desktopHost))
                }
                continue
            }

            // Match 3: npm/Homebrew install — node running @openai/codex script.
            // proc_pidpath returns the node binary, so check command-line args instead.
            if pathLower.hasSuffix("/node") {
                if let args = ProcessTable.getProcessArgs(pid),
                   args.contains(where: { $0.contains("@openai/codex") || $0.contains("openai-codex") }) {
                    processes.append((pid, false))
                }
            }
        }
        return processes
    }

    private static func bundledCodexProcessRole(pid: pid_t, executablePath path: String) -> CodexProcessRole? {
        let parent = ProcessTable.parentPid(of: pid)
        // CodeIsland's own app-server client runs this binary too, from `/`;
        // as a session process it would claim every CLI rollout.
        if parent == getpid() { return nil }

        var ancestry = [ProcessAncestor(pid: pid, executablePath: path, arguments: ProcessTable.getProcessArgs(pid) ?? [])]
        if let parent, let parentPath = ProcessTable.executablePath(for: parent) {
            ancestry.append(ProcessAncestor(
                pid: parent,
                executablePath: parentPath,
                bundleIdentifier: HostHarnessResolver.outermostAppBundlePath(forExecutable: parentPath)
                    .flatMap { Bundle(path: $0)?.bundleIdentifier }
            ))
        }
        return CLIProcessResolver.codexBundledProcessRole(ancestry: ancestry)
    }
}
