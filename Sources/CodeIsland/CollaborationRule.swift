// 多 Agent 协同模式的数据模型和规则管理
import AppKit
import Foundation

// 目标 Agent 类型
enum AgentTargetType: String, Codable, CaseIterable, Identifiable {
    case claude = "claude"
    case codex = "codex"
    case cursor = "cursor"
    case gemini = "gemini"
    case copilot = "copilot"
    case codebuddy = "codebuddy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:         return "Claude Code"
        case .codex:          return "Codex CLI"
        case .cursor:         return "Cursor"
        case .gemini:         return "Gemini"
        case .copilot:        return "Copilot"
        case .codebuddy:      return "CodeBuddy"
        }
    }

    // IDE agents inject prompt via keyboard simulation
    var isIDE: Bool {
        switch self {
        case .codebuddy, .cursor: return true
        default: return false
        }
    }

    var isCLI: Bool { !isIDE }

    // CLI binary search paths
    var binarySearchPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claude:
            return ["\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        case .codex:
            return ["\(home)/.local/bin/codex", "/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        case .cursor:
            // Cursor uses `cursor` CLI or the app bundle
            return ["/usr/local/bin/cursor", "/opt/homebrew/bin/cursor",
                    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"]
        case .gemini:
            return ["\(home)/.local/bin/gemini", "/usr/local/bin/gemini", "/opt/homebrew/bin/gemini"]
        case .copilot:
            return ["\(home)/.local/bin/github-copilot", "/usr/local/bin/github-copilot", "/opt/homebrew/bin/github-copilot"]
        case .codebuddy:
            return ["\(home)/.codebuddy/bin/buddycn"]
        }
    }

    func findBinary() -> String? {
        if isIDE { return findIDEApp() }
        return binarySearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // For IDE agents, check if the app is installed (by bundle ID)
    private func findIDEApp() -> String? {
        let bundleIds: [String]
        switch self {
        case .cursor:    bundleIds = ["com.todesktop.230313mzl4w4u92"]
        case .codebuddy: bundleIds = ["com.tencent.codebuddy", "com.tencent.codebuddycn"]
        default: return nil
        }
        for bid in bundleIds {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                return bid
            }
        }
        // Fallback: check CLI binary
        return binarySearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Session source identifiers that match this target agent type
    var matchingSources: Set<String> {
        switch self {
        case .claude:         return ["claude"]
        case .codex:          return ["codex"]
        case .cursor:         return ["cursor"]
        case .gemini:         return ["gemini"]
        case .copilot:        return ["copilot"]
        case .codebuddy:      return ["codebuddy"]
        }
    }

    // Bundle IDs for IDE window activation
    var appBundleIds: [String] {
        switch self {
        case .cursor:    return ["com.todesktop.230313mzl4w4u92"]
        case .codebuddy: return ["com.tencent.codebuddy", "com.tencent.codebuddycn"]
        default: return []
        }
    }
}

// 内置 Prompt 模板类型
enum PromptTemplateType: String, Codable, CaseIterable, Identifiable {
    case codeReview = "code_review"
    case fixIssues = "fix_issues"
    case securityAudit = "security_audit"
    case custom = "custom"

    var id: String { rawValue }
}

// 协作规则
struct CollaborationRule: Identifiable, Codable {
    let id: UUID
    var name: String
    var enabled: Bool
    var triggerSource: String
    var targetAgent: AgentTargetType
    var templateType: PromptTemplateType
    var customPrompt: String
    var requireConfirmation: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        enabled: Bool = true,
        triggerSource: String = "codebuddy",
        targetAgent: AgentTargetType = .claude,
        templateType: PromptTemplateType = .codeReview,
        customPrompt: String = "",
        requireConfirmation: Bool = true
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.triggerSource = triggerSource
        self.targetAgent = targetAgent
        self.templateType = templateType
        self.customPrompt = customPrompt
        self.requireConfirmation = requireConfirmation
    }
}

// 协作规则管理器
@MainActor
class CollaborationManager: ObservableObject {
    static let shared = CollaborationManager()

    @Published var rules: [CollaborationRule] = []

    private let storageKey = "collaboration_rules"

    private init() {
        loadRules()
    }

    func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CollaborationRule].self, from: data) else {
            rules = Self.defaultRules
            return
        }
        rules = decoded
        ensureCoreInteropRules()
    }

    // Ensure required core interop rules exist (without forcing users to reconfigure)
    private func ensureCoreInteropRules() {
        var changed = false
        for builtin in Self.defaultRules {
            let exists = rules.contains {
                $0.triggerSource == builtin.triggerSource && $0.targetAgent == builtin.targetAgent
            }
            if !exists {
                rules.append(builtin)
                changed = true
            }
        }
        if changed { saveRules() }
    }

    func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func addRule(_ rule: CollaborationRule) {
        rules.append(rule)
        saveRules()
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    func updateRule(_ rule: CollaborationRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
            saveRules()
        }
    }

    func matchingRules(forSource source: String) -> [CollaborationRule] {
        rules.filter { $0.enabled && $0.triggerSource == source }
    }

    // 默认规则：CodeBuddy/Claude/Codex/Cursor 互通（CodeBuddy<->Cursor 除外）
    static let defaultRules: [CollaborationRule] = [
        // CodeBuddy <-> Claude
        CollaborationRule(name: "CodeBuddy -> Claude Code Review",
            triggerSource: "codebuddy", targetAgent: .claude, templateType: .codeReview, requireConfirmation: true),
        CollaborationRule(name: "Claude -> CodeBuddy Fix Issues",
            triggerSource: "claude", targetAgent: .codebuddy, templateType: .fixIssues, requireConfirmation: true),
        // CodeBuddy <-> Codex
        CollaborationRule(name: "CodeBuddy -> Codex Code Review",
            triggerSource: "codebuddy", targetAgent: .codex, templateType: .codeReview, requireConfirmation: true),
        CollaborationRule(name: "Codex -> CodeBuddy Fix Issues",
            triggerSource: "codex", targetAgent: .codebuddy, templateType: .fixIssues, requireConfirmation: true),
        // Claude <-> Cursor
        CollaborationRule(name: "Claude -> Cursor Fix Issues",
            triggerSource: "claude", targetAgent: .cursor, templateType: .fixIssues, requireConfirmation: true),
        CollaborationRule(name: "Cursor -> Claude Code Review",
            triggerSource: "cursor", targetAgent: .claude, templateType: .codeReview, requireConfirmation: true),
        // Claude <-> Codex
        CollaborationRule(name: "Claude -> Codex Fix Issues",
            triggerSource: "claude", targetAgent: .codex, templateType: .fixIssues, requireConfirmation: true),
        CollaborationRule(name: "Codex -> Claude Code Review",
            triggerSource: "codex", targetAgent: .claude, templateType: .codeReview, requireConfirmation: true),
        // Codex <-> Cursor
        CollaborationRule(name: "Codex -> Cursor Fix Issues",
            triggerSource: "codex", targetAgent: .cursor, templateType: .fixIssues, requireConfirmation: true),
        CollaborationRule(name: "Cursor -> Codex Code Review",
            triggerSource: "cursor", targetAgent: .codex, templateType: .codeReview, requireConfirmation: true),
    ]
}
