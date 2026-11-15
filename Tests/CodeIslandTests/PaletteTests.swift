import SwiftUI
import XCTest
@testable import CodeIsland

/// Island themes: the default palette is exactly the colours the panel drew
/// before themes existed, the setting persists, and every theme is named in
/// every language.
@MainActor
final class PaletteTests: XCTestCase {

    private func resolved(_ color: Color) -> Color.Resolved {
        color.resolve(in: EnvironmentValues())
    }

    private func assertSame(_ a: Color, _ b: Color, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(resolved(a), resolved(b), name, file: file, line: line)
    }

    func testDefaultPaletteMatchesTheOriginalColours() {
        let p = Palette.standard
        assertSame(p.panel, .black, "panel")
        assertSame(p.ink, .white, "ink")
        XCTAssertEqual(p.inkBoost, 1)
        assertSame(p.working, Color(red: 0.3, green: 0.85, blue: 0.4), "working")
        assertSame(p.workingBright, Color(red: 0.4, green: 1.0, blue: 0.5), "workingBright")
        assertSame(p.needsYou, Color(red: 1.0, green: 0.6, blue: 0.2), "needsYou")
        assertSame(p.caution, Color(red: 1.0, green: 0.7, blue: 0.28), "caution")
        assertSame(p.stopped, Color(red: 1.0, green: 0.55, blue: 0.4), "stopped")
        assertSame(p.error, Color(red: 1.0, green: 0.38, blue: 0.42), "error")
        assertSame(p.alert, Color(red: 1.0, green: 0.4, blue: 0.4), "alert")
        assertSame(p.accent, Color(red: 0.85, green: 0.47, blue: 0.34), "accent")
        assertSame(p.link, Color(red: 0.45, green: 0.72, blue: 1.0), "link")
        assertSame(p.allowFill, Color(red: 0.16, green: 0.50, blue: 0.24), "allowFill")
        assertSame(p.allowFillHover, Color(red: 0.17, green: 0.53, blue: 0.26), "allowFillHover")
        assertSame(p.deny, Color(red: 0.92, green: 0.38, blue: 0.38), "deny")
    }

    func testDefaultInkIsWhiteAtTheSameOpacity() {
        let sandbox = DefaultsSandbox(keys: [SettingsKey.islandTheme])
        defer { sandbox.restore() }
        UserDefaults.standard.removeObject(forKey: SettingsKey.islandTheme)
        for opacity in [0.045, 0.1, 0.28, 0.55, 0.62, 0.85, 1.0] {
            assertSame(Palette.ink(opacity), .white.opacity(opacity), "ink(\(opacity))")
        }
        XCTAssertEqual(SessionCardStatus.idle.color, Color.white.opacity(0.55))
        XCTAssertEqual(SessionCardStatus.working.color, Color(red: 0.3, green: 0.85, blue: 0.4))
    }

    func testHighContrastLiftsInkAndCapsAtOne() {
        let sandbox = DefaultsSandbox(keys: [SettingsKey.islandTheme])
        defer { sandbox.restore() }
        SettingsManager.shared.islandTheme = .highContrast
        XCTAssertEqual(resolved(Palette.ink(0.4)).opacity, 0.6, accuracy: 0.001)
        XCTAssertEqual(resolved(Palette.ink(0.8)).opacity, 1, accuracy: 0.001)
        assertSame(Palette.current.panel, .black, "panel")
    }

    func testThemeDefaultsToDefaultAndPersists() {
        let sandbox = DefaultsSandbox(keys: [SettingsKey.islandTheme])
        defer { sandbox.restore() }
        XCTAssertEqual(SettingsDefaults.islandTheme, "default")
        XCTAssertEqual(SettingsManager.shared.islandTheme, .standard)
        XCTAssertEqual(IslandTheme.current, .standard)

        for theme in IslandTheme.allCases {
            SettingsManager.shared.islandTheme = theme
            XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKey.islandTheme), theme.rawValue)
            XCTAssertEqual(IslandTheme.current, theme)
        }

        UserDefaults.standard.set("neon", forKey: SettingsKey.islandTheme)
        XCTAssertEqual(IslandTheme.current, .standard, "an unknown value reads as the default")
        XCTAssertEqual(IslandTheme(storedValue: nil), .standard)
    }

    func testThemeIsLocalizedInEveryLanguage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        let keys = ["theme", "theme_desc"] + IslandTheme.allCases.map(\.titleKey)
        for language in ["en", "de", "zh", "zh-Hant", "ja", "ko", "tr"] {
            L10n.shared.language = language
            for key in keys {
                XCTAssertNotEqual(L10n.shared[key], key, "\(language) lacks \(key)")
            }
        }
    }
}
