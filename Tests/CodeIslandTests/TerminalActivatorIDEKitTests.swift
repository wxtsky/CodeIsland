import XCTest
import CodeIslandCore
@testable import CodeIsland

final class TerminalActivatorIDEKitTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 100)

    private var session: SessionSnapshot {
        var value = SessionSnapshot()
        value.source = "catpaw-idekit"
        value.cliPid = 123
        value.cliStartTime = started
        return value
    }

    private func target(_ value: SessionSnapshot, current: ProcessIdentity?,
                        path: String? = "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea",
                        bundle: String? = "com.jetbrains.intellij") -> pid_t? {
        TerminalActivator.idekitProcessToActivate(session: value, currentProcess: current,
                                                  executablePath: path, bundleIdentifier: bundle)
    }

    func testOnlyTheRecordedInstanceCanBeActivated() {
        let current = ProcessIdentity(pid: 123, startTime: started)
        XCTAssertEqual(target(session, current: current), 123)
        // Another process with the same IDEA bundle is not a valid substitute.
        XCTAssertNil(target(session, current: ProcessIdentity(pid: 456, startTime: started)))
        XCTAssertNil(target(session, current: nil))
    }

    func testReusedPIDAndMissingStartTimeDisableJump() {
        XCTAssertNil(target(session, current: ProcessIdentity(pid: 123, startTime: started.addingTimeInterval(1))))
        XCTAssertNil(target(session, current: ProcessIdentity(pid: 123, startTime: nil)))
        var unknown = session
        unknown.cliStartTime = nil
        XCTAssertNil(target(unknown, current: ProcessIdentity(pid: 123, startTime: started)))
        unknown = session
        unknown.cliPid = nil
        XCTAssertNil(target(unknown, current: ProcessIdentity(pid: 123, startTime: started)))
    }

    func testUnverifiedHostAndOtherIntegrationsDisableJump() {
        let current = ProcessIdentity(pid: 123, startTime: started)
        XCTAssertNil(target(session, current: current, path: "/bin/sh"))
        XCTAssertNil(target(session, current: current, bundle: "com.jetbrains.pycharm"))
        XCTAssertNil(target(session, current: current, bundle: nil))
        var other = session
        other.source = "catpaw"
        XCTAssertNil(target(other, current: current))
        other = session
        other.remoteHostId = "remote"
        XCTAssertNil(target(other, current: current))
    }
}
