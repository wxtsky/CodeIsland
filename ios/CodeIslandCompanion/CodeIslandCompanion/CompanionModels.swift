import Foundation

enum CompanionStatus: String, Codable, Hashable {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .processing: return "处理中"
        case .running: return "运行中"
        case .waitingApproval: return "等待批准"
        case .waitingQuestion: return "等待回答"
        }
    }

    var shortLabel: String {
        switch self {
        case .idle: return "空闲"
        case .processing: return "处理"
        case .running: return "运行"
        case .waitingApproval: return "批准"
        case .waitingQuestion: return "问题"
        }
    }
}

enum CompanionPendingAction: String, Codable {
    case approval
    case question
}

enum CompanionMessageRole: String, Codable {
    case user
    case assistant

    var label: String {
        switch self {
        case .user: return "你"
        case .assistant: return "助手"
        }
    }
}

struct CompanionMessagePreview: Codable, Identifiable {
    let id = UUID()
    let role: CompanionMessageRole
    let text: String

    private enum CodingKeys: String, CodingKey {
        case role
        case text
    }
}

struct CompanionQuestionPayload: Codable {
    let header: String?
    let question: String
    let options: [String]
    let descriptions: [String]
    let index: Int
    let total: Int
    let allowsMultipleSelection: Bool
}

struct CompanionSessionPreview: Codable, Identifiable, Hashable {
    let sessionId: String?
    let source: String
    let status: CompanionStatus
    let toolName: String?
    let workspaceName: String?
    let message: String?
    let updatedAt: Date

    var id: String {
        sessionId ?? "\(source)-\(workspaceName ?? "session")-\(updatedAt.timeIntervalSince1970)"
    }
}

struct CompanionStatePayload: Codable {
    let version: Int
    let sequence: UInt64
    let sessionId: String?
    let source: String
    let status: CompanionStatus
    let toolName: String?
    let workspaceName: String?
    let messages: [CompanionMessagePreview]
    let pendingAction: CompanionPendingAction?
    let question: CompanionQuestionPayload?
    let sessions: [CompanionSessionPreview]
    let updatedAt: Date

    init(
        version: Int,
        sequence: UInt64,
        sessionId: String?,
        source: String,
        status: CompanionStatus,
        toolName: String?,
        workspaceName: String?,
        messages: [CompanionMessagePreview],
        pendingAction: CompanionPendingAction?,
        question: CompanionQuestionPayload?,
        sessions: [CompanionSessionPreview] = [],
        updatedAt: Date
    ) {
        self.version = version
        self.sequence = sequence
        self.sessionId = sessionId
        self.source = source
        self.status = status
        self.toolName = toolName
        self.workspaceName = workspaceName
        self.messages = messages
        self.pendingAction = pendingAction
        self.question = question
        self.sessions = sessions
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sequence
        case sessionId
        case source
        case status
        case toolName
        case workspaceName
        case messages
        case pendingAction
        case question
        case sessions
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        source = try container.decode(String.self, forKey: .source)
        status = try container.decode(CompanionStatus.self, forKey: .status)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        messages = try container.decode([CompanionMessagePreview].self, forKey: .messages)
        pendingAction = try container.decodeIfPresent(CompanionPendingAction.self, forKey: .pendingAction)
        question = try container.decodeIfPresent(CompanionQuestionPayload.self, forKey: .question)
        sessions = try container.decodeIfPresent([CompanionSessionPreview].self, forKey: .sessions) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum CompanionCommandType: String, Codable {
    case requestCurrentState
    case approveCurrentPermission
    case denyCurrentPermission
    case skipCurrentQuestion
    case answerQuestion
    case focus
}

struct CompanionCommandPayload: Codable {
    let version: Int
    let type: CompanionCommandType
    let sessionId: String?
    let source: String?
    let answer: String?

    init(version: Int = 1, type: CompanionCommandType, sessionId: String? = nil, source: String? = nil, answer: String? = nil) {
        self.version = version
        self.type = type
        self.sessionId = sessionId
        self.source = source
        self.answer = answer
    }
}
