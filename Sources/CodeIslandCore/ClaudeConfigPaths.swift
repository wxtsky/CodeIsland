import Foundation

/// Resolves the Claude Code configuration directory.
///
/// Claude Code honors `$CLAUDE_CONFIG_DIR` and falls back to `~/.claude`. CodeIsland is a
/// GUI app, so it is usually launched from Finder/login items and does **not** inherit the
/// user's shell environment — reading the env var alone is not enough. The chain below adds
/// a user-settable preference (the only thing that reliably survives a Finder launch) and a
/// probe of the common XDG-style location before defaulting.
///
/// Resolution order:
///   1. `claude_config_dir` user preference (Settings → set explicitly)
///   2. `$CLAUDE_CONFIG_DIR` (present when launched from a shell)
///   3. `~/.config/claude-code`, if it looks like a real config dir
///   4. `~/.claude`
public enum ClaudeConfigPaths {
    /// UserDefaults key backing the Settings field.
    public static let preferenceKey = "claude_config_dir"

    /// Absolute path to the resolved Claude config directory (no trailing slash).
    public static func configDir() -> String {
        resolve(
            preference: UserDefaults.standard.string(forKey: preferenceKey),
            environment: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
            homeDir: NSHomeDirectory(),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Where per-project transcripts live.
    public static func projectsDir() -> String { configDir() + "/projects" }

    /// The `settings.json` that holds hook configuration.
    public static func settingsPath() -> String { configDir() + "/settings.json" }

    /// Pure resolution core — all inputs injected so the fallback chain is testable
    /// without touching UserDefaults, the environment, or the real filesystem.
    public static func resolve(
        preference: String?,
        environment: String?,
        homeDir: String,
        fileExists: (String) -> Bool
    ) -> String {
        if let pref = normalized(preference, homeDir: homeDir) { return pref }
        if let env = normalized(environment, homeDir: homeDir) { return env }
        let xdg = homeDir + "/.config/claude-code"
        if looksLikeConfigDir(xdg, fileExists: fileExists) { return xdg }
        return homeDir + "/.claude"
    }

    /// User-visible form — collapses the home prefix back to `~` so Settings and
    /// diagnostics show `~/.config/claude-code/settings.json` rather than a full path.
    public static func displayPath(_ absolute: String, homeDir: String = NSHomeDirectory()) -> String {
        guard absolute == homeDir || absolute.hasPrefix(homeDir + "/") else { return absolute }
        return "~" + absolute.dropFirst(homeDir.count)
    }

    /// A directory only counts as a Claude config dir if it actually holds Claude state.
    /// Without this, an empty `~/.config/claude-code` created by some other tool would
    /// shadow a perfectly good `~/.claude`.
    static func looksLikeConfigDir(_ path: String, fileExists: (String) -> Bool) -> Bool {
        ["projects", "settings.json"].contains { fileExists(path + "/" + $0) }
    }

    /// Trims, expands `~`, and drops any trailing slash. Returns nil for empty input.
    ///
    /// `$CLAUDE_CONFIG_DIR` holds a single path — Claude Code reads it verbatim and does
    /// not treat it as a `PATH`-style list, so no separator splitting happens here. That
    /// matters on APFS, where `:` is legal in a filename.
    ///
    /// Claude Code normalizes the path to Unicode NFC before use; we match that so a
    /// decomposed path (as some macOS APIs hand back) still resolves to the same directory.
    static func normalized(_ raw: String?, homeDir: String) -> String? {
        var value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "~" { return homeDir.precomposedStringWithCanonicalMapping }
        if value.hasPrefix("~/") { value = homeDir + "/" + value.dropFirst(2) }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value.precomposedStringWithCanonicalMapping
    }
}
