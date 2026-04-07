import AppKit
import XCTest
@testable import CodeIsland

final class ShortcutActionTests: XCTestCase {
    private var shortcutKeys: [String] = []
    private var savedValues: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        shortcutKeys = ShortcutAction.allCases.flatMap { action in
            [
                SettingsKey.shortcutEnabled(action.rawValue),
                SettingsKey.shortcutKeyCode(action.rawValue),
                SettingsKey.shortcutModifiers(action.rawValue),
            ]
        }
        let defaults = UserDefaults.standard
        savedValues = shortcutKeys.reduce(into: [:]) { result, key in
            result[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in shortcutKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in savedValues {
            if let value {
                defaults.set(value, forKey: key)
            }
        }
        super.tearDown()
    }

    func testTogglePanelShortcutDefaultsToCommandShiftI() {
        let binding = ShortcutAction.togglePanel.binding

        XCTAssertTrue(ShortcutAction.togglePanel.isEnabled)
        XCTAssertEqual(binding.keyCode, 34)
        XCTAssertEqual(binding.modifiers, [.command, .shift])
        XCTAssertEqual(binding.displayString, "⇧⌘I")
    }

    func testConflictingActionReturnsOtherEnabledActionSharingBinding() {
        ShortcutAction.approve.setBinding(keyCode: 34, modifiers: [.command, .shift])
        ShortcutAction.approve.setEnabled(true)

        XCTAssertEqual(ShortcutAction.togglePanel.conflictingAction(), .approve)
        XCTAssertEqual(ShortcutAction.approve.conflictingAction(), .togglePanel)
    }
}
