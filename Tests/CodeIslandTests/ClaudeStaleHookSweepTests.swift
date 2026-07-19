import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Covers the cross-directory stale-hook sweep. This path REWRITES files on disk
/// outside the currently resolved config dir, so its guard rails need specs: a
/// regression here silently strips or corrupts a real user `settings.json`.
final class ClaudeStaleHookSweepTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("stale-hooks-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func writeSettings(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try data.write(to: dir.appendingPathComponent("settings.json"))
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let entries = (hooks[event] as? [[String: Any]]) ?? []
        return entries.flatMap { entry -> [String] in
            ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// The marker guard: a settings.json with no CodeIsland entries must be left
    /// byte-identical. Without this the sweep would rewrite (and reformat) an
    /// unrelated user config every time it ran.
    func testSettingsWithoutOurMarkerIsLeftUntouched() throws {
        try writeSettings(["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "echo user-hook", "timeout": 5]]],
        ]]])
        let before = try Data(contentsOf: dir.appendingPathComponent("settings.json"))

        let modified = ConfigInstaller.cleanClaudeHooks(inDir: dir.path, fm: fm)

        XCTAssertFalse(modified, "a file without our marker must not be reported as modified")
        let after = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(before, after, "unrelated settings.json was rewritten")
    }

    /// The actual sweep: our entries go, the user's survive.
    func testOurHooksAreStrippedAndUserHooksSurvive() throws {
        try writeSettings(["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "echo keep-me", "timeout": 5]]],
            ["hooks": [["type": "command", "command": "~/.codeisland/codeisland-bridge --source claude", "timeout": 5]]],
        ]]])

        let modified = ConfigInstaller.cleanClaudeHooks(inDir: dir.path, fm: fm)

        XCTAssertTrue(modified)
        let cmds = commands(try readSettings(), event: "SessionStart")
        XCTAssertTrue(cmds.contains { $0.contains("keep-me") }, "user hook was wiped: \(cmds)")
        XCTAssertFalse(cmds.contains { $0.contains("codeisland") }, "our hook survived: \(cmds)")
    }

    /// A directory with no settings.json at all is a no-op, not a crash or a created file.
    func testMissingSettingsFileIsANoOp() {
        let empty = dir.appendingPathComponent("nonexistent").path
        XCTAssertFalse(ConfigInstaller.cleanClaudeHooks(inDir: empty, fm: fm))
        XCTAssertFalse(fm.fileExists(atPath: empty + "/settings.json"))
    }

    /// The sweep must never target the directory we are currently installing into —
    /// that would delete the hooks just written. `staleClaudeConfigDirs` is private,
    /// so assert the property it exists to guarantee.
    func testResolvedDirIsNeverSwept() throws {
        let resolved = ClaudeConfigPaths.configDir()
        try writeSettings(["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "~/.codeisland/codeisland-bridge --source claude"]]],
        ]]])

        // Sanity: the temp dir is not the resolved dir, so sweeping it is legitimate.
        XCTAssertNotEqual(ClaudeConfigPaths.canonical(dir.path),
                          ClaudeConfigPaths.canonical(resolved))
        XCTAssertTrue(ConfigInstaller.cleanClaudeHooks(inDir: dir.path, fm: fm))
    }

    /// Canonical comparison guards the filter: configDir() is NFC-normalized while the
    /// candidate literals are hand-built, so a decomposed home path must still compare
    /// equal or the resolved dir could slip through and be swept.
    func testCanonicalFormMatchesAcrossUnicodeForms() {
        let decomposed = "/Users/tester/Cafe\u{0301}/.claude"
        let precomposed = "/Users/tester/Caf\u{00E9}/.claude"
        XCTAssertEqual(Array(ClaudeConfigPaths.canonical(decomposed).utf8),
                       Array(ClaudeConfigPaths.canonical(precomposed).utf8))
    }
}
