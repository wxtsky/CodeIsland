import XCTest
@testable import CodeIsland

final class CodexHomeTests: XCTestCase {
    private var savedValue: String?

    override func setUp() {
        super.setUp()
        savedValue = ProcessInfo.processInfo.environment["CODEX_HOME"]
        unsetenv("CODEX_HOME")
    }

    override func tearDown() {
        if let savedValue {
            setenv("CODEX_HOME", savedValue, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        super.tearDown()
    }

    func testCodexHomeDefaultsToDotCodexWhenUnset() {
        unsetenv("CODEX_HOME")
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testCodexHomeUsesAbsolutePath() {
        setenv("CODEX_HOME", "/abs/path", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), "/abs/path")
    }

    func testCodexHomeExpandsTilde() {
        setenv("CODEX_HOME", "~/foo", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/foo")
    }

    func testCodexHomeBareTildeBecomesHome() {
        setenv("CODEX_HOME", "~", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory())
    }

    func testCodexHomeEmptyStringFallsBack() {
        setenv("CODEX_HOME", "", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testCodexHomeWhitespaceFallsBack() {
        setenv("CODEX_HOME", "   ", 1)
        XCTAssertEqual(ConfigInstaller.codexHome(), NSHomeDirectory() + "/.codex")
    }

    func testDisplayCodexPathUsesEnvNameWhenSet() {
        setenv("CODEX_HOME", "/abs/path", 1)
        XCTAssertEqual(ConfigInstaller.displayCodexPath(filename: "hooks.json"), "$CODEX_HOME/hooks.json")
    }

    func testDisplayCodexPathFallsBackWhenUnset() {
        unsetenv("CODEX_HOME")
        XCTAssertEqual(ConfigInstaller.displayCodexPath(filename: "hooks.json"), "~/.codex/hooks.json")
    }

    func testEnableCodexHooksConfigWritesCurrentFeatureName() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(contents.contains("features.hooks = true"))
        XCTAssertFalse(contents.contains("codex_hooks"))
    }

    func testEnableCodexHooksConfigLeavesDottedTrueUntouched() throws {
        // #354: current Codex writes the flag as a root dotted key. The old
        // detection missed it and appended a duplicate [features] table.
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let original = "\"features\".\"hooks\" = true\nmodel = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testEnableCodexHooksConfigFlipsDottedFalse() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "\"features\".\"hooks\" = false\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"features\".\"hooks\" = true"))
        XCTAssertFalse(contents.contains("false"))
    }

    func testEnableCodexHooksConfigInsertsDottedKeyBeforeTablesWhenFeaturesIsImplicit() throws {
        // Put a missing root dotted key before the first table, not inside the
        // subtable. A subtable alone permits a later explicit parent table;
        // it is a root dotted key that makes re-declaring [features] invalid.
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "model = \"gpt-6-sol\"\n\n[features.context_management]\nexperimental_mode = true\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let lines = try String(contentsOf: config, encoding: .utf8).components(separatedBy: "\n")
        let hook = try XCTUnwrap(lines.firstIndex(of: "features.hooks = true"))
        let table = try XCTUnwrap(lines.firstIndex(of: "[features.context_management]"))
        XCTAssertLessThan(hook, table)
    }

    func testEnableCodexHooksConfigInsertsBareKeyAfterQuotedFeaturesHeader() throws {
        // The quoted ["features"] header names the same table; the old
        // `== "[features]"` comparison missed it and appended a duplicate.
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "[\"features\"]\ncontext_management = true\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(contents.contains("[\"features\"]\nhooks = true"))
    }

    func testEnableCodexHooksConfigFlipsCurrentFeatureFalse() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(contents.contains("hooks = true"))
        XCTAssertFalse(contents.contains("hooks = false"))
    }

    func testEnableCodexHooksConfigMigratesLegacyFeatureName() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "[features]\ncodex_hooks = true\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(contents.contains("hooks = true"))
        XCTAssertFalse(contents.contains("codex_hooks"))
    }

    func testEnableCodexHooksConfigRemovesLegacyFeatureNameWhenCurrentFeatureAlreadyEnabled() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let config = codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "[features]\nhooks = true # current\ncodex_hooks = true # legacy\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default))

        let contents = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(contents.contains("hooks = true"))
        XCTAssertFalse(contents.contains("codex_hooks"))
    }

    func testCodexTomlEditingPreservesScopeAndFormatting() throws {
        for fixture in CodexTomlHooksFixture.cases {
            let home = makeTemporaryCodexHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            try fixture.original.write(to: config, atomically: true, encoding: .utf8)

            XCTAssertEqual(ConfigInstaller.enableCodexHooksConfig(fm: .default), fixture.expected != nil, fixture.name)
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), fixture.expected ?? fixture.original, fixture.name)
            if fixture.expected != nil {
                XCTAssertTrue(ConfigInstaller.enableCodexHooksConfig(fm: .default), fixture.name)
                XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), fixture.expected, "idempotence: \(fixture.name)")
            }
        }
    }

    func testCodexExternalInstallPropagatesActivationFailureEvenWithExistingHooks() throws {
        let home = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cli.fullPath))
        let config = home.appendingPathComponent("config.toml")
        let unsafe = "features = { hooks = false }\n"
        try unsafe.write(to: config, atomically: true, encoding: .utf8)

        XCTAssertFalse(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), unsafe)
    }

    func testUnreadableCodexConfigIsNotReplaced() throws {
        let home = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertFalse(ConfigInstaller.enableCodexHooksConfig(fm: .default))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func makeTemporaryCodexHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-home-\(UUID().uuidString)", isDirectory: true)
        setenv("CODEX_HOME", url.path, 1)
        return url
    }
}
