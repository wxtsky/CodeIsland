import XCTest
@testable import CodeIsland
import CodeIslandCore

/// End-to-end: what the user actually hears when a tool fails versus when a
/// whole turn fails. A Bash exit 1 or an unmatched Edit used to ring the same
/// "task error" jingle as a rate-limited turn.
@MainActor
final class TurnFailureSoundBehaviourTests: XCTestCase {
    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.soundEnabled,
        SettingsKey.soundTaskError,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundPromptSubmit,
        SettingsKey.quietHoursEnabled,
    ]

    override func setUp() {
        super.setUp()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskError)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
        UserDefaults.standard.set(false, forKey: SettingsKey.soundPromptSubmit)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testFailedToolCallPlaysNothing() throws {
        let appState = AppState()
        appState.handleEvent(try event(["hook_event_name": "PreToolUse", "session_id": "tf-tool", "tool_name": "Bash"]))
        played = []
        appState.handleEvent(try event(["hook_event_name": "PostToolUseFailure", "session_id": "tf-tool", "tool_name": "Bash"]))

        XCTAssertEqual(played, [], "a single tool failure is not a task error")
    }

    func testStopFailurePlaysTheErrorJingle() throws {
        let appState = AppState()
        appState.handleEvent(try event([
            "hook_event_name": "StopFailure",
            "session_id": "tf-turn",
            "error_type": "overloaded",
            "error": "Overloaded",
        ]))

        XCTAssertEqual(played, ["8bit_error"])
        XCTAssertEqual(appState.sessions["tf-turn"]?.status, .idle, "a failed turn is still a finished turn")
    }

    func testRepeatedTurnFailuresInOneSessionRingOnce() throws {
        let appState = AppState()
        for _ in 0..<3 {
            appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "tf-burst", "prompt": "retry"]))
            appState.handleEvent(try event(["hook_event_name": "StopFailure", "session_id": "tf-burst", "error_type": "rate_limit"]))
        }

        XCTAssertEqual(played, ["8bit_error"], "retrying into the same rate limit is one burst")
    }

    func testTurnFailuresInDifferentSessionsEachRing() {
        SoundManager.shared.handleEvent(EventSoundRouting.turnFailed, sessionId: "tf-a")
        SoundManager.shared.handleEvent(EventSoundRouting.turnFailed, sessionId: "tf-b")

        XCTAssertEqual(played, ["8bit_error", "8bit_error"])
    }

    func testTurnFailureRespectsTheTaskErrorToggle() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundTaskError)
        SoundManager.shared.handleEvent(EventSoundRouting.turnFailed, sessionId: "tf-off")
        XCTAssertEqual(played, [])
    }

    func testClaudeCodeInstallsStopFailureBehindItsVersionGate() throws {
        let claude = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "claude" })
        XCTAssertTrue(claude.events.contains { $0.0 == "StopFailure" })
        XCTAssertEqual(claude.versionedEvents["StopFailure"], "2.1.78")
        XCTAssertTrue(ConfigInstaller.versionAtLeast("2.1.78", "2.1.78"))
        XCTAssertFalse(ConfigInstaller.versionAtLeast("2.1.77", "2.1.78"))
    }

    /// An undetected version drops the gated events, so every common install
    /// location must be probed: Homebrew on Apple Silicon (cask or npm) puts
    /// `claude` in /opt/homebrew/bin, which a GUI app's PATH doesn't reach.
    func testClaudeVersionProbeCoversTheCommonInstallLocations() {
        let candidates = ConfigInstaller.claudeBinaryCandidates(home: "/Users/u")
        XCTAssertEqual(candidates.first, "/Users/u/.local/bin/claude")
        for path in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/Users/u/.claude/local/claude"] {
            XCTAssertTrue(candidates.contains(path), path)
        }
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
