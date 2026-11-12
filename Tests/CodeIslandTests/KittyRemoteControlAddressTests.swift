import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The kitty jump used to depend on the hook carrying `KITTY_LISTEN_ON`: an
/// agent whose extension was loaded before that key existed, or a card
/// restored from an older build, had no address, and a click could only raise
/// kitty. The CLI process's own environment still names the kitty instance it
/// runs in, so the jump reads it directly — no hook, no extension reload, and
/// no particular order for the app, kitty and the CLI to start in.
final class KittyRemoteControlAddressTests: XCTestCase {
    private var child: Process?

    override func tearDown() {
        child?.terminate()
        child?.waitUntilExit()
        child = nil
        super.tearDown()
    }

    /// The package's own stub rather than a system binary: the kernel withholds
    /// a platform binary's environment (`KERN_PROCARGS2` answers with argv
    /// only), while a third-party agent CLI's is readable — the stub stands in
    /// for one, as it does for the bridge's ancestry tests.
    private func stubURL() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codeisland-golden-stub")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("codeisland-golden-stub is not built next to the tests (swift build --build-tests)")
        }
        return url
    }

    private func spawnStub(listenOn address: String) throws -> Process {
        let process = Process()
        process.executableURL = try stubURL()
        process.arguments = ["--", "/bin/sleep", "3"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTY_LISTEN_ON"] = address
        process.environment = environment
        try process.run()
        return process
    }

    /// `KERN_PROCARGS2` is not populated the instant the child is spawned.
    private func waitForEnvironment(of process: Process, keys: Set<String>) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let environment = ProcessTable.environment(for: process.processIdentifier, keys: keys) {
                return environment
            }
            usleep(20_000)
        } while Date() < deadline
        XCTFail("no environment for pid \(process.processIdentifier)")
        return [:]
    }

    func testAddressIsReadFromTheCLIProcessWhenTheHookNeverSentIt() throws {
        let address = "unix:/tmp/kitty-test-\(UUID().uuidString)"
        let process = try spawnStub(listenOn: address)
        child = process
        let environment = try waitForEnvironment(of: process, keys: ["KITTY_LISTEN_ON"])
        XCTAssertEqual(environment["KITTY_LISTEN_ON"], address)

        var session = SessionSnapshot()
        session.source = "pi"
        session.cliPid = process.processIdentifier
        session.cliStartTime = ProcessTable.getProcessStartTime(process.processIdentifier)

        XCTAssertEqual(TerminalActivator.kittyRemoteControlAddress(for: session), address)
    }

    func testTheAddressRecordedByTheHookWins() throws {
        let process = try spawnStub(listenOn: "unix:/tmp/kitty-test-\(UUID().uuidString)")
        child = process
        var session = SessionSnapshot()
        session.source = "pi"
        session.cliPid = process.processIdentifier
        session.cliStartTime = ProcessTable.getProcessStartTime(process.processIdentifier)
        session.kittyListenOn = "unix:/tmp/kitty-from-hook"

        XCTAssertEqual(TerminalActivator.kittyRemoteControlAddress(for: session), "unix:/tmp/kitty-from-hook")
    }

    /// A pid alone is not the process: with a different start time the pid may
    /// be a reused one, whose environment must not steer the jump.
    func testAReusedPIDIsNotRead() throws {
        let address = "unix:/tmp/kitty-test-\(UUID().uuidString)"
        let process = try spawnStub(listenOn: address)
        child = process
        _ = try waitForEnvironment(of: process, keys: ["KITTY_LISTEN_ON"])

        var session = SessionSnapshot()
        session.source = "pi"
        session.cliPid = process.processIdentifier
        session.cliStartTime = Date(timeIntervalSince1970: 1)

        XCTAssertNotEqual(TerminalActivator.kittyRemoteControlAddress(for: session), address)
    }

    /// A remote session's pid belongs to its own host; reading a local process
    /// with that number would name an unrelated kitty.
    func testARemoteSessionsPIDIsNotRead() throws {
        let address = "unix:/tmp/kitty-test-\(UUID().uuidString)"
        let process = try spawnStub(listenOn: address)
        child = process
        _ = try waitForEnvironment(of: process, keys: ["KITTY_LISTEN_ON"])

        var session = SessionSnapshot()
        session.source = "pi"
        session.cliPid = process.processIdentifier
        session.cliStartTime = ProcessTable.getProcessStartTime(process.processIdentifier)
        session.remoteHostId = "server"

        XCTAssertNotEqual(TerminalActivator.kittyRemoteControlAddress(for: session), address)
    }
}
