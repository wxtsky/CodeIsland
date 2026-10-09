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
}
