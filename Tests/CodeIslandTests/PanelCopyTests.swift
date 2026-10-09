import XCTest
@testable import CodeIsland

/// Names and tooltips that explain the panel's terse controls.
final class PanelCopyTests: XCTestCase {
    private let hintKeys = [
        "group_all", "group_status", "group_cli",
        "dismiss_card_hint", "skip_question_hint", "always_hint_session", "always_hint_saved",
    ]

    func testEveryLanguageSpellsOutThePanelControls() {
        // zh and zh-Hant are not merged over English like de, so a missing
        // key there would surface as the raw key in a tooltip.
        for (lang, table) in L10n.strings {
            for key in hintKeys {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang) has no \(key)")
            }
        }
    }

    func testGroupingTabsNameWhatTheyDo() {
        XCTAssertEqual(SessionGroupingTab.all.map(\.tag), ["all", "status", "cli"])
        for tab in SessionGroupingTab.all {
            XCTAssertNotNil(L10n.strings["en"]?[tab.nameKey], "\(tab.pixelLabel) has no spelled-out name")
        }
    }

    func testAboutPageCountsTheIntegrationsInsteadOfHardcodingThem() {
        // It said "Supports 11 CLI/IDE tools" long after there were 30+.
        XCTAssertGreaterThanOrEqual(ConfigInstaller.builtInIntegrationCount, 30)
        for (lang, table) in L10n.strings {
            let text = table["about_desc2"] ?? ""
            XCTAssertTrue(text.contains("%d"), "\(lang) about_desc2 has no count placeholder: \(text)")
            XCTAssertFalse(text.contains("11"), "\(lang) about_desc2 still hardcodes a count: \(text)")
        }
    }

    @MainActor
    func testAlwaysSaysWhetherTheRuleOutlivesTheSession() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        L10n.shared.language = "en"
        XCTAssertTrue(ApprovalHints.always(savesRule: true).contains("~/.codex/rules"))
        XCTAssertTrue(ApprovalHints.always(savesRule: false).contains("session"))
    }
}
