// Prompt 模板加载与变量替换，支持用户自定义覆盖内置模板
import Foundation

struct PromptTemplateManager {
    // UserDefaults key prefix for user-customized templates
    private static let customKeyPrefix = "promptTemplate_"

    // 内置模板定义
    private static let builtinTemplates: [PromptTemplateType: (en: String, zh: String)] = [
        .codeReview: (
            en: """
            The above is the output from {source}. Please review the recent code changes in this project for:
            - Potential bugs and logic errors
            - Code style and readability issues
            - Performance concerns
            - Security vulnerabilities
            Please provide specific suggestions for improvement.
            """,
            zh: """
            以上是 {source} 的输出，请对该项目最近的代码变更进行 Code Review，检查：
            - 潜在的 Bug 和逻辑错误
            - 代码风格和可读性问题
            - 性能隐患
            - 安全漏洞
            请给出具体的修改建议。
            """
        ),
        .fixIssues: (
            en: """
            The above is the Code Review result from {source}. Please fix all the issues mentioned above. \
            For each fix, explain what was wrong and how you fixed it.
            """,
            zh: """
            以上是 {source} 的 Code Review 结果，请修复上述提到的所有问题。\
            对于每个修复，请说明问题所在以及修复方式。
            """
        ),
        .securityAudit: (
            en: """
            The above is the output from {source}. Please perform a security audit on the recent code changes, focusing on:
            - Input validation and sanitization
            - Authentication and authorization
            - Data exposure and privacy
            - Injection vulnerabilities (SQL, XSS, command injection)
            - Dependency security
            """,
            zh: """
            以上是 {source} 的输出，请对最近的代码变更进行安全审计，重点检查：
            - 输入验证和清理
            - 身份认证和授权
            - 数据泄露和隐私
            - 注入漏洞（SQL、XSS、命令注入）
            - 依赖安全
            """
        ),
    ]

    // 获取模板文本（优先用户覆盖，其次内置）
    static func template(for type: PromptTemplateType, language: String = "zh") -> String {
        if type == .custom { return "" }
        let key = customKeyPrefix + type.rawValue + "_" + language
        if let userTemplate = UserDefaults.standard.string(forKey: key), !userTemplate.isEmpty {
            return userTemplate
        }
        guard let t = builtinTemplates[type] else { return "" }
        return language == "zh" ? t.zh : t.en
    }

    // 获取内置默认模板（用于重置）
    static func builtinTemplate(for type: PromptTemplateType, language: String = "zh") -> String {
        guard let t = builtinTemplates[type] else { return "" }
        return language == "zh" ? t.zh : t.en
    }

    // 保存用户自定义模板
    static func setUserTemplate(for type: PromptTemplateType, language: String, text: String) {
        let key = customKeyPrefix + type.rawValue + "_" + language
        if text.isEmpty || text == builtinTemplate(for: type, language: language) {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    // 检查某模板是否被用户修改过
    static func isCustomized(for type: PromptTemplateType, language: String) -> Bool {
        let key = customKeyPrefix + type.rawValue + "_" + language
        return UserDefaults.standard.string(forKey: key) != nil
    }

    // 重置为内置模板
    static func resetTemplate(for type: PromptTemplateType, language: String) {
        let key = customKeyPrefix + type.rawValue + "_" + language
        UserDefaults.standard.removeObject(forKey: key)
    }

    // 构建完整 Prompt：context + 模板
    static func buildPrompt(
        rule: CollaborationRule,
        sourceAgent: String,
        context: String,
        language: String = "zh"
    ) -> String {
        let templateText: String
        if rule.templateType == .custom {
            templateText = rule.customPrompt
        } else {
            templateText = template(for: rule.templateType, language: language)
        }

        let sourceName = AgentTargetType(rawValue: sourceAgent)?.displayName ?? sourceAgent
        let resolved = templateText.replacingOccurrences(of: "{source}", with: sourceName)

        var result = ""
        if !context.isEmpty {
            result += context + "\n\n"
        }
        result += resolved
        return result
    }

    // 模板显示名称
    static func templateName(for type: PromptTemplateType, language: String = "zh") -> String {
        switch type {
        case .codeReview: return language == "zh" ? "Code Review" : "Code Review"
        case .fixIssues: return language == "zh" ? "修复问题" : "Fix Issues"
        case .securityAudit: return language == "zh" ? "安全审计" : "Security Audit"
        case .custom: return language == "zh" ? "自定义" : "Custom"
        }
    }
}
