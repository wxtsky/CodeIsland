import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The approval and question cards: one filled primary per card, an
/// "Always" link that says what it commits to, shortcut badges only for
/// shortcuts that are on, and text that follows Content Font Size without
/// running out of the window.
@MainActor
final class NotchCardRedesignTests: XCTestCase {
    private var sandbox: DefaultsSandbox?
    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        savedLanguage = L10n.shared.language
        L10n.shared.language = "en"
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        MascotAnimationGate.shared.setPanelVisible(true)
        L10n.shared.language = savedLanguage
        sandbox?.restore()
        super.tearDown()
    }

    // MARK: - Copy

    func testTitleSaysWhatTheToolWantsToDo() {
        XCTAssertEqual(ApprovalCopy.title(tool: "Bash", toolInput: ["command": "ls"]), "Bash wants to run a command")
        XCTAssertEqual(ApprovalCopy.title(tool: "Edit", toolInput: ["file_path": "/a/src/Dashboard.tsx"]),
                       "Edit wants to change Dashboard.tsx")
        XCTAssertEqual(ApprovalCopy.title(tool: "Write", toolInput: nil), "Write wants to change files")
        XCTAssertEqual(ApprovalCopy.title(tool: "Read", toolInput: ["file_path": "/a/README.md"]), "Read wants to read README.md")
        XCTAssertEqual(ApprovalCopy.title(tool: "Grep", toolInput: ["pattern": "x"]), "Grep wants to search the files")
        XCTAssertEqual(ApprovalCopy.title(tool: "WebFetch", toolInput: nil), "WebFetch wants to access the web")
        XCTAssertEqual(ApprovalCopy.title(tool: "mcp__github__create_pull_request", toolInput: [:]),
                       "github wants to call create_pull_request")
        XCTAssertEqual(ApprovalCopy.title(tool: "Task", toolInput: nil), "Task wants to start a subagent")
        XCTAssertEqual(ApprovalCopy.title(tool: "Frobnicate", toolInput: nil), "Frobnicate wants to run")
        // Codex's own tool names
        XCTAssertEqual(ApprovalCopy.action(for: "exec_command"), .command)
        XCTAssertEqual(ApprovalCopy.action(for: "write_stdin"), .command)
        XCTAssertEqual(ApprovalCopy.action(for: "apply_patch"), .change)
        XCTAssertEqual(ApprovalCopy.action(for: "web_search"), .web)

        L10n.shared.language = "zh"
        XCTAssertEqual(ApprovalCopy.title(tool: "Bash", toolInput: nil), "Bash 请求运行命令")
        XCTAssertEqual(ApprovalCopy.title(tool: "Edit", toolInput: ["file_path": "/a/b.swift"]), "Edit 请求修改 b.swift")
    }

    func testAlwaysLinkStatesItsScope() {
        XCTAssertEqual(ApprovalCopy.alwaysLink(tool: "Bash", scope: .session), "Always allow Bash this session")
        XCTAssertEqual(ApprovalCopy.alwaysLink(tool: "mcp__github__create_pull_request", scope: .session),
                       "Always allow create_pull_request this session")
        XCTAssertEqual(ApprovalCopy.alwaysLink(tool: "Bash", scope: .codexRules), "Always allow — saved to ~/.codex/rules")
        XCTAssertEqual(ApprovalCopy.alwaysLink(tool: "mcp__docs__search", scope: .codexMCPConfig),
                       "Always allow — saved to ~/.codex/config.toml")
        L10n.shared.language = "zh"
        XCTAssertEqual(ApprovalCopy.alwaysLink(tool: "Bash", scope: .session), "本会话始终允许 Bash")
    }

    func testAlwaysScopeFollowsWhereTheRuleIsSaved() {
        XCTAssertEqual(ApprovalAlwaysScope(savesRule: false, tool: "mcp__github__create_pull_request"), .session)
        XCTAssertEqual(ApprovalAlwaysScope(savesRule: true, tool: "Bash"), .codexRules)
        // CodexPermissionRules writes an MCP tool's approval to config.toml.
        XCTAssertEqual(ApprovalAlwaysScope(savesRule: true, tool: "mcp__docs__search"), .codexMCPConfig)
        XCTAssertEqual(ApprovalAlwaysScope(savesRule: true, tool: "mcp__malformed"), .codexRules)
        XCTAssertTrue(ApprovalHints.always(scope: .codexRules).contains("~/.codex/rules"))
        XCTAssertTrue(ApprovalHints.always(scope: .codexMCPConfig).contains("~/.codex/config.toml"))
        XCTAssertTrue(ApprovalHints.always(scope: .session).contains("session"))
    }

    func testQueuePositionOnlyWithMoreThanOneWaiting() {
        XCTAssertNil(NotchCardQueueLabel.text(position: 1, total: 1))
        XCTAssertEqual(NotchCardQueueLabel.text(position: 2, total: 3), "2 of 3")
        L10n.shared.language = "zh"
        XCTAssertEqual(NotchCardQueueLabel.text(position: 1, total: 3), "第 1/3 个")
    }

    func testEveryLanguageHasTheCardWords() {
        let keys = [
            "always_hint_saved_mcp", "card_permission_tag", "card_queue_position", "card_allow_once", "card_deny",
            "card_hide", "card_skip", "card_back", "card_confirm", "card_submit", "card_always_session",
            "card_always_saved", "card_jump_hint", "approval_title_command", "approval_title_change_file",
            "approval_title_change", "approval_title_read_file", "approval_title_read", "approval_title_search",
            "approval_title_web", "approval_title_mcp", "approval_title_agent", "approval_title_generic",
        ]
        func placeholders(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: #"%(\d\$)?[@d]"#)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }
        let english = L10n.strings["en"] ?? [:]
        for (lang, table) in L10n.strings {
            for key in keys {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(lang) has no \(key)")
                XCTAssertEqual(placeholders(value), placeholders(english[key] ?? ""), "\(lang) \(key): \(value)")
            }
        }
        XCTAssertEqual(L10n.strings["zh"]?["card_hide"], "收起")
    }

    // MARK: - Shortcut badges

    func testButtonsBadgeOnlyTheShortcutsTurnedOn() {
        // All four are off by default (Not Set), so no button shows a badge.
        for action in [ShortcutAction.approve, .approveAlways, .deny, .skipQuestion] {
            XCTAssertNil(CardShortcutHint.text(for: action), "\(action) is badged while off")
        }
        ShortcutAction.approve.setEnabled(true)
        XCTAssertEqual(CardShortcutHint.text(for: .approve), "⇧⌘A")
        XCTAssertNil(CardShortcutHint.text(for: .deny))
    }

    // MARK: - Question card's primary button

    func testPrimaryButtonIsAvailableOnlyWithSomethingToSend() {
        var wizard = QuestionWizardState(requestId: UUID())
        XCTAssertFalse(wizard.canSubmitText)
        XCTAssertFalse(wizard.canSubmitOther)
        XCTAssertFalse(wizard.canConfirmMultiSelect)

        wizard.textInput = "Last 30 days"
        XCTAssertTrue(wizard.canSubmitText)

        wizard.selectedIndices = [1]
        XCTAssertTrue(wizard.canConfirmMultiSelect)
        wizard.selectedIndices = []
        // "Other" ticked but still empty sends nothing.
        wizard.showOtherInput = true
        XCTAssertFalse(wizard.canConfirmMultiSelect)
        wizard.otherText = "Region"
        XCTAssertTrue(wizard.canConfirmMultiSelect)
        XCTAssertTrue(wizard.canSubmitOther)

        wizard.resetInput()
        XCTAssertFalse(wizard.canSubmitText || wizard.canSubmitOther || wizard.canConfirmMultiSelect)
    }

    // MARK: - Content Font Size

    func testCardTextFollowsContentFontSizeWithinTheOfferedRange() {
        let regular = NotchCardTypography(contentFontSize: SettingsDefaults.contentFontSize)
        XCTAssertEqual(regular.body, 11)
        XCTAssertEqual(regular.title, 12)
        XCTAssertEqual(regular.button, 12)

        let largest = NotchCardTypography(contentFontSize: 16)
        XCTAssertEqual(largest.body, 16)
        XCTAssertGreaterThan(largest.title, regular.title)
        XCTAssertGreaterThan(largest.secondary, regular.secondary)
        XCTAssertLessThanOrEqual(largest.button, 15, "buttons stop growing so the decision row stays one line")

        // A value Settings never offers is clamped to its range.
        XCTAssertEqual(NotchCardTypography(contentFontSize: 40), largest)
        XCTAssertEqual(NotchCardTypography(contentFontSize: 2).base, 10)
        XCTAssertGreaterThanOrEqual(NotchCardTypography(contentFontSize: 10).caption, 9)
    }

    func testCardGrowsWithContentFontSize() async throws {
        func height(fontSize: Int) async throws -> CGFloat {
            UserDefaults.standard.set(fontSize, forKey: SettingsKey.contentFontSize)
            let demo = try await GalleryDemo.approval(.bashShort, lang: .en)
            defer { demo.release() }
            let host = CardHost(demo.state)
            defer { host.close() }
            return try host.snapshot().panelHeight
        }
        let regular = try await height(fontSize: 11)
        let large = try await height(fontSize: 16)
        XCTAssertGreaterThan(large - regular, 20, "the approval card's text does not follow Content Font Size")
    }

    // MARK: - Fit at the largest size

    func testApprovalCardsFitTheWindowAtTheLargestTextSize() async throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        ShortcutAction.approve.setEnabled(true)
        ShortcutAction.deny.setEnabled(true)
        for language in ["en", "de", "tr", "zh"] {
            L10n.shared.language = language
            for kind in ApprovalKind.allCases {
                let demo = try await GalleryDemo.approval(kind, lang: language == "zh" ? .zh : (language == "de" ? .de : .en))
                defer { demo.release() }
                try assertFits(demo.state, "\(kind.rawValue) in \(language)", primaryVisible: true)
            }
        }
    }

    func testQuestionCardsFitTheWindowAtTheLargestTextSize() async throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        for language in ["en", "de", "tr"] {
            L10n.shared.language = language
            for kind in QuestionKind.allCases {
                let demo = try await GalleryDemo.question(kind, lang: language == "de" ? .de : .en)
                defer { demo.release() }
                try assertFits(demo.state, "\(kind.rawValue) question in \(language)", primaryVisible: false)
            }
        }
    }

    func testCardsFitANarrowPanelAtTheLargestTextSize() async throws {
        // The panel is min(620, screen − 40) wide; on a small display it has
        // less than the usual 580pt for German and Turkish labels.
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        for action in [ShortcutAction.approve, .approveAlways, .deny, .skipQuestion] { action.setEnabled(true) }
        for language in ["de", "tr"] {
            L10n.shared.language = language
            for kind in [ApprovalKind.codex, .mcp, .bashLong] {
                let demo = try await GalleryDemo.approval(kind, lang: language == "de" ? .de : .en)
                defer { demo.release() }
                try assertFits(demo.state, "\(kind.rawValue) in \(language) on a narrow screen",
                               screenWidth: 520, primaryVisible: true)
            }
            for kind in [QuestionKind.multi, .freeText] {
                let demo = try await GalleryDemo.question(kind, lang: language == "de" ? .de : .en)
                defer { demo.release() }
                try assertFits(demo.state, "\(kind.rawValue) question in \(language) on a narrow screen",
                               screenWidth: 520, primaryVisible: false)
            }
        }
    }

    func testAVeryLongCommandScrollsInsteadOfBeingCutOff() async throws {
        // A heredoc of eighty lines was squeezed into what the window left
        // and cut off mid-command; it now scrolls, and the buttons stay put.
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.cwd = "/Users/dev/code/web-app"
        s.status = .waitingApproval
        state.sessions = ["c": s]
        state.activeSessionId = "c"
        let command = "cat <<'EOF' > seed.sql\n" + (1...80).map { "INSERT INTO orders VALUES (\($0), 'pending');" }
            .joined(separator: "\n") + "\nEOF"
        let release = await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
            "hook_event_name": "PermissionRequest", "session_id": "c", "cwd": "/Users/dev/code/web-app",
            "tool_name": "Bash", "tool_input": ["command": command, "description": "Seed the orders table"],
        ]))
        defer { release() }
        state.refreshDerivedState()
        state.surface = .approvalCard(sessionId: "c")
        try assertFits(state, "an eighty-line command", primaryVisible: true)

        let host = CardHost(state)
        defer { host.close() }
        let scrolls = host.scrollViews.contains { scroll in
            (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 200
        }
        XCTAssertTrue(scrolls, "the command is cut off instead of scrolling")
    }

    // MARK: - Helpers

    private func assertFits(
        _ state: AppState,
        _ what: String,
        screenWidth: CGFloat = 1512,
        primaryVisible: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = CardHost(state, screenWidth: screenWidth)
        defer { host.close() }
        let shot = try host.snapshot()
        XCTAssertGreaterThan(shot.gapUnderPanel, 0, "\(what) runs off the bottom of the window", file: file, line: line)
        XCTAssertEqual(shot.contentAtSideEdges, 0, "\(what) reaches the panel's side edges (clipped)", file: file, line: line)
        if primaryVisible {
            XCTAssertTrue(shot.containsAllowFill, "\(what): Allow once is not on screen", file: file, line: line)
        }
    }
}

/// The real panel hosted at its window size (min(620, screen − 40) wide) on
/// a red backdrop, read back as pixels.
@MainActor
private struct CardHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let size: CGSize

    init(_ state: AppState, screenWidth: CGFloat = 1512, notchHeight: CGFloat = 32) {
        let maxVisible = UserDefaults.standard.object(forKey: SettingsKey.maxVisibleSessions) as? Int
            ?? SettingsDefaults.maxVisibleSessions
        size = CGSize(width: min(620, screenWidth - 40), height: PanelHeightMetrics.desiredHeight(maxVisibleSessions: maxVisible))
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: notchHeight, notchW: 185, screenWidth: screenWidth)
            .environment(\.mascotStaticTime, 5.2)
            .background(Color(red: 1, green: 0, blue: 0))
        host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The AppKit scroll views behind the panel's SwiftUI ScrollViews.
    var scrollViews: [NSScrollView] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return descendants(host).compactMap { $0 as? NSScrollView }
    }

    func snapshot() throws -> PanelSnapshot {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return PanelSnapshot(pixels: pixels, width: w, height: h, scale: CGFloat(h) / size.height)
    }
}

private struct PanelSnapshot {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat

    private func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    private func isBackdrop(_ x: Int, _ y: Int) -> Bool {
        let p = rgb(x, y)
        return p.r > 200 && p.g < 60 && p.b < 60
    }

    /// Lowest row of the panel, read down its middle.
    private var bottomRow: Int {
        var row = height - 1
        while row > 0, isBackdrop(width / 2, row) { row -= 1 }
        return row
    }

    var gapUnderPanel: CGFloat { CGFloat(height - 1 - bottomRow) / scale }
    var panelHeight: CGFloat { CGFloat(bottomRow + 1) / scale }

    /// Pixels of content within 5pt of the panel's left and right edges,
    /// from below the notch bar to above the rounded bottom corners. The
    /// card keeps a 14pt margin, so anything there was laid out wider than
    /// the panel and cut off by it.
    var contentAtSideEdges: Int {
        let top = Int(48 * scale)
        let bottom = bottomRow - Int(28 * scale)
        guard bottom > top else { return 0 }
        let probe = (top + bottom) / 2
        var left = 0
        while left < width - 1, isBackdrop(left, probe) { left += 1 }
        var right = width - 1
        while right > 0, isBackdrop(right, probe) { right -= 1 }
        let strip = Int(5 * scale)
        var count = 0
        for y in top...bottom {
            for x in Array((left + 1)...(left + strip)) + Array((right - strip)...(right - 1)) {
                let p = rgb(x, y)
                if max(p.r, p.g, p.b) > 40 { count += 1 }
            }
        }
        return count
    }

    /// Whether the green of the card's one filled button is on screen.
    var containsAllowFill: Bool {
        // NotchCardPalette.allowFill, rgb(0.16, 0.50, 0.24)
        let target = (r: 41, g: 128, b: 61)
        for y in stride(from: 0, to: bottomRow, by: 1) {
            for x in stride(from: 0, to: width, by: 2) {
                let p = rgb(x, y)
                if abs(p.r - target.r) < 8 && abs(p.g - target.g) < 8 && abs(p.b - target.b) < 8 { return true }
            }
        }
        return false
    }
}
