import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Locks in the wire-level pieces of ZCode support (#245). ZCode (Z.ai) is an
/// Electron desktop app — NOT a CLI matching any existing format. Its native
/// hook config (~/.zcode/cli/config.json) wraps hooks in `{enabled, events}`
/// with a STRICT 7-name event schema: writing any other event key silently
/// drops the whole `hooks` config on load. These assertions guard the parts
/// that don't need a live ZCode install: source recognition, the new
/// `.zcode` HookFormat, the default event list, the event-name whitelist,
/// and the JSON merge/remove logic for the `{enabled, events}` wrapper.
final class ZCodeSupportTests: XCTestCase {

    // MARK: - Source recognition / display name

    func testZcodeIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("zcode"), "zcode")
    }

    func testZcodeAliasesNormalizeToZcode() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("z-code"), "zcode")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("z code"), "zcode")
    }

    func testZcodeDisplayLabel() {
        var snapshot = SessionSnapshot()
        snapshot.source = "zcode"
        XCTAssertEqual(snapshot.sourceLabel, "ZCode")
    }

    // MARK: - HookFormat round-trip

    func testHookFormatZcodeRoundTripsThroughStorageValue() {
        XCTAssertEqual(HookFormat.zcode.storageValue, "zcode")
        XCTAssertEqual(HookFormat(storageValue: "zcode"), .zcode)
        XCTAssertEqual(HookFormat(storageValue: "ZCode"), .zcode) // case-insensitive
    }

    // MARK: - CLIConfig wiring

    func testZcodeCLIConfigIsRegistered() {
        let cli = ConfigInstaller.allCLIs.first { $0.source == "zcode" }
        XCTAssertEqual(cli?.name, "ZCode")
        XCTAssertEqual(cli?.configPath, ".zcode/cli/config.json")
        XCTAssertEqual(cli?.configKey, "hooks")
    }

    // MARK: - Default events

    func testZcodeDefaultEventsExcludePermissionRequest() {
        // PermissionRequest is legal per ZCode's schema, but its approve/deny
        // decision-response semantics are unconfirmed — MVP omits it (#245).
        let names = ConfigInstaller.defaultEvents(for: .zcode).map { $0.0 }
        XCTAssertEqual(names, [
            "SessionStart", "UserPromptSubmit", "PreToolUse",
            "PostToolUse", "PostToolUseFailure", "Stop",
        ])
        XCTAssertFalse(names.contains("PermissionRequest"))
    }

    // MARK: - Strict event-name whitelist (#245)

    func testZcodeAllowedEventsMatchesUpstreamStrictSchema() {
        XCTAssertEqual(ConfigInstaller.zcodeAllowedEvents, [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
            "PostToolUse", "PostToolUseFailure", "Stop",
        ])
    }

    func testAllZcodeDefaultEventsAreWithinTheWhitelist() {
        // Writing any event name outside the whitelist silently drops the
        // WHOLE hooks config upstream — every event we ever emit must be a
        // subset of the 7 legal names.
        let names = Set(ConfigInstaller.defaultEvents(for: .zcode).map { $0.0 })
        XCTAssertTrue(names.isSubset(of: ConfigInstaller.zcodeAllowedEvents))
    }

    // MARK: - mergeZcodeHooks

    func testMergeZcodeHooksCreatesEnabledAndEventsWhenMissing() throws {
        let merged = ConfigInstaller.mergeZcodeHooks(into: "")

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)

        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"] {
            let entries = try XCTUnwrap(events[event] as? [[String: Any]], "missing event \(event)")
            let entry = try XCTUnwrap(entries.first)
            let hookList = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            let hook = try XCTUnwrap(hookList.first)
            XCTAssertEqual(hook["type"] as? String, "command")
            let command = try XCTUnwrap(hook["command"] as? String)
            XCTAssertTrue(command.contains("codeisland-bridge --source zcode"))
        }
        // Never register the omitted event.
        XCTAssertNil(events["PermissionRequest"])
    }

    func testMergeZcodeHooksNeverFlipsUserDisabledMasterSwitch() throws {
        // `enabled` is the user's master switch over ALL their hooks — install
        // must not silently re-arm hook commands the user turned off.
        let original = """
        {
          "hooks": {
            "enabled": false,
            "events": {
              "Stop": [ { "hooks": [ { "type": "command", "command": "echo user-hook" } ] } ]
            }
          }
        }
        """

        let merged = ConfigInstaller.mergeZcodeHooks(into: original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, false)
    }

    func testMergeZcodeHooksIsIdempotent() throws {
        let once = ConfigInstaller.mergeZcodeHooks(into: "")
        let twice = ConfigInstaller.mergeZcodeHooks(into: once)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(twice.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        let entries = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        // Re-running must not duplicate our managed entry.
        XCTAssertEqual(entries.count, 1)
    }

    func testMergeZcodeHooksPreservesUserHooksAndOtherTopLevelKeys() throws {
        let bridge = "\(NSHomeDirectory())/.codeisland/codeisland-bridge"
        let original = """
        {
          "theme": "dark",
          "hooks": {
            "enabled": true,
            "events": {
              "Stop": [
                { "hooks": [ { "type": "command", "command": "echo user-hook" } ] },
                { "hooks": [ { "type": "command", "command": "\(bridge) --source zcode" } ] }
              ]
            }
          }
        }
        """

        let merged = ConfigInstaller.mergeZcodeHooks(into: original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])

        // Sibling top-level key preserved.
        XCTAssertEqual(root["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        let stopEntries = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        let stopCommands = stopEntries.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }

        // User's own Stop hook preserved.
        XCTAssertTrue(stopCommands.contains("echo user-hook"))
        // Exactly one of our managed entries (the stale one was replaced, not duplicated).
        XCTAssertEqual(stopCommands.filter { $0.contains("codeisland-bridge") && $0.contains("--source zcode") }.count, 1)
    }

    // MARK: - removeManagedZcodeHooks

    func testRemoveManagedZcodeHooksDropsOnlyOurEntries() throws {
        let bridge = "\(NSHomeDirectory())/.codeisland/codeisland-bridge"
        let original = """
        {
          "hooks": {
            "enabled": true,
            "events": {
              "Stop": [
                { "hooks": [ { "type": "command", "command": "echo user-hook" } ] },
                { "hooks": [ { "type": "command", "command": "\(bridge) --source zcode" } ] }
              ],
              "SessionStart": [
                { "hooks": [ { "type": "command", "command": "\(bridge) --source zcode" } ] }
              ]
            }
          }
        }
        """

        let cleaned = ConfigInstaller.removeManagedZcodeHooks(from: original)
        XCTAssertFalse(cleaned.contains("codeisland-bridge --source zcode"))
        XCTAssertTrue(cleaned.contains("echo user-hook"))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        // SessionStart had only our entry — that event key is dropped entirely.
        XCTAssertNil(events["SessionStart"])
        // Stop still exists (user's hook survives).
        XCTAssertNotNil(events["Stop"])
    }

    func testRemoveManagedZcodeHooksDropsWholeHooksKeyWhenNothingElseRemains() throws {
        let bridge = "\(NSHomeDirectory())/.codeisland/codeisland-bridge"
        let original = """
        {
          "theme": "dark",
          "hooks": {
            "enabled": true,
            "events": {
              "Stop": [
                { "hooks": [ { "type": "command", "command": "\(bridge) --source zcode" } ] }
              ]
            }
          }
        }
        """

        let cleaned = ConfigInstaller.removeManagedZcodeHooks(from: original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])

        // Sibling top-level key untouched.
        XCTAssertEqual(root["theme"] as? String, "dark")
        // No leftover `{"enabled": true, "events": {}}` scaffolding.
        XCTAssertNil(root["hooks"])
    }

    func testRemoveManagedZcodeHooksLeavesUnrelatedConfigUntouched() {
        let original = """
        {
          "hooks": {
            "enabled": true,
            "events": {
              "Stop": [
                { "hooks": [ { "type": "command", "command": "echo user-hook" } ] }
              ]
            }
          }
        }
        """
        let cleaned = ConfigInstaller.removeManagedZcodeHooks(from: original)
        // Nothing of ours present -> unchanged.
        XCTAssertEqual(cleaned, original)
    }
}
