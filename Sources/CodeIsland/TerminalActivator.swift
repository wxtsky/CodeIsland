import AppKit
import CodeIslandCore

/// Activates the terminal window/tab running a specific Claude Code session.
/// Supports tab-level switching for: Ghostty, iTerm2, Terminal.app, WezTerm, kitty.
/// Falls back to app-level activation for: Alacritty, Warp, Hyper, Tabby, Rio.
struct TerminalActivator {
    private static let knownTerminals: [(name: String, bundleId: String)] = [
        ("cmux", "com.cmuxterm.app"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    /// Fallback: source-based app jump for CLIs with NO terminal mode.
    /// Most sources should use nativeAppBundles instead (by bundle ID).
    private static let appSources: [String: String] = [:]

    /// Reverse map: source → native app bundle ID. Used as a fallback when
    /// termBundleId is missing but the source's desktop app is running.
    static let sourceToNativeAppBundleId: [String: String] = [
        "codex": "com.openai.codex",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "trae": "com.trae.app",
        "traecn": "com.trae.app",
        "qoder": "com.qoder.ide",
        "droid": "com.factory.app",
        "codebuddy": "com.tencent.codebuddy",
        "codybuddycn": "com.tencent.codebuddy.cn",
        "stepfun": "com.stepfun.app",
        "opencode": "ai.opencode.desktop",
        "workbuddy": "com.workbuddy.workbuddy",
    ]

    /// Bundle IDs of apps that have both APP and CLI modes.
    /// When termBundleId matches, bring that app to front;
    /// otherwise fall through to terminal tab-matching.
    private static let nativeAppBundles: [String: String] = [
        "com.openai.codex": "Codex",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.trae.app": "Trae",
        "com.qoder.ide": "Qoder",
        "com.factory.app": "Factory",
        "com.tencent.codebuddy": "CodeBuddy",
        "com.tencent.codebuddy.cn": "CodyBuddyCN",
        "com.stepfun.app": "StepFun",
        "ai.opencode.desktop": "OpenCode",
        "com.workbuddy.workbuddy": "WorkBuddy",
    ]

    static func activate(session: SessionSnapshot, sessionId: String? = nil) {
        guard !session.isRemote else { return }

        // Native app by bundle ID (e.g. Codex APP vs Codex CLI)
        if let bundleId = session.termBundleId,
           nativeAppBundles[bundleId] != nil {
            activateByBundleId(bundleId)
            return
        }

        // IDE integrated terminal: try window-level matching by CWD, fall back to app-level
        if session.isIDETerminal,
           let bundleId = session.termBundleId {
            activateIDEWindow(bundleId: bundleId, cwd: session.cwd)
            return
        }

        // IDE sources: just bring the app to front
        if let appName = appSources[session.source] {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == appName
            }) {
                if app.isHidden { app.unhide() }
                app.activate()
            } else {
                bringToFront(appName)
            }
            return
        }

        // When termBundleId is missing and the source has a known desktop app that's
        // running, prefer the desktop app over possibly-stale TERM_PROGRAM env. This
        // handles e.g. OpenCode CLI launched from Ghostty but editing in VS Code — without
        // this, the inherited TERM_PROGRAM=ghostty would jump to the wrong terminal.
        if session.termBundleId == nil,
           let nativeBundleId = sourceToNativeAppBundleId[session.source],
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == nativeBundleId }) {
            activateByBundleId(nativeBundleId)
            return
        }

        // Resolve terminal: bundle ID (most accurate) → TERM_PROGRAM → scan running apps
        let termApp: String
        if let bundleId = session.termBundleId,
           let resolved = knownTerminals.first(where: { $0.bundleId == bundleId })?.name {
            termApp = resolved
        } else {
            let raw = session.termApp ?? ""
            // "tmux" / "screen" etc. are not GUI apps — fall back to scanning
            if raw.isEmpty || raw.lowercased() == "tmux" || raw.lowercased() == "screen" {
                termApp = detectRunningTerminal()
            } else {
                termApp = raw
            }
        }
        let lower = termApp.lowercased()

        // --- tmux: switch pane first, then fall through to terminal-specific activation ---
        if let pane = session.tmuxPane, !pane.isEmpty {
            activateTmux(pane: pane, tmuxEnv: session.tmuxEnv)
        }

        // In tmux, use the client TTY (outer terminal) for tab matching,
        // since ttyPath is the inner tmux pty which won't match the terminal's tab.
        // When tmux is detached (no client TTY), set effectiveTty to nil so terminal-specific
        // handlers skip useless TTY matching and fall back to CWD or app-level activation.
        let inTmux = session.tmuxPane != nil && !(session.tmuxPane ?? "").isEmpty
        let effectiveTty: String?
        if inTmux {
            effectiveTty = session.tmuxClientTty  // nil when detached — intentional
        } else {
            effectiveTty = session.ttyPath
        }

        // --- cmux: surface-level precise jump (workspace + surface) ---
        // Must be handled before generic tab-switching logic to avoid degrading to bringToFront
        if lower.contains("cmux") {
            activateCmux(
                surfaceId: session.cmuxSurfaceId,
                workspaceId: session.cmuxWorkspaceId
            )
            return
        }

        // --- Tab-level switching (5 terminals) ---

        if lower.contains("iterm") {
            if let itermId = session.itermSessionId, !itermId.isEmpty {
                activateITerm(sessionId: itermId)
            } else {
                // No session ID — fall back to tty or cwd matching
                activateITermByTtyOrCwd(tty: effectiveTty, cwd: session.cwd)
            }
            return
        }

        if lower == "ghostty" {
            activateGhostty(
                cwd: session.cwd,
                tty: effectiveTty,
                sessionId: sessionId,
                source: session.source,
                tmuxPane: session.tmuxPane,
                tmuxEnv: session.tmuxEnv
            )
            return
        }

        // Match Terminal.app by bundle ID only — Warp sets TERM_PROGRAM=Apple_Terminal
        if session.termBundleId == "com.apple.Terminal" || (session.termBundleId == nil && lower == "terminal") {
            activateTerminalApp(ttyPath: effectiveTty, cwd: session.cwd)
            return
        }

        if lower.contains("wezterm") || lower.contains("wez") {
            activateWezTerm(ttyPath: effectiveTty, cwd: session.cwd)
            return
        }

        if lower.contains("kitty") {
            activateKitty(windowId: session.kittyWindowId, cwd: session.cwd, source: session.source)
            return
        }

        // --- Warp (SQLite pane precision jump + Cmd+N tab switch) ---
        if lower.contains("warp") {
            activateWarp(cwd: session.cwd)
            return
        }

        // --- Other terminals (Alacritty, Hyper, Tabby, Rio, etc.) ---
        // Try window-level matching via System Events (title contains CWD folder name),
        // similar to IDE window matching. Falls back to app-level if no match.
        if let bundleId = session.termBundleId, let cwd = session.cwd, !cwd.isEmpty {
            activateTerminalWindow(bundleId: bundleId, cwd: cwd, fallbackName: termApp)
        } else {
            bringToFront(termApp)
        }
    }

    // MARK: - Ghostty (AppleScript: match by CWD + session ID in title)

    private static func activateGhostty(
        cwd: String?,
        tty: String? = nil,
        sessionId: String? = nil,
        source: String = "claude",
        tmuxPane: String? = nil,
        tmuxEnv: String? = nil
    ) {
        guard let cwd = cwd, !cwd.isEmpty else { bringToFront("Ghostty"); return }
        // Ensure app is running, unhidden, and brought to front (Space switching)
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            bringToFront("Ghostty")
            return
        }
        if app.isHidden { app.unhide() }
        // Don't call app.activate() here — it triggers Ghostty's quick terminal.
        // The AppleScript's `focus t; activate` below will activate after focusing
        // the correct terminal window.

        // The remaining work (tmux key resolution + AppleScript construction +
        // osascript dispatch) is the last subprocess-bound path that wasn't
        // already off-main — match the rest of the activator and run it on a
        // userInitiated background queue so a stuck `tmux display-message`
        // can't freeze the UI. See #139.
        DispatchQueue.global(qos: .userInitiated).async {
        // Resolve tmux title prefix (most reliable for tmux sessions in Ghostty).
        // Example Ghostty title often contains: "<session>:<winIdx>:<winName> - ..."
        var tmuxKey = ""
        var tmuxSession = ""
        if let pane = tmuxPane?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pane.isEmpty,
           let tmuxBin = findBinary("tmux") {
            // Try full key first, fall back to session name only
            let formats = [
                "#{session_name}:#{window_index}:#{window_name}",
                "#{session_name}",
            ]
            for fmt in formats {
                if let data = runProcess(tmuxBin, args: ["display-message", "-p", "-t", pane, "-F", fmt], env: tmuxProcessEnv(tmuxEnv)),
                   let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !result.isEmpty {
                    if fmt.contains("window_index") {
                        tmuxKey = result
                        if let first = result.split(separator: ":").first { tmuxSession = String(first) }
                    } else {
                        tmuxSession = result
                    }
                    break
                }
            }
        }

        // Normalize CWD variants:
        // - trim whitespace
        // - strip trailing slashes (except "/")
        // - include symlink-resolved path variant
        func stripTrailingSlashes(_ path: String) -> String {
            var p = path
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd1 = stripTrailingSlashes(trimmedCwd)
        let cwd2 = stripTrailingSlashes(URL(fileURLWithPath: cwd1).resolvingSymlinksInPath().path)
        let dirName = (cwd1 as NSString).lastPathComponent

        let home = NSHomeDirectory()
        let tildeCwd: String = {
            if cwd1 == home { return "~" }
            if cwd1.hasPrefix(home + "/") {
                return "~" + String(cwd1.dropFirst(home.count))
            }
            return ""
        }()

        let escapedCwd1 = escapeAppleScript(cwd1)
        let escapedCwd2 = escapeAppleScript(cwd2)
        let escapedDir = escapeAppleScript(dirName)
        let escapedTilde = escapeAppleScript(tildeCwd)
        let escapedTmux = escapeAppleScript(tmuxKey)
        let escapedTmuxSession = escapeAppleScript(tmuxSession)

        // Match order:
        // 1) tmux title prefix (when available)
        // 2) session ID in title (disambiguates same-CWD sessions)
        // 3) source keyword in title ("claude"/"codex"/...)
        // 4) CWD match (working directory), then title-based fallback
        let idFilter: String
        if let sid = sessionId, !sid.isEmpty {
            let escapedSid = escapeAppleScript(String(sid.prefix(8)))
            idFilter = """
                repeat with t in matches
                    if name of t contains "\(escapedSid)" then
                        focus t
                        activate
                        return
                    end if
                end repeat
            """
        } else {
            idFilter = ""
        }
        let keyword = escapeAppleScript(source)
        let script = """
        tell application "Ghostty"
            set allTerms to terminals

            -- 1) tmux: match by tmux title prefix first (more robust than CWD in tmux)
            set tmuxKey to "\(escapedTmux)"
            set tmuxSession to "\(escapedTmuxSession)"

            -- 1a) exact window key when available: "<session>:<winIdx>:<winName>"
            if tmuxKey is not "" then
                repeat with t in allTerms
                    try
                        if name of t contains tmuxKey then
                            focus t
                            activate
                            return
                        end if
                    end try
                end repeat
            end if

            -- 1b) tmuxcc-style fallback: title starts with "<session>:"
            if tmuxSession is not "" then
                repeat with t in allTerms
                    try
                        set tname to (name of t as text)
                        if tname starts with (tmuxSession & ":") then
                            focus t
                            activate
                            return
                        end if
                    end try
                end repeat
            end if

            -- 2) TTY: Ghostty does not currently expose a `tty` property (only uuid,
            -- title, working directory). This block is kept for future-proofing and
            -- silently skips via try if the property doesn't exist.
            \(tty.map { t in
                let escaped = escapeAppleScript(t)
                return """
                if "\(escaped)" is not "" then
                    try
                        set ttyMatches to (every terminal whose tty is "\(escaped)")
                        if (count of ttyMatches) > 0 then
                            focus (item 1 of ttyMatches)
                            activate
                            return
                        end if
                    end try
                end if
                """
            } ?? "")

            -- 3) CWD: exact match on Ghostty's working directory property
            set matches to {}
            set cwd1 to "\(escapedCwd1)"
            set cwd2 to "\(escapedCwd2)"
            if cwd1 is not "" then
                try
                    set matches to (every terminal whose working directory is cwd1)
                end try
            end if
            if (count of matches) = 0 and cwd2 is not "" and cwd2 is not cwd1 then
                try
                    set matches to (every terminal whose working directory is cwd2)
                end try
            end if

            -- 4) Fallback: match by title when Ghostty can't report the true working directory (common in tmux)
            if (count of matches) = 0 then
                set dirName to "\(escapedDir)"
                set tildeCwd to "\(escapedTilde)"
                repeat with t in allTerms
                    try
                        set tname to (name of t as text)
                        if (tildeCwd is not "" and tname contains tildeCwd) or (cwd1 is not "" and tname contains cwd1) or (dirName is not "" and tname contains dirName) then
                            set end of matches to t
                        end if
                    end try
                end repeat
            end if

            \(idFilter)
            repeat with t in matches
                if name of t contains "\(keyword)" then
                    focus t
                    activate
                    return
                end if
            end repeat
            if (count of matches) > 0 then
                focus (item 1 of matches)
            end if
            activate
        end tell

        -- Final fallback via System Events: Ghostty's own `focus`/`activate` is unreliable
        -- in some versions (issue #84), and even when it brings the app to front it doesn't
        -- deminiaturize a window that's currently minimized to the dock. System Events
        -- Accessibility API forces both. Wrapped in `try` so it silently no-ops if the
        -- user hasn't granted Accessibility permission.
        try
            tell application "System Events"
                tell process "Ghostty"
                    set frontmost to true
                    repeat with w in windows
                        try
                            if value of attribute "AXMinimized" of w is true then
                                set value of attribute "AXMinimized" of w to false
                            end if
                        end try
                    end repeat
                end tell
            end tell
        end try
        """
        // Use /usr/bin/osascript to run AppleScript out-of-process (tmuxcc uses the same approach).
        // This avoids relying on NSAppleScript execution inside the app process.
        // Already on a background queue (see DispatchQueue.global wrap above) — call the
        // _Sync variant to skip an extra dispatch hop.
        runOsaScriptSync(script)
        } // end DispatchQueue.global async
    }

    // MARK: - iTerm2 (AppleScript: match by session ID, tty, or cwd)

    /// Fallback when iTerm2 session ID is unavailable: try tty match, then cwd/name match.
    private static func activateITermByTtyOrCwd(tty: String?, cwd: String?) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else {
            bringToFront("iTerm2")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()
        // Strategy 1: match by tty (precise)
        if let tty = tty, !tty.isEmpty {
            let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            let script = """
            try
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if tty of s is "\(escapeAppleScript(fullTty))" then
                                        select t
                                        select s
                                        set index of w to 1
                                        return
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                end tell
            end try
            """
            runAppleScript(script)
            return
        }
        // Strategy 2: match by cwd directory name in session name/path
        guard let cwd = cwd, !cwd.isEmpty else { return }
        let dirName = (cwd as NSString).lastPathComponent
        let script = """
        try
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if name of s contains "\(escapeAppleScript(dirName))" or path of s contains "\(escapeAppleScript(dirName))" then
                                    select t
                                    select s
                                    set index of w to 1
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
        end try
        """
        runAppleScript(script)
    }

    private static func activateITerm(sessionId: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else {
            bringToFront("iTerm2")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()
        let script = """
        try
            tell application "iTerm2"
                repeat with aWindow in windows
                    if miniaturized of aWindow then set miniaturized of aWindow to false
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if unique ID of aSession is "\(escapeAppleScript(sessionId))" then
                                set miniaturized of aWindow to false
                                select aTab
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end try
        """
        runAppleScript(script)
    }

    // MARK: - Terminal.app (AppleScript: match by TTY, fallback to CWD)

    private static func activateTerminalApp(ttyPath: String?, cwd: String?) {
        // If Terminal.app is not running, launch it and return — no tab matching possible.
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Terminal"
        }) else {
            bringToFront("Terminal")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()

        let ttyEscaped = ttyPath.map(escapeAppleScript) ?? ""
        let dirEscaped = cwd.map { escapeAppleScript(($0 as NSString).lastPathComponent) } ?? ""

        // Try tty → tab auto-name → user custom title → deminiaturize any window as a last resort.
        // Terminal.app auto-generates `name of t` containing the running command + cwd; `custom title`
        // only exists when the user set it explicitly, so matching against `name` works for the
        // overwhelming default case.
        // Note: locals named `targetTty` / `targetDir` (NOT `tty` / `dir`). AppleScript's
        // resolver can't reliably tell `if tty of t is tty` apart from `if tty of t is
        // tty of <implicit object>` — `tty` is also a tab property name, so reusing it as
        // a local variable causes Strategy 1 to silently misfire and Strategy 2 to
        // fall through, which manifested as "click any session, jumps to the same tab"
        // (issue #124).
        let script = """
        tell application "Terminal"
            set targetTty to "\(ttyEscaped)"
            set targetDir to "\(dirEscaped)"
            set found to false

            -- Strategy 1: precise tty match
            if targetTty is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is targetTty then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                set found to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if found then exit repeat
                end repeat
            end if

            -- Strategy 2: auto tab title contains the cwd folder name
            if not found and targetDir is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (name of t as text) contains targetDir then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                set found to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if found then exit repeat
                end repeat
            end if

            -- Strategy 3: user-set custom title
            if not found and targetDir is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if custom title of t contains targetDir then
                                if miniaturized of w then set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                set found to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if found then exit repeat
                end repeat
            end if

            -- Fallback: unminimize the first miniaturized window so the user always sees something.
            if not found then
                repeat with w in windows
                    try
                        if miniaturized of w then
                            set miniaturized of w to false
                            set index of w to 1
                            exit repeat
                        end if
                    end try
                end repeat
            end if

            activate
        end tell

        -- Final fallback via System Events: when Terminal.app's `windows` collection doesn't
        -- include a minimized window (some macOS 14 cases), or when osascript silently no-ops,
        -- force both frontmost and AXMinimized=false through Accessibility (issue #124).
        try
            tell application "System Events"
                tell process "Terminal"
                    set frontmost to true
                    repeat with w in windows
                        try
                            if value of attribute "AXMinimized" of w is true then
                                set value of attribute "AXMinimized" of w to false
                            end if
                        end try
                    end repeat
                end tell
            end tell
        end try
        """
        runAppleScript(script)
    }

    // MARK: - WezTerm (CLI: wezterm cli list + activate-tab)

    private static func activateWezTerm(ttyPath: String?, cwd: String?) {
        bringToFront("WezTerm")
        guard let bin = findBinary("wezterm") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let json = runProcess(bin, args: ["cli", "list", "--format", "json"]),
                  let panes = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return }

            // Find tab: prefer TTY match, fallback to CWD
            var tabId: Int?
            if let tty = ttyPath {
                tabId = panes.first(where: { ($0["tty_name"] as? String) == tty })?["tab_id"] as? Int
            }
            if tabId == nil, let cwd = cwd {
                let cwdUrl = "file://" + cwd
                tabId = panes.first(where: {
                    guard let paneCwd = $0["cwd"] as? String else { return false }
                    return paneCwd == cwdUrl || paneCwd == cwd
                })?["tab_id"] as? Int
            }

            if let id = tabId {
                _ = runProcess(bin, args: ["cli", "activate-tab", "--tab-id", "\(id)"])
            }
        }
    }

    // MARK: - kitty (CLI: kitten @ focus-window/focus-tab)

    private static func activateKitty(windowId: String?, cwd: String?, source: String = "claude") {
        bringToFront("kitty")
        guard let bin = findBinary("kitten") else { return }

        // Prefer window ID for precise switching
        if let windowId = windowId, !windowId.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = runProcess(bin, args: ["@", "focus-window", "--match", "id:\(windowId)"])
            }
            return
        }

        // Fallback to CWD matching, then title with source keyword
        guard let cwd = cwd, !cwd.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if runProcess(bin, args: ["@", "focus-tab", "--match", "cwd:\(cwd)"]) == nil {
                _ = runProcess(bin, args: ["@", "focus-tab", "--match", "title:\(source)"])
            }
        }
    }

    // MARK: - tmux (CLI: tmux select-window/select-pane)

    private static func activateTmux(pane: String, tmuxEnv: String? = nil) {
        guard let bin = findBinary("tmux") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Switch to the window containing the pane, then select the pane
            _ = runProcess(bin, args: ["select-window", "-t", pane], env: tmuxProcessEnv(tmuxEnv))
            _ = runProcess(bin, args: ["select-pane", "-t", pane], env: tmuxProcessEnv(tmuxEnv))
        }
    }

    // MARK: - IDE window-level activation (JetBrains, VS Code, Zed, etc.)

    /// Activate the specific IDE window whose title contains the project folder name.
    /// Falls back to app-level activation if no CWD or no matching window found.
    private static func activateIDEWindow(bundleId: String, cwd: String?) {
        guard let cwd = cwd, !cwd.isEmpty else {
            activateByBundleId(bundleId)
            return
        }
        let folderName = (cwd as NSString).lastPathComponent
        guard !folderName.isEmpty else {
            activateByBundleId(bundleId)
            return
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            activateByBundleId(bundleId)
            return
        }

        if app.isHidden { app.unhide() }
        app.activate()

        // Use System Events to iterate windows and AXRaise the best match.
        // Priority: exact folder name at word boundary > shortest title containing folder name.
        // This avoids jumping to the wrong window when multiple projects share a folder name
        // (e.g., /work/app vs /backup/app).
        let appName = app.localizedName ?? "Application"
        let escapedFolder = escapeAppleScript(folderName)
        let script = """
        tell application "System Events"
            tell process "\(escapeAppleScript(appName))"
                set frontmost to true
                set bestWindow to missing value
                set bestLen to 999999
                repeat with w in windows
                    try
                        set wName to name of w as text
                        if wName contains "\(escapedFolder)" then
                            set wLen to count of wName
                            if wLen < bestLen then
                                set bestWindow to w
                                set bestLen to wLen
                            end if
                        end if
                    end try
                end repeat
                if bestWindow is not missing value then
                    perform action "AXRaise" of bestWindow
                end if
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Generic terminal window matching (Alacritty, Warp, Hyper, etc.)

    /// For terminals without tab-switching APIs, try to raise the window whose title
    /// contains the project folder name via System Events. Falls back to app-level.
    private static func activateTerminalWindow(bundleId: String, cwd: String, fallbackName: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            bringToFront(fallbackName)
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()

        let folderName = (cwd as NSString).lastPathComponent
        guard !folderName.isEmpty else { return }

        let appName = app.localizedName ?? fallbackName
        let script = """
        tell application "System Events"
            tell process "\(escapeAppleScript(appName))"
                repeat with w in windows
                    try
                        if name of w contains "\(escapeAppleScript(folderName))" then
                            perform action "AXRaise" of w
                            return
                        end if
                    end try
                end repeat
            end tell
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - Activate by bundle ID

    private static func activateByBundleId(_ bundleId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
        }
        // Also use openApplication for reliable Space switching (Electron apps like VSCode)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Generic (bring app to front)

    private static func bringToFront(_ termApp: String) {
        let name: String
        let lower = termApp.lowercased()
        if lower.contains("cmux") { name = "cmux" }
        else if lower == "ghostty" { name = "Ghostty" }
        else if lower.contains("iterm") { name = "iTerm2" }
        else if lower.contains("terminal") || lower.contains("apple_terminal") { name = "Terminal" }
        else if lower.contains("wezterm") || lower.contains("wez") { name = "WezTerm" }
        else if lower.contains("alacritty") || lower.contains("lacritty") { name = "Alacritty" }
        else if lower.contains("kitty") { name = "kitty" }
        else if lower.contains("warp") { name = "Warp" }
        else if lower.contains("hyper") { name = "Hyper" }
        else if lower.contains("tabby") { name = "Tabby" }
        else if lower.contains("rio") { name = "Rio" }
        else { name = termApp }

        // Try NSRunningApplication first — handles Space switching and unhide
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(name)
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
            return
        }
        // Fallback: open -a (app not running yet)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", name]
            try? proc.run()
        }
    }

    // MARK: - Helpers

    private static func detectRunningTerminal() -> String {
        let running = NSWorkspace.shared.runningApplications
        for (name, bundleId) in knownTerminals {
            if running.contains(where: { $0.bundleIdentifier == bundleId }) {
                return name
            }
        }
        return "Terminal"
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
    }

    private static func runOsaScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            runOsaScriptSync(source)
        }
    }

    /// Run osascript on the current queue (no extra dispatch). Use from
    /// callers that are already on a background queue to avoid the double
    /// hop activateGhostty would otherwise pay (#139 review).
    private static func runOsaScriptSync(_ source: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    /// Escape special characters for AppleScript string interpolation
    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Find a CLI binary in common paths (Homebrew Intel + Apple Silicon, system)
    /// Support extraPaths for priority search (e.g. app-bundled binaries like cmux)
    private static func findBinary(_ name: String, extraPaths: [String] = []) -> String? {
        let paths = extraPaths + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a process and return stdout. Returns nil on failure or timeout.
    /// 10s cap on each call so a stuck osascript / tmux invocation can't
    /// freeze the UI when activate() is dispatched on the main thread (#139).
    @discardableResult
    private static func runProcess(_ path: String, args: [String], env: [String: String]? = nil) -> Data? {
        ProcessRunner.run(path: path, args: args, env: env, timeout: 10)
    }

    private static func tmuxProcessEnv(_ tmuxEnv: String?) -> [String: String]? {
        guard let tmuxEnv = tmuxEnv?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tmuxEnv.isEmpty else { return nil }
        return ["TMUX": tmuxEnv]
    }

    // MARK: - cmux (CLI: focus-panel cross-workspace surface jump)

    /// Activate cmux and precisely focus on the specified surface.
    /// Prefers surface UUID (CMUX_SURFACE_ID); optionally pass workspace UUID to narrow scope.
    /// - Parameters:
    ///   - surfaceId: cmux surface UUID string (from CMUX_SURFACE_ID env var)
    ///   - workspaceId: cmux workspace UUID string (from CMUX_WORKSPACE_ID env var, optional)
    private static func activateCmux(surfaceId: String?, workspaceId: String?) {
        // Reuse activateByBundleId: unified handling of Space switching, hidden state, app not running, etc.
        activateByBundleId("com.cmuxterm.app")

        // No surface ID — degrade to app-level activation (already done above)
        guard let sid = surfaceId, !sid.isEmpty else { return }

        // Prefer bundle-embedded binary, then fall back to Homebrew / system paths
        guard let cmuxBin = findBinary("cmux", extraPaths: [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            NSHomeDirectory() + "/Applications/cmux.app/Contents/Resources/bin/cmux",
        ]) else { return }

        // Invoke focus-panel CLI asynchronously to avoid blocking the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["focus-panel", "--panel", sid]
            if let wid = workspaceId, !wid.isEmpty {
                args += ["--workspace", wid]
            }
            _ = runProcess(cmuxBin, args: args)
        }
    }

    // MARK: - Warp (SQLite pane lookup + optional tab keystroke)

    /// Bring Warp forward, and when the SQLite state shows that the target cwd lives
    /// in a non-active tab, send the default "go to tab N" keystroke (Cmd+digit).
    ///
    /// The keystroke path requires Accessibility permission; without it CGEvent.post
    /// becomes a silent no-op and we gracefully degrade to plain app activation —
    /// which is what the previous implementation did unconditionally, so this is a
    /// strict improvement rather than a regression risk.
    private static func activateWarp(cwd: String?) {
        let warpBundleId = "dev.warp.Warp-Stable"

        guard let warpApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == warpBundleId
        }) else {
            bringToFront("Warp")
            return
        }
        if warpApp.isHidden { warpApp.unhide() }
        warpApp.activate()

        guard let cwd, !cwd.isEmpty else { return }

        // SQLite I/O is fast (sub-ms on a warm cache) but run it off the main thread
        // anyway; we've already handed the user a visible activation.
        DispatchQueue.global(qos: .userInitiated).async {
            let resolver = WarpPaneResolver()
            let matches: [WarpPaneMatch]
            do {
                matches = try resolver.resolve(cwd: cwd)
            } catch {
                return
            }
            guard let best = matches.first else { return }
            if best.isActiveTab { return }

            let targetPosition = best.tabIndexInWindow + 1
            guard (1...9).contains(targetPosition) else { return }

            DispatchQueue.main.async {
                sendWarpGoToTab(position: targetPosition)
            }
        }
    }

    /// Synthesize Warp's default "jump to tab N" shortcut (Cmd+<digit>, 1-9) for the
    /// frontmost window. 10+ would require an extra keycode table; we bail for now.
    private static func sendWarpGoToTab(position: Int) {
        guard (1...9).contains(position) else { return }
        // ANSI virtual keycodes for digits 1..9 (QWERTY layout).
        let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keyCode = digitKeyCodes[position - 1]
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }
}
