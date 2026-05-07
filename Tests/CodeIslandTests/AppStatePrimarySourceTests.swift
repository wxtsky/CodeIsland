import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStatePrimarySourceTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.defaultSource)
        super.tearDown()
    }

    /// #149 regression: when sessions exist but none are actively working
    /// (all .idle), the primary source / mascot should reflect the user's
    /// configured default rather than echoing whichever source spoke last.
    func testIdleSessionsRespectUserDefaultMascot() {
        UserDefaults.standard.set("codex", forKey: SettingsKey.defaultSource)

        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .idle
        session.lastActivity = Date()
        appState.sessions["s1"] = session

        appState.refreshDerivedState()

        XCTAssertEqual(appState.primarySource, "codex",
            "All-idle sessions must fall back to user-configured default mascot (#149)")
    }

    /// Sanity: an active session always wins over the default mascot — we
    /// don't want to mute "what's actually running right now" just because
    /// the user picked a preferred idle mascot.
    func testActiveSessionWinsOverUserDefaultMascot() {
        UserDefaults.standard.set("codex", forKey: SettingsKey.defaultSource)

        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.lastActivity = Date()
        appState.sessions["s1"] = session

        appState.refreshDerivedState()

        XCTAssertEqual(appState.primarySource, "claude",
            "Active work overrides the user default — show what's actually running")
    }

    /// #102 still holds: with no sessions at all, default mascot wins.
    func testEmptyStateRespectsUserDefaultMascot() {
        UserDefaults.standard.set("codex", forKey: SettingsKey.defaultSource)

        let appState = AppState()
        appState.refreshDerivedState()

        XCTAssertEqual(appState.primarySource, "codex")
    }

    /// Mixed: one active, one idle — active source wins regardless of default.
    func testMixedActiveAndIdleSessionsUseActiveSource() {
        UserDefaults.standard.set("codex", forKey: SettingsKey.defaultSource)

        let appState = AppState()
        var idleSession = SessionSnapshot()
        idleSession.source = "claude"
        idleSession.status = .idle
        idleSession.lastActivity = Date()
        appState.sessions["s1"] = idleSession

        var runningSession = SessionSnapshot()
        runningSession.source = "gemini"
        runningSession.status = .running
        runningSession.lastActivity = Date()
        appState.sessions["s2"] = runningSession

        appState.refreshDerivedState()

        XCTAssertEqual(appState.primarySource, "gemini",
            "When at least one session is running, surface that source not the user default")
    }
}
