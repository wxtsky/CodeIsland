import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// Offscreen UI gallery: every surface of the island, and every Settings
/// page, in representative states — for design reviews and before/after
/// comparisons. Nothing is launched (no hooks are installed, a running
/// island is left alone); the real views render into PNGs at 2×.
///
/// Opt-in, like the README harness — skipped unless `UI_GALLERY_DIR` is set:
///
///     UI_GALLERY_DIR=/tmp/gallery swift test --filter UIGalleryHarness
///
/// Filters: `UI_GALLERY_ONLY=collapsed,list,approval,question,completion,settings`
/// and `UI_GALLERY_LANGS=en,zh,de`. Output goes to one folder per group,
/// named `<state>[-<variant>]-<lang>.png`; `index.txt` lists every file with
/// any overflow found (content running off the bottom of the panel window).
///
/// Settings the panel reads are cleared for the run (shipped defaults) and
/// restored after; variants (16pt content font, grouping modes, …) set
/// theirs inside that sandbox. The plan-limit setting is only ever written to
/// a private suite so the quota monitor never fetches.
@MainActor
final class UIGalleryHarness: XCTestCase {

    private var outDir = ""
    private var index: [String] = []

    func testRenderGallery() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["UI_GALLERY_DIR"] else {
            throw XCTSkip("UI_GALLERY_DIR not set — gallery is opt-in")
        }
        self.outDir = outDir
        let only = env["UI_GALLERY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let langs = (env["UI_GALLERY_LANGS"] ?? "en,zh,de").split(separator: ",").compactMap { GalleryLang(rawValue: String($0)) }
        func wants(_ group: String) -> Bool { only?.contains(group) ?? true }

        _ = NSApplication.shared
        let sandbox = DefaultsSandbox(keys: GallerySettings.keys)
        XCTAssertGreaterThan(GallerySettings.keys.count, 100, "Settings.swift keys were not found")
        let savedLanguage = L10n.shared.language
        MascotAnimationGate.shared.setPanelVisible(false)
        defer {
            MascotAnimationGate.shared.setPanelVisible(true)
            L10n.shared.language = savedLanguage
            sandbox.restore()
            GallerySettings.suite.removePersistentDomain(forName: GallerySettings.suiteName)
        }

        for lang in langs {
            L10n.shared.language = lang.rawValue
            if wants("collapsed") { try await renderCollapsed(lang) }
            if wants("list") { try await renderList(lang) }
            if wants("approval") { try await renderApprovals(lang) }
            if wants("question") { try await renderQuestions(lang) }
            if wants("completion") { try await renderCompletion(lang) }
            if wants("settings") { try renderSettings(lang) }
        }
        try (index.sorted().joined(separator: "\n") + "\n")
            .write(toFile: "\(outDir)/index.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Groups

    private func renderCollapsed(_ lang: GalleryLang) async throws {
        let all = CollapsedState.allCases
        var jobs: [(CollapsedState, StageScreen, StageWallpaper)] = []
        if lang == .en {
            for state in all { jobs.append((state, .macBook14, .dark)) }
            for state in all { jobs.append((state, .macBook16, .dark)) }
            for state in all { jobs.append((state, .external, .dark)) }
            for state in [CollapsedState.idle, .workingShort, .approval, .quota] { jobs.append((state, .macBook14, .light)) }
        } else {
            for state in [CollapsedState.workingShort, .workingLong, .quota] { jobs.append((state, .macBook14, .dark)) }
        }
        for (state, screen, wallpaper) in jobs {
            GallerySettings.reset()
            if state == .quota { GallerySettings.set(true, SettingsKey.showClaudeQuota, suiteOnly: true) }
            let demo = try await GalleryDemo.collapsed(state, lang: lang)
            defer { demo.release() }
            let name = "\(screen.name)-\(state.rawValue)" + (wallpaper == .light ? "-light" : "")
            try renderOnStage(demo, group: "collapsed", name: name, lang: lang, screen: screen,
                              layout: StageLayout(width: screen.hasNotch ? 760 : 820, bottomMargin: 18, menuItems: true),
                              wallpaper: wallpaper, windowHeight: 120)
        }
    }

    private func renderList(_ lang: GalleryLang) async throws {
        struct Job { let name: String; let count: Int; let settings: [(String, Any)]; let quota: Bool
                     var wallpaper: StageWallpaper = .dark; var appearance: NSAppearance.Name = .darkAqua }
        var jobs = [
            Job(name: "1", count: 1, settings: [], quota: false),
            Job(name: "4", count: 4, settings: [], quota: false),
            Job(name: "8", count: 8, settings: [], quota: false),
            Job(name: "4-f16", count: 4, settings: [(SettingsKey.contentFontSize, 16)], quota: false),
            Job(name: "8-quota", count: 8, settings: [], quota: true),
            Job(name: "8-status", count: 8, settings: [(SettingsKey.sessionGroupingMode, "status")], quota: false),
            Job(name: "8-cli", count: 8, settings: [(SettingsKey.sessionGroupingMode, "cli")], quota: false),
            Job(name: "4-compact", count: 4, settings: [(SettingsKey.sessionListDensity, "compact")], quota: false),
            Job(name: "8-compact", count: 8, settings: [(SettingsKey.sessionListDensity, "compact")], quota: false),
        ]
        if lang == .en {
            jobs += [
                Job(name: "8-details", count: 8, settings: [
                    (SettingsKey.showModelLabel, true), (SettingsKey.showAgentDetails, true), (SettingsKey.aiMessageLines, 2),
                ], quota: false),
                Job(name: "8-max8", count: 8, settings: [(SettingsKey.maxVisibleSessions, 8)], quota: false),
                Job(name: "8-compact-f16", count: 8, settings: [
                    (SettingsKey.sessionListDensity, "compact"), (SettingsKey.contentFontSize, 16),
                ], quota: false),
                Job(name: "8-compact-status", count: 8, settings: [
                    (SettingsKey.sessionListDensity, "compact"), (SettingsKey.sessionGroupingMode, "status"),
                ], quota: true),
                Job(name: "4-light", count: 4, settings: [], quota: false, wallpaper: .light),
                Job(name: "4-lightmode", count: 4, settings: [], quota: false, appearance: .aqua),
            ]
        }
        for job in jobs {
            GallerySettings.reset()
            for (key, value) in job.settings { GallerySettings.set(value, key) }
            if job.quota { GallerySettings.set(true, SettingsKey.showClaudeQuota, suiteOnly: true) }
            let demo = try await GalleryDemo.list(count: job.count, lang: lang, quota: job.quota)
            defer { demo.release() }
            try renderOnStage(demo, group: "list", name: job.name, lang: lang, screen: .macBook14,
                              layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false),
                              wallpaper: job.wallpaper, appearance: job.appearance)
        }
    }

    private func renderApprovals(_ lang: GalleryLang) async throws {
        // Every card at the default text size and at the largest Content
        // Font Size (16pt), which the card text follows.
        for kind in ApprovalKind.allCases {
            for big in [false, true] {
                GallerySettings.reset()
                if big { GallerySettings.set(16, SettingsKey.contentFontSize) }
                let demo = try await GalleryDemo.approval(kind, lang: lang)
                defer { demo.release() }
                try renderOnStage(demo, group: "approval", name: kind.rawValue + (big ? "-f16" : ""), lang: lang,
                                  screen: .macBook14, layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false))
            }
        }
        // The buttons badge a global shortcut only once it is turned on.
        for big in [false, true] {
            GallerySettings.reset()
            GallerySettings.setCardShortcutsEnabled()
            if big { GallerySettings.set(16, SettingsKey.contentFontSize) }
            let demo = try await GalleryDemo.approval(.bashShort, lang: lang)
            defer { demo.release() }
            try renderOnStage(demo, group: "approval", name: "bash-short-keys" + (big ? "-f16" : ""), lang: lang,
                              screen: .macBook14, layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false))
        }
        if lang == .en {
            GallerySettings.reset()
            let demo = try await GalleryDemo.approval(.bashShort, lang: lang)
            defer { demo.release() }
            try renderOnStage(demo, group: "approval", name: "bash-short-light", lang: lang, screen: .macBook14,
                              layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false), wallpaper: .light)
        }
    }

    private func renderQuestions(_ lang: GalleryLang) async throws {
        for kind in QuestionKind.allCases {
            for big in [false, true] {
                GallerySettings.reset()
                if big { GallerySettings.set(16, SettingsKey.contentFontSize) }
                let demo = try await GalleryDemo.question(kind, lang: lang)
                defer { demo.release() }
                try renderOnStage(demo, group: "question", name: kind.rawValue + (big ? "-f16" : ""), lang: lang,
                                  screen: .macBook14, layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false))
            }
        }
        GallerySettings.reset()
        GallerySettings.setCardShortcutsEnabled()
        let demo = try await GalleryDemo.question(.multi, lang: lang)
        defer { demo.release() }
        try renderOnStage(demo, group: "question", name: "multi-keys", lang: lang, screen: .macBook14,
                          layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false))
    }

    private func renderCompletion(_ lang: GalleryLang) async throws {
        var jobs: [(String, CompletionKind, [(String, Any)])] = [
            ("short", .short, []),
            ("markdown", .markdown, []),
        ]
        if lang == .en { jobs.append(("markdown-f16", .markdown, [(SettingsKey.contentFontSize, 16)])) }
        for (name, kind, settings) in jobs {
            GallerySettings.reset()
            for (key, value) in settings { GallerySettings.set(value, key) }
            let demo = GalleryDemo.completion(kind, lang: lang)
            defer { demo.release() }
            try renderOnStage(demo, group: "completion", name: name, lang: lang, screen: .macBook14,
                              layout: StageLayout(width: 700, bottomMargin: 40, menuItems: false))
        }
    }

    private func renderSettings(_ lang: GalleryLang) throws {
        let pages: [SettingsPage] = [.general, .behavior, .appearance, .mascots, .sound, .shortcuts, .remote, .hooks, .buddy, .about]
        let appearances: [NSAppearance.Name] = lang == .en ? [.darkAqua, .aqua] : [.darkAqua]
        // SettingsWindowController: min(660, w/2) × min(540, h/0.6) on a 14" display.
        let size = CGSize(width: 660, height: 540)
        for appearance in appearances {
            for page in pages {
                GallerySettings.reset()
                let view = SettingsView(appState: nil, initialPage: page)
                    .defaultAppStorage(GallerySettings.suite)
                let image = try OffscreenRender.hosted(
                    view, size: size, appearance: appearance,
                    styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], passes: 5
                )
                // The window background the real (titled) window draws behind it.
                let backed = try XCTUnwrap(OffscreenRender.rasterize(
                    ZStack {
                        Rectangle().fill(appearance == .aqua ? Color(white: 0.93) : Color(white: 0.16))
                        Image(decorative: image, scale: 2)
                    }.frame(width: size.width, height: size.height)
                ))
                let name = page.rawValue + (appearance == .aqua ? "-light" : "")
                try write(backed, group: "settings", name: name, lang: lang, note: nil)
            }
        }
    }

    // MARK: - Rendering

    /// Renders the panel as PanelWindowController hosts it on `screen`, then
    /// composites it onto the stage.
    private func renderOnStage(
        _ demo: GalleryDemoState,
        group: String,
        name: String,
        lang: GalleryLang,
        screen: StageScreen,
        layout: StageLayout,
        wallpaper: StageWallpaper = .dark,
        appearance: NSAppearance.Name = .darkAqua,
        windowHeight: CGFloat? = nil
    ) throws {
        let maxVisible = UserDefaults.standard.object(forKey: SettingsKey.maxVisibleSessions) as? Int
            ?? SettingsDefaults.maxVisibleSessions
        // Window height as PanelWindowController.panelSize, clamped to the
        // 14" display's visible frame (982 − menu bar).
        let height = windowHeight ?? min(PanelHeightMetrics.desiredHeight(maxVisibleSessions: maxVisible), 982 - 37)
        let view = NotchPanelView(
            appState: demo.state,
            hasNotch: screen.hasNotch,
            notchHeight: screen.notchHeight,
            notchW: screen.notchWidth,
            screenWidth: screen.screenWidth
        )
        .environment(\.mascotStaticTime, GalleryDemo.mascotTime)
        .defaultAppStorage(GallerySettings.suite)
        .frame(width: screen.windowWidth, height: height)

        let full = try OffscreenRender.hosted(
            view, size: CGSize(width: screen.windowWidth, height: height),
            appearance: appearance, afterFirstLayout: demo.afterFirstLayout
        )
        let trimmed = try OffscreenRender.trimmedToContent(full)
        let overflow = trimmed.height >= height - 0.5
        let stage = Stage(panel: trimmed.image, panelHeight: trimmed.height, layout: layout,
                          screen: screen, wallpaper: wallpaper, clock: lang.clock)
        let image = try XCTUnwrap(OffscreenRender.rasterize(stage), "stage render failed for \(group)/\(name)")
        try write(image, group: group, name: name, lang: lang,
                  note: overflow ? "OVERFLOW: content reaches the bottom of the \(Int(height))pt window" : nil)
    }

    private func write(_ image: CGImage, group: String, name: String, lang: GalleryLang, note: String?) throws {
        let dir = "\(outDir)/\(group)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = "\(group)/\(name)-\(lang.rawValue).png"
        try OffscreenRender.writePNG(image, to: "\(outDir)/\(file)")
        index.append(file + (note.map { "  \($0)" } ?? ""))
    }
}

// MARK: - Settings sandbox

/// Panel settings for one render: the standard defaults (sandboxed by the
/// harness) for views that read them directly — the scrolling session list
/// hosts its cards in a nested NSHostingView that does not inherit
/// `defaultAppStorage` — and a private suite for everything else.
@MainActor
enum GallerySettings {
    static let suiteName = "CodeIsland.UIGalleryHarness"
    static let suite = UserDefaults(suiteName: suiteName)!

    /// Every key the harness sandboxes (and clears before each render).
    static let keys = DefaultsSandbox.allSettingsKeys

    static func reset() {
        suite.removePersistentDomain(forName: suiteName)
        for key in keys where key != SettingsKey.appLanguage {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// `suiteOnly` keeps a key out of the standard defaults — the quota
    /// monitor watches those and would start fetching.
    static func set(_ value: Any, _ key: String, suiteOnly: Bool = false) {
        suite.set(value, forKey: key)
        if !suiteOnly { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Turns on the approve / always / deny / skip shortcuts (off by
    /// default): ⌘⇧A, ⌘⇧L, ⌘⇧D and ⌘⇧S.
    static func setCardShortcutsEnabled() {
        let commandShift = Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)
        for (action, keyCode) in [(ShortcutAction.approve, 0), (.approveAlways, 37), (.deny, 2), (.skipQuestion, 1)] {
            set(true, SettingsKey.shortcutEnabled(action.rawValue))
            set(keyCode, SettingsKey.shortcutKeyCode(action.rawValue))
            set(commandShift, SettingsKey.shortcutModifiers(action.rawValue))
        }
    }
}

// MARK: - Variants

enum GalleryLang: String {
    case en, zh, de

    var clock: String {
        switch self {
        case .en: return "Tue 9:41"
        case .zh: return "周二 9:41"
        case .de: return "Di. 9:41"
        }
    }

    func t(_ en: String, _ zh: String, _ de: String) -> String {
        switch self {
        case .en: return en
        case .zh: return zh
        case .de: return de
        }
    }
}

enum CollapsedState: String, CaseIterable {
    case empty
    case idle
    case workingShort = "working-short"
    case workingLong = "working-long"
    case approval
    case question
    case questionDismissed = "question-dismissed"
    case quota
    case glance
}

enum ApprovalKind: String, CaseIterable {
    case bashShort = "bash-short"
    case bashLong = "bash-long"
    /// Longer than the window holds: the command scrolls.
    case bashHeredoc = "bash-heredoc"
    case edit
    case write
    case mcp
    case codex
    case queued
}

enum QuestionKind: String, CaseIterable {
    case single
    case multi
    case many
    case longText = "long-text"
    case freeText = "free-text"
    case wizard
    case legacy
}

enum CompletionKind {
    case short, markdown
}

@MainActor
struct GalleryDemoState {
    let state: AppState
    var afterFirstLayout: (() -> Void)? = nil
    var release: () -> Void = {}
}

// MARK: - Demo data

@MainActor
enum GalleryDemo {
    static let mascotTime: Double = 5.2

    enum ID {
        static let claude = "a3e1c0d4-6f2b-4c8e-9b17-52d8e4f07c91"
        static let codex = "b7d2f5a8-1c4e-4e90-8a3b-6f1c2d9e04b3"
        static let cursor = "c5a9e3b1-8d7f-4b21-a6c4-0e3f9d2b7a58"
        static let gemini = "d8f4b2c6-3a1e-4d57-b9e8-7c2a5f1d93e6"
        static let hermes = "e1b7c3d9-4f2a-4e68-a1c5-8d3e6f2b7c40"
        static let minimax = "f6a2d8e4-5b3c-4f79-b2d6-9e4f7a3c8d51"
        static let mimo = "a9c4e2f7-6d1b-4a80-c3e7-0f5a8b4d9e62"
        static let kimi = "b2d8f6a1-7e3c-4b91-d4f8-1a6b9c5e0f73"
    }

    static func session(
        source: String,
        project: String,
        branch: String?,
        terminalBundleId: String?,
        status: AgentStatus,
        startedMinutesAgo: Double
    ) -> SessionSnapshot {
        var s = SessionSnapshot(startTime: Date().addingTimeInterval(-startedMinutesAgo * 60 - 20))
        s.source = source
        s.cwd = "/Users/dev/code/\(project)"
        s.gitBranch = branch
        s.termBundleId = terminalBundleId
        s.status = status
        s.lastActivity = Date()
        return s
    }

    private static func converse(_ s: inout SessionSnapshot, prompt: String, reply: String?) {
        s.lastUserPrompt = prompt
        s.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        if let reply {
            s.lastAssistantMessage = reply
            s.addRecentMessage(ChatMessage(isUser: false, text: reply))
        }
    }

    private static func usage() -> ClaudeUsageScanner.Snapshot {
        var fiveHours = ClaudeUsageTotals()
        fiveHours.inputTokens = 148_000
        fiveHours.cacheCreationTokens = 274_000
        fiveHours.outputTokens = 96_400
        fiveHours.cacheReadTokens = 11_800_000
        fiveHours.messageCount = 131
        var today = ClaudeUsageTotals()
        today.inputTokens = 392_000
        today.cacheCreationTokens = 530_000
        today.outputTokens = 233_000
        today.cacheReadTokens = 29_600_000
        today.messageCount = 388
        return ClaudeUsageScanner.Snapshot(
            last5h: fiveHours,
            today: today,
            hourlyOutputTokens: [0, 3_100, 14_800, 9_200, 0, 0, 18_400, 36_500, 22_900, 12_300, 41_800, 27_600],
            scannedAt: Date()
        )
    }

    private static func applyQuota(_ state: AppState) {
        let now = Date()
        state.claudeQuota.applyPreview(ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 64, resetsAt: now.addingTimeInterval(2 * 3600 + 1200)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 38, resetsAt: now.addingTimeInterval(3 * 86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 81, severity: "warning",
                             resetsAt: now.addingTimeInterval(3 * 86_400), scopeLabel: "Opus"),
        ], fetchedAt: now))
    }

    // MARK: Sessions

    static func claudeWorking(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                        terminalBundleId: "com.mitchellh.ghostty", status: .running, startedMinutesAgo: 12)
        s.model = "claude-opus-4-5"
        converse(&s, prompt: lang.t("Add filters to the dashboard page", "给仪表盘页面加上筛选功能",
                                    "Füge der Dashboard-Seite Filter hinzu"),
                 reply: lang.t("Adding a date-range and status filter bar above the orders table.",
                               "先在订单表格上方加一个日期范围和状态筛选栏。",
                               "Ich füge über der Bestelltabelle eine Filterleiste für Zeitraum und Status hinzu."))
        s.currentTool = "Edit"
        s.toolDescription = "src/components/Dashboard.tsx"
        s.subagents["explore-1"] = SubagentState(agentId: "explore-1", agentType: "Explore")
        var plan = SubagentState(agentId: "plan-1", agentType: "Plan")
        plan.status = .idle
        s.subagents["plan-1"] = plan
        s.agentTasks = AgentTaskList(items: [
            AgentTaskItem(id: "t1", title: lang.t("Read the dashboard layout", "阅读仪表盘布局", "Dashboard-Layout lesen"), status: .completed),
            AgentTaskItem(id: "t2", title: lang.t("Add the filter bar component", "添加筛选栏组件", "Filterleisten-Komponente hinzufügen"), status: .completed),
            AgentTaskItem(id: "t3", title: lang.t("Wire filters into the orders query", "把筛选接入订单查询", "Filter an die Bestellabfrage anbinden"),
                          activeForm: lang.t("Wiring filters into the orders query", "正在把筛选接入订单查询", "Filter werden an die Bestellabfrage angebunden"),
                          status: .inProgress),
            AgentTaskItem(id: "t4", title: lang.t("Persist filters in the URL", "把筛选状态写入 URL", "Filter in der URL speichern"), status: .pending),
            AgentTaskItem(id: "t5", title: lang.t("Write tests", "编写测试", "Tests schreiben"), status: .pending),
        ])
        return s
    }

    static func codexWorking(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "codex", project: "api-server", branch: "perf/query-planner",
                        terminalBundleId: "com.googlecode.iterm2", status: .running, startedMinutesAgo: 26)
        s.model = "gpt-5-codex"
        let output = lang.t("Added cost-based planner; running cargo test…", "已加入基于代价的查询规划器，正在运行 cargo test…",
                            "Kostenbasierten Planer ergänzt; cargo test läuft…")
        converse(&s, prompt: lang.t("Speed up the slow /search endpoint", "优化 /search 接口的慢查询",
                                    "Beschleunige den langsamen /search-Endpunkt"), reply: output)
        s.liveCodexOutput = output
        s.currentTool = "Bash"
        s.toolDescription = "cargo test -p planner"
        return s
    }

    static func cursorQuestion(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "cursor", project: "mobile-app", branch: "fix/feed-scroll",
                        terminalBundleId: "com.todesktop.230313mzl4w4u92", status: .waitingQuestion, startedMinutesAgo: 4)
        converse(&s, prompt: lang.t("Fix the scroll jank on the feed", "修复信息流滚动卡顿", "Behebe das Ruckeln beim Scrollen im Feed"), reply: nil)
        s.cursorPendingQuestion = lang.t("Virtualize the feed list, or switch to pagination?",
                                         "信息流列表改用虚拟滚动，还是换成分页？",
                                         "Feed-Liste virtualisieren oder auf Seitenumbruch umstellen?")
        return s
    }

    static func geminiIdle(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "gemini", project: "docs-site", branch: "main",
                        terminalBundleId: "dev.warp.Warp-Stable", status: .idle, startedMinutesAgo: 68)
        s.model = "gemini-2.5-pro"
        converse(&s, prompt: lang.t("Document the new filter API", "为新的筛选 API 补充文档", "Dokumentiere die neue Filter-API"),
                 reply: lang.t("Updated 6 pages under docs/api and fixed 3 broken links.",
                               "已更新 docs/api 下的 6 个页面，并修复了 3 个失效链接。",
                               "6 Seiten unter docs/api aktualisiert und 3 defekte Links repariert."))
        s.recap = SessionRecap(text: lang.t(
            "Documented the filter API (6 pages) and fixed broken links. Next: review the new examples.",
            "已为筛选 API 写好文档（6 页）并修复失效链接。下一步：检查新增示例。",
            "Filter-API dokumentiert (6 Seiten) und defekte Links repariert. Als Nächstes: neue Beispiele prüfen."),
            createdAt: Date())
        return s
    }

    static func hermesThinking(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "hermes", project: "infra", branch: "chore/terraform-1.9",
                        terminalBundleId: "com.apple.Terminal", status: .processing, startedMinutesAgo: 2)
        converse(&s, prompt: lang.t("Upgrade the Terraform providers", "升级 Terraform provider", "Aktualisiere die Terraform-Provider"), reply: nil)
        return s
    }

    static func minimaxInterrupted(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "minimax", project: "payments", branch: "feat/refunds",
                        terminalBundleId: "com.mitchellh.ghostty", status: .idle, startedMinutesAgo: 41)
        converse(&s, prompt: lang.t("Add partial refunds to the checkout flow", "给结账流程加上部分退款", "Füge dem Checkout Teilrückerstattungen hinzu"),
                 reply: lang.t("Interrupted while migrating the refunds table.", "迁移 refunds 表时被中断。",
                               "Beim Migrieren der Tabelle refunds unterbrochen."))
        s.interrupted = true
        return s
    }

    static func mimoApproval(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "mimo", project: "ml-pipeline", branch: "exp/feature-store",
                        terminalBundleId: "com.googlecode.iterm2", status: .waitingApproval, startedMinutesAgo: 7)
        converse(&s, prompt: lang.t("Backfill the feature store for March", "回填三月份的特征库", "Fülle den Feature Store für März nach"), reply: nil)
        s.currentTool = "Bash"
        s.toolDescription = "python scripts/backfill.py --month 2026-03"
        return s
    }

    static func kimiRemote(_ lang: GalleryLang) -> SessionSnapshot {
        var s = session(source: "kimi", project: "customer-onboarding-service-v2-migration",
                        branch: "feature/very-long-branch-name-for-onboarding-flow", terminalBundleId: nil,
                        status: .idle, startedMinutesAgo: 190)
        s.remoteHostId = "devbox"
        s.remoteHostName = "devbox"
        s.isYoloMode = true
        s.model = "kimi-k2"
        converse(&s, prompt: lang.t("Migrate the onboarding emails to the new template engine",
                                    "把注册引导邮件迁移到新的模板引擎",
                                    "Migriere die Onboarding-E-Mails auf die neue Template-Engine"),
                 reply: lang.t("Migrated 14 templates; 2 need copy review.", "已迁移 14 个模板，其中 2 个需要文案审核。",
                               "14 Vorlagen migriert; 2 brauchen eine Textprüfung."))
        return s
    }

    // MARK: Collapsed

    static func collapsed(_ kind: CollapsedState, lang: GalleryLang) async throws -> GalleryDemoState {
        let state = AppState()
        state.claudeUsage = usage()
        if kind == .empty { return GalleryDemoState(state: state) }

        var claude = claudeWorking(lang)
        var after: (() -> Void)?
        var release: () -> Void = {}
        switch kind {
        case .empty: break
        case .idle, .quota, .glance:
            claude.status = .idle
            claude.currentTool = nil
            claude.toolDescription = nil
        case .workingShort, .workingLong:
            // The bar shows a tool once it sees it change.
            let tool = kind == .workingShort ? "Edit" : "mcp__github__create_pull_request_review"
            let desc = kind == .workingShort ? "src/components/Dashboard.tsx" : "owner/web-app#482"
            claude.currentTool = nil
            after = {
                state.sessions[ID.claude]?.currentTool = tool
                state.sessions[ID.claude]?.toolDescription = desc
            }
        case .approval:
            claude.status = .waitingApproval
            claude.currentTool = "Bash"
        case .question, .questionDismissed:
            claude.status = .waitingQuestion
            claude.currentTool = nil
        }
        state.sessions = [ID.claude: claude, ID.gemini: geminiIdle(lang)]
        state.activeSessionId = ID.claude
        state.refreshDerivedState()

        switch kind {
        case .approval:
            let event = try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": ID.claude, "cwd": "/Users/dev/code/web-app",
                "tool_name": "Bash", "tool_input": ["command": "npm run test -- --coverage"],
            ])
            release = await DemoRequests.enqueuePermission(state, event: event)
        case .question, .questionDismissed:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: "/Users/dev/code/web-app", items: [
                (lang.t("Which state library should the dashboard use?", "仪表盘应该用哪个状态管理库？",
                        "Welche State-Bibliothek soll das Dashboard nutzen?"), nil,
                 [("Zustand", nil), ("Redux Toolkit", nil)], false),
            ])
            if kind == .questionDismissed {
                state.surface = .questionCard(sessionId: ID.claude)
                state.dismissQuestion(expectedSessionId: ID.claude)
            }
            state.surface = .collapsed
        case .quota:
            applyQuota(state)
        case .glance:
            state.glanceCompletionActive = true
        default: break
        }
        state.refreshDerivedState()
        return GalleryDemoState(state: state, afterFirstLayout: after, release: release)
    }

    // MARK: Session list

    static func list(count: Int, lang: GalleryLang, quota: Bool) async throws -> GalleryDemoState {
        let state = AppState()
        state.claudeUsage = usage()
        var sessions: [String: SessionSnapshot] = [:]
        switch count {
        case 1:
            sessions = [ID.claude: claudeWorking(lang)]
        case 4:
            sessions = [ID.claude: claudeWorking(lang), ID.codex: codexWorking(lang),
                        ID.mimo: mimoApproval(lang), ID.gemini: geminiIdle(lang)]
        default:
            sessions = [ID.claude: claudeWorking(lang), ID.codex: codexWorking(lang), ID.cursor: cursorQuestion(lang),
                        ID.gemini: geminiIdle(lang), ID.hermes: hermesThinking(lang), ID.minimax: minimaxInterrupted(lang),
                        ID.mimo: mimoApproval(lang), ID.kimi: kimiRemote(lang)]
        }
        state.sessions = sessions
        state.activeSessionId = ID.claude
        var release: () -> Void = {}
        if sessions[ID.mimo] != nil {
            let event = try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": ID.mimo, "cwd": "/Users/dev/code/ml-pipeline",
                "tool_name": "Bash",
                "tool_input": ["command": "python scripts/backfill.py --month 2026-03",
                               "description": lang.t("Backfill March features", "回填三月特征", "März-Features nachfüllen")],
            ])
            release = await DemoRequests.enqueuePermission(state, event: event)
        }
        if quota { applyQuota(state) }
        state.refreshDerivedState()
        state.surface = .sessionList
        return GalleryDemoState(state: state, release: release)
    }

    // MARK: Approval cards

    static func approval(_ kind: ApprovalKind, lang: GalleryLang) async throws -> GalleryDemoState {
        let state = AppState()
        state.claudeUsage = usage()
        var claude = claudeWorking(lang)
        claude.status = .waitingApproval
        var sid = ID.claude
        var cwd = "/Users/dev/code/web-app"
        var source = "claude"
        var tool = "Bash"
        var input: [String: Any] = [:]
        switch kind {
        case .bashShort, .queued:
            input = ["command": "npm run test -- --coverage",
                     "description": lang.t("Run the test suite with a coverage report", "运行测试套件并生成覆盖率报告",
                                           "Testsuite mit Coverage-Bericht ausführen")]
        case .bashLong:
            input = ["command": """
                docker compose -f docker-compose.yml -f docker-compose.ci.yml run --rm \\
                  -e DATABASE_URL=postgres://ci:ci@db:5432/app_test \\
                  -e REDIS_URL=redis://cache:6379/1 \\
                  api bash -lc 'bundle exec rails db:prepare && bundle exec rspec spec/requests --format documentation --fail-fast'
                """,
                     "description": lang.t("Run the request specs against a disposable CI database",
                                           "在一次性 CI 数据库上运行请求测试",
                                           "Request-Specs gegen eine Wegwerf-CI-Datenbank ausführen")]
        case .bashHeredoc:
            input = ["command": "psql \"$DATABASE_URL\" <<'SQL'\n" + (1...60).map {
                "INSERT INTO orders (id, status, total) VALUES (\($0), 'pending', \($0 * 7 % 90 + 10).00);"
            }.joined(separator: "\n") + "\nSQL",
                     "description": lang.t("Seed the orders table for the dashboard demo", "为仪表盘演示写入订单种子数据",
                                           "Bestelltabelle für die Dashboard-Demo befüllen")]
        case .edit:
            tool = "Edit"
            input = ["file_path": "/Users/dev/code/web-app/src/components/Dashboard.tsx",
                     "old_string": "const [orders, setOrders] = useState<Order[]>([]);",
                     "new_string": "const [orders, setOrders] = useState<Order[]>([]);\nconst [filters, setFilters] = useState<OrderFilters>(defaultFilters);"]
        case .write:
            tool = "Write"
            input = ["file_path": "/Users/dev/code/web-app/src/components/FilterBar.tsx",
                     "content": "import { DateRangePicker } from './DateRangePicker';\n\nexport function FilterBar({ value, onChange }: Props) {\n  return (\n    <div className=\"filter-bar\">\n      <DateRangePicker value={value.range} onChange={…} />\n"]
        case .mcp:
            tool = "mcp__github__create_pull_request"
            input = ["owner": "acme", "repo": "web-app", "title": lang.t("Dashboard filters", "仪表盘筛选", "Dashboard-Filter"),
                     "head": "feat/dashboard", "base": "main",
                     "body": lang.t("Adds a date-range and status filter bar above the orders table.",
                                    "在订单表格上方新增日期范围和状态筛选栏。",
                                    "Fügt über der Bestelltabelle eine Filterleiste für Zeitraum und Status hinzu.")]
        case .codex:
            sid = ID.codex
            cwd = "/Users/dev/code/api-server"
            source = "codex"
            input = ["command": "cargo test -p planner -- --nocapture"]
        }
        var sessions = [ID.claude: claude]
        if kind == .codex {
            var codex = codexWorking(lang)
            codex.status = .waitingApproval
            sessions = [ID.codex: codex]
        }
        if kind == .queued {
            var codex = codexWorking(lang)
            codex.status = .waitingApproval
            var mimo = mimoApproval(lang)
            mimo.status = .waitingApproval
            sessions[ID.codex] = codex
            sessions[ID.mimo] = mimo
        }
        state.sessions = sessions
        state.activeSessionId = sid
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sid, "cwd": cwd,
            "tool_name": tool, "tool_input": input,
        ]
        if source != "claude" { payload["_source"] = source }
        var releases = [await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent(payload))]
        if kind == .queued {
            releases.append(await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": ID.codex, "cwd": "/Users/dev/code/api-server",
                "_source": "codex", "tool_name": "Bash", "tool_input": ["command": "cargo bench -p planner"],
            ])))
            releases.append(await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": ID.mimo, "cwd": "/Users/dev/code/ml-pipeline",
                "tool_name": "Bash", "tool_input": ["command": "python scripts/backfill.py --month 2026-03"],
            ])))
        }
        state.refreshDerivedState()
        state.surface = .approvalCard(sessionId: sid)
        return GalleryDemoState(state: state) { releases.forEach { $0() } }
    }

    // MARK: Question cards

    static func question(_ kind: QuestionKind, lang: GalleryLang) async throws -> GalleryDemoState {
        let state = AppState()
        state.claudeUsage = usage()
        var claude = claudeWorking(lang)
        claude.status = .waitingQuestion
        claude.currentTool = nil
        state.sessions = [ID.claude: claude]
        state.activeSessionId = ID.claude
        let cwd = "/Users/dev/code/web-app"
        let stateLibs: [(String, String?)] = [
            (lang.t("Zustand (Recommended)", "Zustand（推荐）", "Zustand (empfohlen)"),
             lang.t("Tiny hook-based store with almost no boilerplate", "轻量的 Hook 式 store，几乎零样板代码",
                    "Winziger Hook-basierter Store fast ohne Boilerplate")),
            ("Redux Toolkit", lang.t("Structured slices, DevTools and RTK Query built in", "结构化 slice，自带 DevTools 与 RTK Query",
                                     "Strukturierte Slices, DevTools und RTK Query inklusive")),
            ("React Context", lang.t("Built into React; fine for state that rarely changes", "React 内置方案，适合不常变化的状态",
                                     "In React eingebaut; gut für selten geänderten State")),
        ]
        let release: () -> Void
        switch kind {
        case .single:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t("Which state library should the dashboard use?", "仪表盘应该用哪个状态管理库？",
                        "Welche State-Bibliothek soll das Dashboard nutzen?"),
                 lang.t("State", "状态管理", "State"), stateLibs, false),
            ])
        case .multi:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t("Which filters should the first version ship with?", "第一版要包含哪些筛选项？",
                        "Mit welchen Filtern soll die erste Version starten?"),
                 lang.t("Filters", "筛选", "Filter"), [
                    (lang.t("Date range", "日期范围", "Zeitraum"), lang.t("Presets plus a custom range", "预设区间加自定义", "Vorgaben plus eigener Zeitraum")),
                    (lang.t("Order status", "订单状态", "Bestellstatus"), nil),
                    (lang.t("Customer", "客户", "Kunde"), lang.t("Type-ahead search", "输入联想搜索", "Suche mit Vorschlägen")),
                    (lang.t("Amount", "金额", "Betrag"), nil),
                 ], true),
            ])
        case .many:
            let regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-central-1",
                           "ap-northeast-1", "ap-southeast-1", "ap-southeast-2", "sa-east-1"]
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t("Which region should the staging stack deploy to?", "预发环境部署到哪个区域？",
                        "In welche Region soll der Staging-Stack deployt werden?"),
                 lang.t("Region", "区域", "Region"),
                 regions.map { ($0, lang.t("Latency to the team: medium", "团队访问延迟：中等", "Latenz zum Team: mittel")) }, false),
            ])
        case .longText:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t(
                    "The orders table is rendered by both the legacy jQuery grid (used by the admin export page) and the new React table. Adding filters to both means duplicating the query-building logic, while moving the export page to the React table first would delay this change by about a day. Which approach should I take?",
                    "订单表格同时由旧的 jQuery 表格（管理后台导出页在用）和新的 React 表格渲染。两边都加筛选意味着要复制一份查询构建逻辑；而先把导出页迁到 React 表格，会让这次改动推迟大约一天。我该选哪种方案？",
                    "Die Bestelltabelle wird sowohl vom alten jQuery-Grid (Export-Seite im Admin-Bereich) als auch von der neuen React-Tabelle gerendert. Filter in beiden bedeuten doppelte Abfragelogik; die Export-Seite zuerst auf die React-Tabelle umzustellen, verzögert diese Änderung um etwa einen Tag. Welchen Weg soll ich nehmen?"),
                 lang.t("Approach", "方案", "Vorgehen"), [
                    (lang.t("Duplicate the logic for now", "暂时复制逻辑", "Logik vorerst duplizieren"), nil),
                    (lang.t("Migrate the export page first", "先迁移导出页", "Zuerst die Export-Seite migrieren"), nil),
                 ], false),
            ])
        case .freeText:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t("What should the default date range be?", "默认的日期范围应该是多少？", "Welcher Zeitraum soll standardmäßig gelten?"),
                 nil, [], false),
            ])
        case .wizard:
            release = try await DemoRequests.enqueueQuestion(state, sessionId: ID.claude, cwd: cwd, items: [
                (lang.t("Which state library should the dashboard use?", "仪表盘应该用哪个状态管理库？",
                        "Welche State-Bibliothek soll das Dashboard nutzen?"),
                 lang.t("State", "状态管理", "State"), stateLibs, false),
                (lang.t("Persist filters where?", "筛选状态保存在哪里？", "Wo sollen Filter gespeichert werden?"),
                 lang.t("Storage", "存储", "Speicher"), [("URL", nil), ("localStorage", nil)], false),
            ])
        case .legacy:
            let event = try DemoRequests.hookEvent([
                "hook_event_name": "Notification", "session_id": ID.claude, "cwd": cwd,
                "message": "Claude needs your input",
            ])
            release = await DemoRequests.enqueueQuestion(state, event: event, payload: QuestionPayload(
                question: lang.t("Claude needs your input to continue", "Claude 需要你的输入才能继续", "Claude braucht deine Eingabe, um fortzufahren"),
                options: nil, descriptions: nil, header: nil), askState: nil)
        }
        state.refreshDerivedState()
        state.surface = .questionCard(sessionId: ID.claude)
        return GalleryDemoState(state: state, release: release)
    }

    // MARK: Completion card

    static func completion(_ kind: CompletionKind, lang: GalleryLang) -> GalleryDemoState {
        let state = AppState()
        state.claudeUsage = usage()
        var s = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                        terminalBundleId: "com.mitchellh.ghostty", status: .idle, startedMinutesAgo: 18)
        let prompt = lang.t("Add filters to the dashboard page", "给仪表盘页面加上筛选功能", "Füge der Dashboard-Seite Filter hinzu")
        let reply: String
        switch kind {
        case .short:
            reply = lang.t("Done — the filter bar is live and all 42 tests pass.", "完成——筛选栏已上线，42 个测试全部通过。",
                           "Fertig – die Filterleiste ist aktiv und alle 42 Tests laufen durch.")
        case .markdown:
            reply = lang.t("""
                ## Dashboard filters

                Added a **filter bar** above the orders table:

                - Date range with presets (7d, 30d, custom)
                - Status multi-select
                - Filters persist in the URL via `useSearchParams`

                ```ts
                const filters = parseFilters(searchParams);
                const orders = useOrders(filters);
                ```

                | Check | Result |
                | --- | --- |
                | Unit tests | 42 passed |
                | Lint | clean |

                Next: decide whether the export page should share the filters.
                """, """
                ## 仪表盘筛选

                在订单表格上方加了一个**筛选栏**：

                - 日期范围（7 天、30 天、自定义）
                - 状态多选
                - 通过 `useSearchParams` 把筛选写入 URL

                ```ts
                const filters = parseFilters(searchParams);
                const orders = useOrders(filters);
                ```

                | 检查 | 结果 |
                | --- | --- |
                | 单元测试 | 42 个通过 |
                | Lint | 无问题 |

                下一步：决定导出页是否共用这些筛选。
                """, """
                ## Dashboard-Filter

                Über der Bestelltabelle gibt es jetzt eine **Filterleiste**:

                - Zeitraum mit Vorgaben (7 T, 30 T, eigener)
                - Status-Mehrfachauswahl
                - Filter bleiben per `useSearchParams` in der URL

                ```ts
                const filters = parseFilters(searchParams);
                const orders = useOrders(filters);
                ```

                | Prüfung | Ergebnis |
                | --- | --- |
                | Unit-Tests | 42 bestanden |
                | Lint | sauber |

                Als Nächstes: Soll die Export-Seite die Filter mitnutzen?
                """)
        }
        converse(&s, prompt: prompt, reply: reply)
        s.recap = SessionRecap(text: lang.t(
            "Shipped dashboard filters; 42 tests pass. Next: your call on the export page.",
            "仪表盘筛选已完成，42 个测试通过。下一步：由你决定导出页。",
            "Dashboard-Filter fertig; 42 Tests bestanden. Als Nächstes: deine Entscheidung zur Export-Seite."),
            createdAt: Date())
        state.sessions = [ID.claude: s, ID.codex: codexWorking(lang)]
        state.activeSessionId = ID.claude
        state.refreshDerivedState()
        state.surface = .completionCard(sessionId: ID.claude)
        return GalleryDemoState(state: state)
    }
}
