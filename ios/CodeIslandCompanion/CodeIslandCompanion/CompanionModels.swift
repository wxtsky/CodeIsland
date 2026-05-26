import Foundation

enum CompanionStatus: String, Codable {
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
    let updatedAt: Date
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
