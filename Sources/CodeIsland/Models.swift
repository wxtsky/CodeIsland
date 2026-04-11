import Foundation
import CodeIslandCore

struct PermissionRequest {
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>
}

struct QuestionRequest {
    let event: HookEvent
    let question: QuestionPayload
    let continuation: CheckedContinuation<Data, Never>
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool
    /// All questions from AskUserQuestion (1-4). Empty for Notification-based questions.
    let allQuestions: [AskUserQuestionItem]

    init(event: HookEvent, question: QuestionPayload, continuation: CheckedContinuation<Data, Never>, isFromPermission: Bool = false, allQuestions: [AskUserQuestionItem] = []) {
        self.event = event
        self.question = question
        self.continuation = continuation
        self.isFromPermission = isFromPermission
        self.allQuestions = allQuestions
    }
}
