import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// The expanded panel's chrome: the header (grouping tabs, Quit that asks
/// once) and the session list's usage footer.
@MainActor
final class PanelChromeTests: XCTestCase {

    // MARK: - Quit asks once

    /// A clock and a timer the test moves by hand; `quit` only counts.
    private final class Harness {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var quits = 0
        var pending: [(fireAt: Date, fire: @MainActor () -> Void, cancelled: Bool)] = []
        var cancels = 0

        @MainActor
        func make() -> QuitConfirmation {
            QuitConfirmation(
                quit: { [unowned self] in self.quits += 1 },
                now: { [unowned self] in self.now },
                schedule: { [unowned self] delay, fire in
                    let index = self.pending.count
                    self.pending.append((self.now.addingTimeInterval(delay), fire, false))
                    return { [unowned self] in
                        if !self.pending[index].cancelled { self.cancels += 1 }
                        self.pending[index].cancelled = true
                    }
                }
            )
        }

        /// Moves the clock and runs every timer now due.
        @MainActor
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            for i in pending.indices where !pending[i].cancelled && pending[i].fireAt <= now {
                pending[i].cancelled = true
                pending[i].fire()
            }
        }
    }

    func testFirstClickOnlyArmsTheButton() {
        let h = Harness()
        let confirm = h.make()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
    }

    func testSecondClickWithinTheWindowQuitsOnce() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.advance(QuitConfirmation.window - 0.1)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
        XCTAssertFalse(confirm.isArmed)
        // The timeout is cancelled, not left to fire later.
        XCTAssertTrue(h.pending.allSatisfy(\.cancelled))
    }

    func testTheArmLapsesAfterTheWindow() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.advance(QuitConfirmation.window)
        XCTAssertFalse(confirm.isArmed, "the pill reverts on its own")
        // The next click starts over: it arms, it doesn't quit.
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
    }

    func testALateClickBeforeTheTimeoutRanStillDoesNotQuit() {
        // A busy main thread can run the revert late; the window is measured
        // on the clock, not by whether the timer got to run.
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        h.now = h.now.addingTimeInterval(QuitConfirmation.window + 0.5)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertFalse(confirm.press())
        XCTAssertTrue(confirm.isArmed, "re-armed for a fresh window")
        XCTAssertEqual(h.quits, 0)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
    }

    func testMovingAwayRevertsWithoutQuitting() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        confirm.cancel()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertEqual(h.cancels, 1, "its timeout goes with it")
        XCTAssertFalse(confirm.press(), "coming back takes two clicks again")
        XCTAssertEqual(h.quits, 0)
    }

    func testAStaleTimeoutDoesNotRevertANewerArm() {
        let h = Harness()
        let confirm = h.make()
        confirm.press()
        // The revert is late; the next click re-arms for a fresh window…
        h.now = h.now.addingTimeInterval(QuitConfirmation.window + 0.5)
        confirm.press()
        // …and the first arm's timeout, running now, must not cut it short.
        h.advance(0)
        XCTAssertTrue(confirm.isArmed)
        XCTAssertTrue(confirm.press())
        XCTAssertEqual(h.quits, 1)
    }

    func testCancelWhileIdleIsHarmless() {
        let h = Harness()
        let confirm = h.make()
        confirm.cancel()
        XCTAssertFalse(confirm.isArmed)
        XCTAssertEqual(h.quits, 0)
        XCTAssertEqual(h.cancels, 0)
    }

    func testQuitPillFitsBesideTheNotchInEveryLanguage() {
        // Expanded header, narrowest panel, 185pt notch: the right wing holds
        // two 24pt buttons, the pill, 4pt gaps and 6pt trailing padding.
        let headerRoom = (580 - 185) / 2 - 6 - 2 * NotchIconButton.hitSize - 2 * 4 - SessionGroupingTabsLayout.notchGap
        // The hovered idle bar (no sessions) is only a wing plus 40pt wider
        // than the notch on each side: mascot + 102 for its right side.
        let idleRoom = (26 + 102) - 6 - 2 * NotchIconButton.hitSize - 2 * 4
        for (lang, table) in L10n.strings {
            let text = table["quit_confirm"] ?? ""
            XCTAssertFalse(text.isEmpty, "\(lang) has no quit_confirm")
            let width = QuitConfirmButton.pillWidth(for: text)
            XCTAssertLessThanOrEqual(width, headerRoom, "\(lang) \"\(text)\" crowds the header")
            XCTAssertLessThanOrEqual(width, idleRoom, "\(lang) \"\(text)\" runs past the idle bar")
            XCTAssertFalse((table["quit_confirm_hint"] ?? "").isEmpty, "\(lang) has no quit_confirm_hint")
        }
    }

    // MARK: - Grouping tabs

    func testTabsAreSpelledOutInThePixelFont() {
        XCTAssertEqual(SessionGroupingTab.all.map(\.pixelLabel), ["ALL", "STATUS", "AGENT"])
        for tab in SessionGroupingTab.all {
            for label in [tab.pixelLabel, tab.shortPixelLabel] {
                for ch in label {
                    XCTAssertNotNil(PixelText.glyphs[ch], "the pixel font can't draw \(ch) in \(label)")
                }
            }
        }
        XCTAssertLessThan(SessionGroupingTabsLayout.width(short: true), SessionGroupingTabsLayout.width(short: false))
    }

    func testSpelledOutTabsFitBesideAMacBookNotchOnTheNarrowestPanel() {
        for notch: CGFloat in [185, 200] {
            let room = SessionGroupingTabsLayout.room(panelWidth: 580, notchWidth: notch, hasNotch: true)
            XCTAssertFalse(SessionGroupingTabsLayout.usesShortLabels(room: room), "\(notch)pt notch")
        }
        // No notch: the menu bar has room to spare.
        let flat = SessionGroupingTabsLayout.room(panelWidth: 580, notchWidth: 240, hasNotch: false)
        XCTAssertFalse(SessionGroupingTabsLayout.usesShortLabels(room: flat))
    }

    func testTabsFallBackToShortLabelsRatherThanRunUnderAWiderNotch() {
        let room = SessionGroupingTabsLayout.room(panelWidth: 580, notchWidth: 230, hasNotch: true)
        XCTAssertTrue(SessionGroupingTabsLayout.usesShortLabels(room: room))
        XCTAssertLessThanOrEqual(SessionGroupingTabsLayout.width(short: true), room, "the short labels still fit")
        // A wider panel (larger width scale) gives the words back.
        let wide = SessionGroupingTabsLayout.room(panelWidth: 620, notchWidth: 230, hasNotch: true)
        XCTAssertFalse(SessionGroupingTabsLayout.usesShortLabels(room: wide))
    }

    func testTabHitTargetsAreTallerThanTheStripTheyDraw() {
        XCTAssertGreaterThanOrEqual(SessionGroupingTabsLayout.hitHeight, 24)
        XCTAssertGreaterThanOrEqual(NotchIconButton.hitSize, 24)
        // Still inside the shortest header (a 25pt menu bar).
        XCTAssertLessThanOrEqual(SessionGroupingTabsLayout.hitHeight, 25)
    }

    // MARK: - Usage footer

    private func usage(empty: Bool = false) -> ClaudeUsageScanner.Snapshot {
        var fiveHours = ClaudeUsageTotals()
        var today = ClaudeUsageTotals()
        if !empty {
            fiveHours.inputTokens = 148_000
            fiveHours.cacheCreationTokens = 274_000
            fiveHours.outputTokens = 96_400
            fiveHours.cacheReadTokens = 11_800_000
            fiveHours.messageCount = 131
            today.inputTokens = 392_000
            today.cacheCreationTokens = 530_000
            today.outputTokens = 233_000
            today.cacheReadTokens = 29_600_000
            today.messageCount = 388
        }
        return ClaudeUsageScanner.Snapshot(last5h: fiveHours, today: today, hourlyOutputTokens: [0, 1, 2], scannedAt: Date())
    }

    private func withLanguage(_ lang: String, _ body: () throws -> Void) rethrows {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        L10n.shared.language = lang
        try body()
    }

    func testFooterLeadsWithLimitsOnceTheyAreFetched() {
        typealias C = SessionListFooterContent
        // Limits on and fetched: one line, tokens folded into it.
        XCTAssertEqual(C.resolve(showClaudeQuota: true, hasSnapshot: true, hasError: false, hasUsage: true), C(limits: true))
        XCTAssertEqual(C.resolve(showClaudeQuota: true, hasSnapshot: true, hasError: true, hasUsage: false), C(limits: true))
        // Limits off: the token line alone.
        XCTAssertEqual(C.resolve(showClaudeQuota: false, hasSnapshot: true, hasError: false, hasUsage: true), C(tokens: true))
        XCTAssertEqual(C.resolve(showClaudeQuota: false, hasSnapshot: false, hasError: true, hasUsage: false), C())
        // On, first fetch pending: tokens; failed: tokens and the error.
        XCTAssertEqual(C.resolve(showClaudeQuota: true, hasSnapshot: false, hasError: false, hasUsage: true), C(tokens: true))
        XCTAssertEqual(C.resolve(showClaudeQuota: true, hasSnapshot: false, hasError: true, hasUsage: true),
                       C(tokens: true, quotaMessage: true))
        XCTAssertEqual(C.resolve(showClaudeQuota: true, hasSnapshot: false, hasError: true, hasUsage: false),
                       C(quotaMessage: true))
    }

    func testTokenUsageIsShownOnlyWhenOnAndNonEmpty() {
        XCTAssertNil(UsageFooterText.shownUsage(usage(), enabled: false))
        XCTAssertNil(UsageFooterText.shownUsage(nil, enabled: true))
        XCTAssertNil(UsageFooterText.shownUsage(usage(empty: true), enabled: true))
        XCTAssertNotNil(UsageFooterText.shownUsage(usage(), enabled: true))
    }

    func testTokenLineUsesWordsInsteadOfArrows() {
        withLanguage("en") {
            // "In" is billed input: new input plus cache writes.
            XCTAssertEqual(UsageFooterText.last5h(usage(), l10n: .shared), "last 5h: 422K in · 96.4K out")
            XCTAssertEqual(UsageFooterText.today(usage(), l10n: .shared), "Today: 922K in · 233K out")
            XCTAssertEqual(UsageFooterText.leading("last 5h: 1K in"), "Last 5h: 1K in")
        }
        withLanguage("zh") {
            XCTAssertEqual(UsageFooterText.last5h(usage(), l10n: .shared), "近 5 小时：输入 422K · 输出 96.4K")
            XCTAssertEqual(UsageFooterText.today(usage(), l10n: .shared), "今日：输入 922K · 输出 233K")
        }
        withLanguage("de") {
            XCTAssertEqual(UsageFooterText.last5h(usage(), l10n: .shared), "letzte 5 Std.: 422K Eingabe · 96.4K Ausgabe")
        }
        for lang in L10n.strings.keys {
            withLanguage(lang) {
                let text = UsageFooterText.last5h(usage(), l10n: .shared) + UsageFooterText.usageTooltip(usage(), l10n: .shared)
                XCTAssertFalse(text.contains("↑") || text.contains("↓"), "\(lang): \(text)")
                XCTAssertTrue(text.contains("422K") && text.contains("96.4K") && text.contains("11.8M"), "\(lang): \(text)")
            }
        }
    }

    func testTokenTooltipBreaksDownWhatInMeans() {
        withLanguage("en") {
            let tip = UsageFooterText.usageTooltip(usage(), l10n: .shared)
            XCTAssertEqual(tip, """
            Claude tokens, from the local transcripts
            Last 5h: 422K in · 96.4K out
              148K new input + 274K cache writes · 11.8M cache reads
            Today: 922K in · 233K out
              392K new input + 530K cache writes · 29.6M cache reads
            """)
        }
    }

    func testLimitTooltipSpellsOutResetsAndPaceAndCarriesTheTokens() {
        let now = Date()
        let snapshot = ClaudeQuotaSnapshot(limits: [
            // 3h of 5h gone (60%), 72% used: 12 points ahead.
            ClaudeQuotaLimit(kind: .session, percent: 72, resetsAt: now.addingTimeInterval(2 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 10, resetsAt: nil, scopeLabel: "Opus"),
        ], fetchedAt: now)
        withLanguage("en") {
            let line = UsageFooterText.limitLine(snapshot.ordered[0], l10n: .shared, now: now)
            XCTAssertTrue(line.hasPrefix("5h 72% · resets in 2h · 12 pts ahead of even pace"), line)
            XCTAssertFalse(line.contains("↻"))
            XCTAssertEqual(UsageFooterText.limitLine(snapshot.ordered[1], l10n: .shared, now: now), "Opus 10%")

            let withTokens = UsageFooterText.limitsTooltip(snapshot, stale: true, usage: usage(), l10n: .shared, now: now)
            let lines = withTokens.components(separatedBy: "\n")
            XCTAssertEqual(lines[2], L10n.shared["quota_stale"])
            XCTAssertEqual(lines[3], "", "a blank line before the tokens")
            XCTAssertEqual(lines[4], "Claude tokens, from the local transcripts")
            XCTAssertTrue(withTokens.contains("Last 5h: 422K in · 96.4K out"))

            let limitsOnly = UsageFooterText.limitsTooltip(snapshot, stale: false, usage: nil, l10n: .shared, now: now)
            XCTAssertEqual(limitsOnly.components(separatedBy: "\n").count, 2)
        }
    }

    func testLimitsTurnWarningNearTheCap() {
        XCTAssertEqual(UsageFooterText.level(ClaudeQuotaLimit(kind: .weeklyAll, percent: 79)), .normal)
        XCTAssertEqual(UsageFooterText.level(ClaudeQuotaLimit(kind: .weeklyAll, percent: 80)), .warning)
        XCTAssertEqual(UsageFooterText.level(ClaudeQuotaLimit(kind: .session, percent: 40, severity: "warning")), .warning)
        XCTAssertEqual(UsageFooterText.level(ClaudeQuotaLimit(kind: .session, percent: 85, severity: "critical")), .critical)
        XCTAssertEqual(UsageFooterText.level(ClaudeQuotaLimit(kind: .session, percent: 100)), .critical)
    }

    func testLongModelNamesAreCutOnTheLineButNotInTheTooltip() {
        let limit = ClaudeQuotaLimit(kind: .weeklyScoped, percent: 50, scopeLabel: "Claude Opus 4.5 Max")
        withLanguage("en") {
            let label = UsageFooterText.windowLabel(limit, l10n: .shared)
            XCTAssertEqual(label.count, UsageFooterText.maxWindowLabelLength)
            XCTAssertTrue(label.hasSuffix("…"))
            XCTAssertTrue(UsageFooterText.limitLine(limit, l10n: .shared, now: Date()).hasPrefix("Claude Opus 4.5 Max 50%"))
            XCTAssertEqual(UsageFooterText.windowLabel(ClaudeQuotaLimit(kind: .weeklyAll, percent: 1), l10n: .shared), "Week")
        }
    }

    // MARK: - Strings

    func testEveryLanguageHasTheNewChromeStrings() {
        let keys = ["usage_last_5h", "usage_span", "usage_in_out", "usage_tooltip_title", "usage_tooltip_breakdown",
                    "quota_resets_in", "quit_confirm", "quit_confirm_hint"]
        func placeholders(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(\\d\\$)?@")
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        let english = L10n.strings["en"]!
        for (lang, table) in L10n.strings {
            for key in keys {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(lang) has no \(key)")
                XCTAssertEqual(placeholders(value), placeholders(english[key]!), "\(lang) \(key): \(value)")
            }
        }
    }
}
