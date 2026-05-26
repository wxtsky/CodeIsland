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
}
