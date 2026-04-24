import Foundation
import CodeIslandCore

struct PermissionRequest {
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>

    var toolUseId: String? { event.toolUseId }
}

struct AskUserQuestionItem {
    let payload: QuestionPayload
    let answerKey: String
    let multiSelect: Bool
}

struct AskUserQuestionState {
    let items: [AskUserQuestionItem]
    var answers: [String: String]

    var canConfirm: Bool {
        items.allSatisfy { answers[$0.answerKey] != nil }
    }

    mutating func select(questionIndex: Int, option: String) {
        guard items.indices.contains(questionIndex) else { return }
        answers[items[questionIndex].answerKey] = option
    }
}

struct QuestionRequest {
    let event: HookEvent
    let question: QuestionPayload
    let continuation: CheckedContinuation<Data, Never>
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool
    var askUserQuestionState: AskUserQuestionState?

    init(event: HookEvent, question: QuestionPayload, continuation: CheckedContinuation<Data, Never>, isFromPermission: Bool = false, askUserQuestionState: AskUserQuestionState? = nil) {
        self.event = event
        self.question = askUserQuestionState?.items.first?.payload ?? question
        self.continuation = continuation
        self.isFromPermission = isFromPermission
        self.askUserQuestionState = askUserQuestionState
    }
}
