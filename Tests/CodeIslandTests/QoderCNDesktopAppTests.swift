import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Qoder 国行's desktop app is a separate install (`Qoder CN.app`,
/// `com.qodercn.app`) whose hooks live under ~/.qoder-cn and report the shared
/// `qoder-cli` source. The bundle was absent from the native-app maps, so its
/// sessions fell back to generic terminal handling: no app-name badge, no
/// smart-suppress, and click-to-jump only raised the app instead of matching
/// the project window.
final class QoderCNDesktopAppTests: XCTestCase {

    func testChinaDesktopAppIsNativeAppMode() {
        var session = SessionSnapshot()
        session.source = "qoder-cli"
        session.termBundleId = "com.qodercn.app"

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        XCTAssertEqual(session.terminalName, "Qoder CN")
        XCTAssertEqual(SessionSnapshot.sourceForAppBundleId("com.qodercn.app"), "qoder-cli")
    }

    /// The source check is what separates an app session from a CLI run inside
    /// another host — a bundle id alone must not satisfy it.
    func testBundleWithMismatchedSourceIsNotNativeAppMode() {
        var session = SessionSnapshot()
        session.source = "qoder"
        session.termBundleId = "com.qodercn.app"

        XCTAssertFalse(session.isNativeAppMode)
    }

    func testInternationalAppAndIDEMappingsDoNotRegress() {
        var intl = SessionSnapshot()
        intl.source = "qoder"
        intl.termBundleId = "com.qoder.app"
        XCTAssertTrue(intl.isNativeAppMode)
        XCTAssertEqual(intl.terminalName, "Qoder")

        var ide = SessionSnapshot()
        ide.source = "qoder"
        ide.termBundleId = "com.qoder.ide"
        XCTAssertTrue(ide.isNativeAppMode)
        XCTAssertEqual(ide.terminalName, "Qoder IDE")
    }

    func testQoderCLIInTerminalStaysATerminalSession() {
        var session = SessionSnapshot()
        session.source = "qoder-cli"
        session.termBundleId = "com.apple.Terminal"

        XCTAssertFalse(session.isNativeAppMode)
    }
}
