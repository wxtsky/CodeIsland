import Foundation
import CodeIslandCore

struct PermissionRequest {
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>
}

struct AskUserQuestionItem {
    let payload: QuestionPayload
    let answerKey: String
}

struct AskUserQuestionState {
    let items: [AskUserQuestionItem]
    var answers: [String: String]

    var canConfirm: Bool {
        !items.isEmpty && items.allSatisfy { answers[$0.answerKey] != nil }
    }

    mutating func select(questionIndex: Int, option: String) {
        guard items.indices.contains(questionIndex) else { return }
        let key = items[questionIndex].answerKey
        answers[key] = option
    }
}

struct QuestionRequest {
    let event: HookEvent
    var question: QuestionPayload
    let continuation: CheckedContinuation<Data, Never>
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool
    var askUserQuestionState: AskUserQuestionState?

    init(
        event: HookEvent,
        question: QuestionPayload,
        continuation: CheckedContinuation<Data, Never>,
        isFromPermission: Bool = false,
        askUserQuestionState: AskUserQuestionState? = nil
    ) {
        self.event = event
        self.question = askUserQuestionState?.items.first?.payload ?? question
        self.continuation = continuation
        self.isFromPermission = isFromPermission
        self.askUserQuestionState = askUserQuestionState
    }
}
