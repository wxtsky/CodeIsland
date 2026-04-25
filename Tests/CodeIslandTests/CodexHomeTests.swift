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
}
