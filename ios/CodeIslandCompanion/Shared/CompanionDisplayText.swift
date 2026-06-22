import Foundation

enum CompanionDisplayText {
    static func source(_ text: String?) -> String {
        guard let trimmed = cleaned(text) else { return "CodeIsland" }

        switch trimmed.lowercased() {
        case "claude", "claudecode", "clawd":
            return "CLAUDE"
        case "codex", "openai":
            return "CODEX"
        case "gemini":
            return "GEMINI"
        case "cursor":
            return "CURSOR"
        case "opencode":
            return "OPENCODE"
        case "qwen":
            return "QWEN"
        default:
            return trimmed.uppercased()
        }
    }

    static func message(_ text: String?) -> String? {
        guard let trimmed = cleaned(text) else { return nil }

        switch trimmed {
        case "[Request interrupted by user]", "Request interrupted by user":
            return "请求已被你中断"
        case "[Request interrupted by user for tool use]", "Request interrupted by user for tool use":
            return "工具调用已被你中断"
        default:
            return trimmed
        }
    }

    static func tool(_ text: String?) -> String? {
        guard let trimmed = cleaned(text) else { return nil }

        switch trimmed.lowercased() {
        case "askuserquestion":
            return "提问"
        case "bash", "shell":
            return "终端"
        case "read":
            return "读取"
        case "edit", "write", "multiedit":
            return "编辑"
        case "grep", "glob", "search":
            return "搜索"
        case "webfetch", "websearch":
            return "网页"
        case "todowrite":
            return "计划"
        case "notebookedit":
            return "笔记"
        default:
            return trimmed
        }
    }

    static func workspace(_ text: String?) -> String? {
        guard let trimmed = cleaned(text) else { return nil }

        switch trimmed.lowercased() {
        case "workspace":
            return "工作区"
        default:
            return trimmed
        }
    }

    static func subtitle(workspaceName: String?, toolName: String?, fallback: String) -> String {
        if let workspaceName = workspace(workspaceName) {
            return workspaceName
        }
        if let toolName = tool(toolName) {
            return toolName
        }
        return fallback
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static var markdownCache: [String: AttributedString] = [:]
    private static let markdownCacheLimit = 128

    /// 行内 markdown 渲染（粗体 / 斜体 / 代码 / 链接），与 Mac notch 一致。
    /// 只解析行内语法、保留空白。仅用于消息正文与问题等散文内容，
    /// 不要用于来源名 / 工作区 / 工具名（含下划线的路径会被误判为斜体）。
    ///
    /// 解析失败、或某些语法（如链接定义、未闭合标签）解析出空内容时，回退为纯文本。
    /// 结果按文本缓存：同一段文字始终返回同一个 AttributedString，避免看板被活动会话
    /// 频繁刷新时，静止的空闲会话因重复解析出新实例而被 SwiftUI 反复重绘/动画（闪烁）。
    static func inlineMarkdown(_ text: String) -> AttributedString {
        if let cached = markdownCache[text] {
            return cached
        }
        let result: AttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ), !attributed.characters.isEmpty {
            result = attributed
        } else {
            result = AttributedString(text)
        }
        if markdownCache.count >= markdownCacheLimit {
            markdownCache.removeAll(keepingCapacity: true)
        }
        markdownCache[text] = result
        return result
    }
}
