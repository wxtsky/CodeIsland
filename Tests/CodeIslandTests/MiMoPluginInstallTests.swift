import XCTest
@testable import CodeIsland

/// #355: MiMo Code / Xiaomi MiMo get the OpenCode plugin, relabelled, in
/// `<config>/plugins/codeisland.js`. Every test works in a temp dir — never
/// the user's `~/.config/mimocode`.
final class MiMoPluginInstallTests: XCTestCase {
    private var root: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "codeisland-mimo-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    private var configDir: String { root + "/mimocode" }

    private func shippedPluginSource() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repo.appendingPathComponent("Sources/CodeIsland/Resources/codeisland-opencode.js"),
            encoding: .utf8
        )
    }

    // MARK: - Relabelling

    func testMimoCopyChangesOnlyTheSourceLine() throws {
        let original = try shippedPluginSource()
        let mimo = try XCTUnwrap(ConfigInstaller.mimoPluginSource(from: original))

        XCTAssertFalse(mimo.contains(ConfigInstaller.mimoPluginSourceMarker))
        XCTAssertTrue(mimo.contains(ConfigInstaller.mimoPluginSourceLine))
        let before = original.components(separatedBy: "\n")
        let after = mimo.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.map(\.1), [ConfigInstaller.mimoPluginSourceLine])
    }

    func testRelabellingRefusesAMissingOrRepeatedMarker() {
        XCTAssertNil(ConfigInstaller.mimoPluginSource(from: #"const SOURCE = "pi";"#))
        let twice = ConfigInstaller.mimoPluginSourceMarker + "\n" + ConfigInstaller.mimoPluginSourceMarker
        XCTAssertNil(ConfigInstaller.mimoPluginSource(from: twice))
    }

    // MARK: - Install / status / uninstall

    func testInstallWritesThePluginWhereMimoAutoLoadsIt() throws {
        XCTAssertTrue(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: true))

        let path = ConfigInstaller.mimoPluginPath(configDir: configDir)
        XCTAssertEqual(path, configDir + "/plugins/codeisland.js")
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(written.contains(ConfigInstaller.mimoPluginSourceLine))
        XCTAssertTrue(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))
        // MiMo Code globs `{plugin,plugins}/*.{js,ts}` itself: no config file is written.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: configDir), ["plugins"])
    }

    func testInstallLeavesAMachineWithoutMimoAlone() {
        XCTAssertTrue(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: false))
        XCTAssertFalse(fm.fileExists(atPath: configDir))
        XCTAssertFalse(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))
    }

    func testOpenCodeLabelledOrOutdatedCopyNeedsRepair() throws {
        let path = ConfigInstaller.mimoPluginPath(configDir: configDir)
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // A plain OpenCode copy would report MiMo sessions as OpenCode.
        let original = try shippedPluginSource()
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))

        // An older plugin version is repaired too.
        let mimo = try XCTUnwrap(ConfigInstaller.mimoPluginSource(from: original))
        let versionLine = try XCTUnwrap(mimo.components(separatedBy: "\n").first { $0.hasPrefix("// version: ") })
        try mimo.replacingOccurrences(of: versionLine, with: "// version: v1")
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))

        XCTAssertTrue(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: true))
        XCTAssertTrue(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))
    }

    func testUninstallRemovesOnlyOurOwnPlugin() throws {
        XCTAssertTrue(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: true))
        ConfigInstaller.uninstallMimoPlugin(fm: fm, configDir: configDir)
        let path = ConfigInstaller.mimoPluginPath(configDir: configDir)
        XCTAssertFalse(fm.fileExists(atPath: path))

        // Someone else's file of the same name stays.
        let foreign = "export default { id: \"mine\", server: async () => ({}) }\n"
        try foreign.write(toFile: path, atomically: true, encoding: .utf8)
        ConfigInstaller.uninstallMimoPlugin(fm: fm, configDir: configDir)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), foreign)
    }

    func testInstallNeverOverwritesSomeoneElsesPlugin() throws {
        let path = ConfigInstaller.mimoPluginPath(configDir: configDir)
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let foreign = "export default { id: \"mine\", server: async () => ({}) }\n"
        try foreign.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: true))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), foreign)
        XCTAssertFalse(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))

        // An empty file is nobody's plugin.
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigInstaller.installMimoPlugin(fm: fm, configDir: configDir, present: true))
        XCTAssertTrue(ConfigInstaller.isMimoPluginInstalled(fm: fm, configDir: configDir))
    }

    func testDefaultLocationIsMimoCodesGlobalConfigDir() {
        XCTAssertEqual(ConfigInstaller.mimoConfigDir, NSHomeDirectory() + "/.config/mimocode")
        XCTAssertEqual(
            ConfigInstaller.mimoPluginPath(),
            NSHomeDirectory() + "/.config/mimocode/plugins/codeisland.js"
        )
        XCTAssertEqual(
            Set(ConfigInstaller.mimoDesktopBundleIds),
            ["com.xiaomi.mimo.desktop", "com.xiaomi.mimo.desktop-ai"]
        )
    }
}
