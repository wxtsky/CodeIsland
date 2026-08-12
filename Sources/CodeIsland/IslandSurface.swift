/// 面板当前展示的 "面"——同一时刻只能有一个
enum IslandSurface: Equatable {
    /// 收起状态，只显示 compact bar
    case collapsed
    /// 用户主动展开，显示 session 列表
    case sessionList
    /// 显示权限审批卡片
    case approvalCard(sessionId: String)
    /// 显示问答卡片
    case questionCard(sessionId: String)
    /// 自动展开显示完成通知
    case completionCard(sessionId: String)

    var isExpanded: Bool { self != .collapsed }

    /// 当前 surface 关联的 session ID（如有）
    var sessionId: String? {
        switch self {
        case .collapsed, .sessionList: return nil
        case .approvalCard(let id), .questionCard(let id), .completionCard(let id): return id
        }
    }

    /// Session of the surface only when it is the matching card kind. A
    /// permission shortcut fired while a question card is up must not address
    /// that session's (non-existent) approval and discard the live card. (#308)
    var approvalSessionId: String? {
        if case .approvalCard(let id) = self { return id }
        return nil
    }

    var questionSessionId: String? {
        if case .questionCard(let id) = self { return id }
        return nil
    }
}
