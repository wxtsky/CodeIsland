import AppKit
import Darwin
import SQLite3
import CodeIslandCore

/// Process-side half of host-harness support (#321): reads the agent's
/// ancestry, verifies the harness server, and performs the jump. The matching
/// rules themselves live in `HostHarnessResolver` (CodeIslandCore) so they
/// stay pure and tested.
enum HostHarnessSupport {
    /// Outcome of one ancestry probe. `conclusive` is false when the walk
    /// could not even read the starting process (it exited before we looked);
    /// only conclusive results are worth caching.
    struct ProbeResult: Sendable {
        let harness: HostHarness?
        let conclusive: Bool
    }

    private static let environmentKeys: Set<String> = ["T3CODE_HOME"]

    /// Walk `cliPid`'s ancestry and resolve the hosting harness, if any.
    /// Blocking (sysctl + a small file read) — call off the main actor.
    nonisolated static func probe(cliPid: pid_t) -> ProbeResult {
        let ancestry = collectAncestry(from: cliPid)
        guard !ancestry.isEmpty else { return ProbeResult(harness: nil, conclusive: false) }
        guard var harness = HostHarnessResolver.detect(
            ancestry: ancestry,
            homeDirectory: NSHomeDirectory()
        ) else {
            return ProbeResult(harness: nil, conclusive: true)
        }
        if case .browser = harness.surface {
            verifyBrowserOrigin(&harness)
        }
        return ProbeResult(harness: harness, conclusive: true)
    }

    // MARK: - Ancestry

    private nonisolated static func collectAncestry(from pid: pid_t) -> [ProcessAncestor] {
        var result: [ProcessAncestor] = []
        var current = pid
        var visited = Set<pid_t>()
        while current > 1, !visited.contains(current), result.count < HostHarnessResolver.maxAncestryDepth {
            visited.insert(current)
            guard let parent = parentPID(of: current) else { break }
            let path = executablePath(for: current)
            let parsed = procArgs(for: current)
            result.append(ProcessAncestor(
                pid: current,
                executablePath: path,
                arguments: parsed?.arguments ?? [],
                environment: parsed?.environment ?? [:],
                bundleIdentifier: path.flatMap(bundleIdentifier(forExecutable:))
            ))
            current = parent
        }
        return result
    }

    private nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private nonisolated static func procArgs(for pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcArgsParser.parse(Array(buffer.prefix(size)), environmentKeys: environmentKeys)
    }

    private nonisolated static func bundleIdentifier(forExecutable path: String) -> String? {
        guard let appPath = HostHarnessResolver.outermostAppBundlePath(forExecutable: path) else { return nil }
        return Bundle(path: appPath)?.bundleIdentifier
    }

    // MARK: - T3 browser server

    /// Pin the browser origin to the state directory whose runtime file was
    /// written by this very server process. Without a match the harness stays
    /// un-jumpable (hidden affordance) instead of guessing a port.
    private nonisolated static func verifyBrowserOrigin(_ harness: inout HostHarness) {
        for directory in harness.stateDirectories {
            let path = (directory as NSString).appendingPathComponent("server-runtime.json")
            guard let data = FileManager.default.contents(atPath: path),
                  let origin = HostHarnessResolver.t3BrowserOrigin(runtimeJSON: data, expectedPid: harness.serverPid) else {
                continue
            }
            harness.browserOrigin = origin
            harness.stateDirectories = [directory]
            return
        }
    }

    /// Thread URL when T3's state maps this agent session to a thread, else
    /// T3's root (its thread list). The mapping is read at click time — the
    /// harness records it lazily — from T3's internal `provider_session_runtime`
    /// table; a schema change there degrades to the root URL, never to a
    /// wrong thread.
    nonisolated static func t3BrowserURL(
        harness: HostHarness,
        sessionId: String?,
        session: SessionSnapshot
    ) -> URL? {
        guard let origin = harness.browserOrigin else { return nil }
        guard let directory = harness.stateDirectories.first, let sessionId else {
            return HostHarnessResolver.t3BrowserURL(origin: origin, environmentId: nil, threadId: nil)
        }
        let environmentId = (try? String(
            contentsOfFile: (directory as NSString).appendingPathComponent("environment-id"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = HostHarnessResolver.providerSessionIdCandidates(
            sessionId: sessionId,
            source: session.source,
            providerSessionId: session.providerSessionId
        )
        let threadId = environmentId == nil ? nil : lookupT3ThreadId(
            databasePath: (directory as NSString).appendingPathComponent("state.sqlite"),
            providerSessionIds: candidates
        )
        return HostHarnessResolver.t3BrowserURL(origin: origin, environmentId: environmentId, threadId: threadId)
    }

    private nonisolated static func lookupT3ThreadId(databasePath: String, providerSessionIds: [String]) -> String? {
        guard !providerSessionIds.isEmpty, FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 500)

        // Claude records its session id as `resume`, OpenCode/Cursor as
        // `sessionId`, Codex its thread id as `threadId`. LIMIT 2 so an
        // ambiguous match is detected and refused rather than guessed.
        let sql = """
            SELECT thread_id FROM provider_session_runtime
            WHERE json_extract(resume_cursor_json, '$.resume') = ?1
               OR json_extract(resume_cursor_json, '$.sessionId') = ?1
               OR json_extract(resume_cursor_json, '$.threadId') = ?1
            LIMIT 2;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for candidate in providerSessionIds {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, candidate, -1, transient)
            var matches: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    matches.append(String(cString: text))
                }
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    // MARK: - Jump

    /// Bring the harness forward for this session. Returns false when there
    /// is nowhere verified to go (callers hide the affordance in that case,
    /// so this is a safety net, not a user-visible path).
    @discardableResult
    static func activate(harness: HostHarness, session: SessionSnapshot, sessionId: String?) -> Bool {
        switch harness.surface {
        case .desktopApp(let bundleId):
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                if app.isHidden { app.unhide() }
                app.activate()
            }
            if let url = TerminalActivator.appURL(forBundleId: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
            return false
        case .browser:
            guard harness.browserOrigin != nil else { return false }
            // The sqlite read is small but still I/O; keep it off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let url = t3BrowserURL(harness: harness, sessionId: sessionId, session: session) else { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return true
        }
    }

    /// Did the jump land? Desktop: the harness app is frontmost. Browser: the
    /// default web browser is frontmost — which tab is showing is not
    /// observable, so this is app-level only (like Warp/Alacritty).
    static func isFrontmost(_ harness: HostHarness) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
        switch harness.surface {
        case .desktopApp(let bundleId):
            return front == bundleId.lowercased()
        case .browser:
            guard let probe = URL(string: "http://localhost"),
                  let browserURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
                  let browserId = Bundle(url: browserURL)?.bundleIdentifier?.lowercased() else {
                return false
            }
            return front == browserId
        }
    }
}
