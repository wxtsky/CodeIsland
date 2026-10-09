import XCTest
@testable import CodeIsland

/// What the launch install and the periodic `verifyAndRepair` may write on a
/// machine. Every test runs on a temp root through `rootOverride` — never the
/// user's home.
final class InstallerFootprintTests: XCTestCase {
    private let fm = FileManager.default
    private var root = ""

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("codeisland-footprint-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    private func builtIn(_ source: String) throws -> CLIConfig {
        var cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == source }, source)
        let root = self.root
        cli.rootOverride = { root }
        return cli
    }

    /// `verifyAndRepair` sends every built-in entry whose hooks don't read as
    /// installed through `installExternalHooks`. pi, Oh My Pi, OpenClaw and
    /// DeepSeek Harness have no hooks file there: their entry points at the
    /// extension, the plugin, or (DSH) the tool's home directory itself. The
    /// generic writer put `{"": {}}` in that spot — on every Mac, a `~/.dsh`
    /// file that made DeepSeek Harness look installed and stood where DSH
    /// creates its home.
    func testHooklessEntriesGetNoConfigFileWritten() throws {
        for source in ["dsh", "openclaw", "pi", "omp"] {
            let cli = try builtIn(source)
            try fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)

            XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm), source)
            XCTAssertFalse(fm.fileExists(atPath: cli.fullPath), "\(source): nothing at \(cli.fullPath)")
        }
    }

    // MARK: - Cline

    /// The launch install created `~/Documents/Cline/Hooks` on every Mac, so
    /// Settings listed Cline as detected for people who never used it.
    func testClineHooksStayOffAMachineWithoutCline() throws {
        let cli = try builtIn("cline")
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertFalse(fm.fileExists(atPath: root + "/Documents"))
        XCTAssertFalse(ConfigInstaller.clinePresenceDetected(home: root, fm: fm))
    }

    func testClineHooksInstallWhereClineIs() throws {
        let cli = try builtIn("cline")
        // Cline's own folder (it keeps Rules / Workflows there) …
        try fm.createDirectory(atPath: root + "/Documents/Cline/Rules", withIntermediateDirectories: true)
        XCTAssertTrue(ConfigInstaller.clinePresenceDetected(home: root, fm: fm))
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        for (event, _, _) in cli.events {
            XCTAssertTrue(fm.fileExists(atPath: cli.fullPath + "/" + event), event)
        }

        // … or only the VS Code extension's storage.
        let other = root + "/other"
        let storage = other + "/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
        try fm.createDirectory(atPath: storage, withIntermediateDirectories: true)
        XCTAssertTrue(ConfigInstaller.clinePresenceDetected(home: other, fm: fm))
    }

    /// `verifyAndRepair` asks the generic JSON check whether hooks are in
    /// place. Cline's are one script per event in a directory, which that
    /// check can't read, so every pass (each app switch, a minute apart)
    /// rewrote all of them.
    func testInstalledClineHooksReadAsInstalled() throws {
        let cli = try builtIn("cline")
        try fm.createDirectory(atPath: root + "/Documents/Cline", withIntermediateDirectories: true)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertTrue(ConfigInstaller.isHooksInstalled(for: cli, fm: fm))

        try fm.removeItem(atPath: cli.fullPath + "/" + cli.events[0].0)
        XCTAssertFalse(ConfigInstaller.isHooksInstalled(for: cli, fm: fm))
    }
}
