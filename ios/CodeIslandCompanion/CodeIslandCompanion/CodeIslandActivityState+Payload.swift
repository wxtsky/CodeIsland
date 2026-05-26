import Foundation

extension CodeIslandActivityAttributes.ContentState {
    init(payload: CompanionStatePayload) {
        self.init(
            sequence: payload.sequence,
            source: payload.source,
            status: payload.status.rawValue,
            toolName: payload.toolName,
            workspaceName: payload.workspaceName,
            message: payload.messages.last?.text,
            pendingAction: payload.pendingAction?.rawValue,
            questionText: payload.question?.question,
            questionHeader: payload.question?.header,
            questionProgress: payload.question.flatMap { question in
                question.total > 1 ? "\(question.index)/\(question.total)" : nil
            },
            updatedAt: payload.updatedAt
        )
    }
}
