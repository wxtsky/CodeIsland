import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// Offscreen README screenshot harness.
///
/// Renders the real `NotchPanelView`, fed curated demo sessions, onto a
/// stylised MacBook top edge (wallpaper, menu bar, notch) and writes 2× PNGs
/// for the README. Nothing is launched: the panel is hosted in a window that
/// is never shown, so no hooks get installed and a running island is left
/// alone. Opt-in like MascotRenderHarness — skipped unless `README_SHOT_DIR`
/// is set:
///
///     README_SHOT_DIR=docs/images swift test --filter ReadmeScreenshotHarness
///     # optional, lossless (zlib 9) — trims ~25%:
///     python3 -c "import glob; from PIL import Image; [Image.open(f).save(f, optimize=True) for f in glob.glob('docs/images/readme-*.png')]"
///
/// Optional filters: `README_SHOT_ONLY=hero,approval,question`,
/// `README_SHOT_LANGS=en,zh`. Every settings key (`SettingsKey`) is cleared
/// for the render (so the shots show shipped defaults) and restored after.
/// Terminal badges use the icons of whatever terminals are installed on the
/// rendering Mac (Ghostty, iTerm2, Cursor, Warp); a missing app shows its
/// badge text only.
@MainActor
final class ReadmeScreenshotHarness: XCTestCase {

    func testRenderReadmeScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["README_SHOT_DIR"] else {
            throw XCTSkip("README_SHOT_DIR not set — harness is opt-in")
        }
        let only = env["README_SHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let langs = (env["README_SHOT_LANGS"] ?? "en,zh").split(separator: ",").compactMap { ShotLang(rawValue: String($0)) }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // Views touch NSApp (e.g. QuestionBar.onAppear); make sure it exists.
        _ = NSApplication.shared

        let sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        let savedLanguage = L10n.shared.language
        // Gate the mascots off so MascotTimeline renders one pinned frame
        // (`mascotStaticTime`) instead of a live TimelineView.
        MascotAnimationGate.shared.setPanelVisible(false)
        defer {
            MascotAnimationGate.shared.setPanelVisible(true)
            L10n.shared.language = savedLanguage
            sandbox.restore()
        }

        for lang in langs {
            L10n.shared.language = lang.rawValue
            for shot in Shot.allCases where only?.contains(shot.rawValue) ?? true {
                let demo = try await ReadmeDemo.make(shot, lang: lang)
                defer { demo.release() }

                let panel = try renderPanel(demo.state)
                let stage = Stage(panel: panel.image, panelHeight: panel.height, layout: shot.layout,
                                  clock: lang == .zh ? "周二 9:41" : "Tue 9:41")
                let image = try XCTUnwrap(OffscreenRender.rasterize(stage), "stage render failed for \(shot)/\(lang)")
                let rep = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(outDir)/\(shot.fileName(lang)).png"))
            }
        }
    }

    /// Renders the panel exactly as PanelWindowController hosts it on a 14"
    /// MacBook Pro (1512pt wide, 185×32pt notch), then trims the transparent
    /// window area below the panel.
    private func renderPanel(_ state: AppState) throws -> (image: CGImage, height: CGFloat) {
        let screen = StageScreen.macBook14
        let view = NotchPanelView(
            appState: state,
            hasNotch: true,
            notchHeight: screen.notchHeight,
            notchW: screen.notchWidth,
            screenWidth: screen.screenWidth
        )
        .environment(\.mascotStaticTime, ReadmeDemo.mascotTime)
        .environment(\.colorScheme, .dark)
        .frame(width: screen.windowWidth, height: 900)

        // Hosted like the app, not through ImageRenderer: the question card's
        // options sit in a scroll view, which ImageRenderer leaves blank.
        let full = try OffscreenRender.hosted(view, size: CGSize(width: screen.windowWidth, height: 900),
                                              appearance: .darkAqua)
        return try OffscreenRender.trimmedToContent(full)
    }
}

// MARK: - Shots

private enum ShotLang: String {
    case en, zh
}

private enum Shot: String, CaseIterable {
    case hero
    case approval
    case question

    func fileName(_ lang: ShotLang) -> String {
        "readme-\(rawValue)" + (lang == .zh ? "-zh" : "")
    }

    var layout: StageLayout {
        switch self {
        case .hero: return StageLayout(width: 900, bottomMargin: 76, menuItems: true)
        case .approval, .question: return StageLayout(width: 668, bottomMargin: 56, menuItems: false)
        }
    }
}

/// A demo AppState plus whatever must be torn down after rendering it
/// (pending hook continuations are resumed so no task is left hanging).
@MainActor
private struct DemoState {
    let state: AppState
    var release: () -> Void = {}
}

// MARK: - Curated demo data

@MainActor
private enum ReadmeDemo {
    /// Timeline instant every mascot is frozen at — picked so none of them
    /// is mid-blink or mid-quirk.
    static let mascotTime: Double = 5.2

    enum ID {
        static let claude = "a3e1c0d4-6f2b-4c8e-9b17-52d8e4f07c91"
        static let codex = "b7d2f5a8-1c4e-4e90-8a3b-6f1c2d9e04b3"
        static let cursor = "c5a9e3b1-8d7f-4b21-a6c4-0e3f9d2b7a58"
        static let gemini = "d8f4b2c6-3a1e-4d57-b9e8-7c2a5f1d93e6"
    }

    static func make(_ shot: Shot, lang: ShotLang) async throws -> DemoState {
        switch shot {
        case .hero: return hero(lang)
        case .approval: return try await approval(lang)
        case .question: return try await question(lang)
        }
    }

    private static func t(_ lang: ShotLang, _ en: String, _ zh: String) -> String {
        lang == .zh ? zh : en
    }

    private static func session(
        source: String,
        project: String,
        branch: String?,
        terminalBundleId: String,
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

    // MARK: Hero — session list

    private static func hero(_ lang: ShotLang) -> DemoState {
        let state = AppState()

        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .running, startedMinutesAgo: 12)
        claude.model = "claude-opus-4-5"
        let claudePrompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = claudePrompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: claudePrompt))
        claude.addRecentMessage(ChatMessage(isUser: false, text: t(lang,
            "Adding a date-range and status filter bar above the orders table.",
            "先在订单表格上方加一个日期范围和状态筛选栏。")))
        claude.currentTool = "Edit"
        claude.toolDescription = "src/components/Dashboard.tsx"
        claude.subagents["explore-1"] = SubagentState(agentId: "explore-1", agentType: "Explore")

        var codex = session(source: "codex", project: "api-server", branch: "perf/query-planner",
                            terminalBundleId: "com.googlecode.iterm2", status: .running, startedMinutesAgo: 26)
        codex.model = "gpt-5-codex"
        let codexPrompt = t(lang, "Speed up the slow /search endpoint", "优化 /search 接口的慢查询")
        let codexOutput = t(lang, "Added cost-based planner; running cargo test…", "已加入基于代价的查询规划器，正在运行 cargo test…")
        codex.lastUserPrompt = codexPrompt
        codex.addRecentMessage(ChatMessage(isUser: true, text: codexPrompt))
        codex.addRecentMessage(ChatMessage(isUser: false, text: codexOutput))
        codex.lastAssistantMessage = codexOutput
        codex.liveCodexOutput = codexOutput
        codex.currentTool = "Bash"
        codex.toolDescription = "cargo test -p planner"

        var cursor = session(source: "cursor", project: "mobile-app", branch: "fix/feed-scroll",
                             terminalBundleId: "com.todesktop.230313mzl4w4u92", status: .waitingQuestion, startedMinutesAgo: 4)
        let cursorPrompt = t(lang, "Fix the scroll jank on the feed", "修复信息流滚动卡顿")
        cursor.lastUserPrompt = cursorPrompt
        cursor.addRecentMessage(ChatMessage(isUser: true, text: cursorPrompt))
        cursor.cursorPendingQuestion = t(lang,
            "Virtualize the feed list, or switch to pagination?",
            "信息流列表改用虚拟滚动，还是换成分页？")

        var gemini = session(source: "gemini", project: "docs-site", branch: "main",
                             terminalBundleId: "dev.warp.Warp-Stable", status: .idle, startedMinutesAgo: 68)
        gemini.model = "gemini-2.5-pro"
        let geminiPrompt = t(lang, "Document the new filter API", "为新的筛选 API 补充文档")
        let geminiReply = t(lang,
            "Updated 6 pages under docs/api and fixed 3 broken links.",
            "已更新 docs/api 下的 6 个页面，并修复了 3 个失效链接。")
        gemini.lastUserPrompt = geminiPrompt
        gemini.lastAssistantMessage = geminiReply
        gemini.addRecentMessage(ChatMessage(isUser: true, text: geminiPrompt))
        gemini.addRecentMessage(ChatMessage(isUser: false, text: geminiReply))

        state.sessions = [ID.claude: claude, ID.codex: codex, ID.cursor: cursor, ID.gemini: gemini]
        state.activeSessionId = ID.claude

        // Usage footer (on by default). Set before expanding so the panel
        // never kicks off a scan of this machine's real ~/.claude history.
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
        state.claudeUsage = ClaudeUsageScanner.Snapshot(
            last5h: fiveHours,
            today: today,
            hourlyOutputTokens: [0, 3_100, 14_800, 9_200, 0, 0, 18_400, 36_500, 22_900, 12_300, 41_800, 27_600],
            scannedAt: Date()
        )
        state.surface = .sessionList
        return DemoState(state: state)
    }

    // MARK: Approval card

    private static func approval(_ lang: ShotLang) async throws -> DemoState {
        let state = AppState()
        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .waitingApproval, startedMinutesAgo: 14)
        let prompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = prompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        claude.currentTool = "Bash"
        claude.toolDescription = "npm run test -- --coverage"
        state.sessions = [ID.claude: claude]
        state.activeSessionId = ID.claude

        let event = try hookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": ID.claude,
            "cwd": "/Users/dev/code/web-app",
            "tool_name": "Bash",
            "tool_input": [
                "command": "npm run test -- --coverage",
                "description": t(lang, "Run the test suite with a coverage report", "运行测试套件并生成覆盖率报告"),
            ],
        ])
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.permissionQueue.append(PermissionRequest(event: event, continuation: continuation))
            }
        }
        await waitUntil { !state.permissionQueue.isEmpty }
        state.surface = .approvalCard(sessionId: ID.claude)
        return DemoState(state: state) {
            for request in state.permissionQueue { request.continuation.resume(returning: Data()) }
            state.permissionQueue.removeAll()
            _ = task
        }
    }

    // MARK: Question card (AskUserQuestion)

    private static func question(_ lang: ShotLang) async throws -> DemoState {
        let state = AppState()
        var claude = session(source: "claude", project: "web-app", branch: "feat/dashboard",
                             terminalBundleId: "com.mitchellh.ghostty", status: .waitingQuestion, startedMinutesAgo: 9)
        let prompt = t(lang, "Add filters to the dashboard page", "给仪表盘页面加上筛选功能")
        claude.lastUserPrompt = prompt
        claude.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        state.sessions = [ID.claude: claude]
        state.activeSessionId = ID.claude

        let questionText = t(lang, "Which state library should the dashboard use?", "仪表盘应该用哪个状态管理库？")
        let options = [
            (t(lang, "Zustand (Recommended)", "Zustand（推荐）"),
             t(lang, "Tiny hook-based store with almost no boilerplate", "轻量的 Hook 式 store，几乎零样板代码")),
            ("Redux Toolkit",
             t(lang, "Structured slices, DevTools and RTK Query built in", "结构化 slice，自带 DevTools 与 RTK Query")),
            ("React Context",
             t(lang, "Built into React; fine for state that rarely changes", "React 内置方案，适合不常变化的状态")),
        ]
        let header = t(lang, "State", "状态管理")
        let event = try hookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": ID.claude,
            "cwd": "/Users/dev/code/web-app",
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": questionText,
                    "header": header,
                    "multiSelect": false,
                    "options": options.map { ["label": $0.0, "description": $0.1] },
                ]],
            ],
        ])
        // Same item construction as AppState.handleAskUserQuestion.
        let payload = QuestionPayload(
            question: questionText,
            options: options.map(\.0),
            descriptions: options.map(\.1),
            header: header
        )
        let item = AskUserQuestionItem(payload: payload, answerKey: questionText, multiSelect: false)
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.questionQueue.append(QuestionRequest(
                    event: event,
                    question: payload,
                    continuation: continuation,
                    isFromPermission: true,
                    askUserQuestionState: AskUserQuestionState(items: [item], answers: [:])
                ))
            }
        }
        await waitUntil { !state.questionQueue.isEmpty }
        state.surface = .questionCard(sessionId: ID.claude)
        return DemoState(state: state) {
            for request in state.questionQueue { request.resolution.resumeHook(returning: Data()) }
            state.questionQueue.removeAll()
            _ = task
        }
    }

    private static func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), "HookEvent parse failed")
    }
}
