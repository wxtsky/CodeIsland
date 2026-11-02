import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The question card's answer state belongs to one request. SwiftUI hands a
/// view's @State to whatever request is rendered into the same slot next, so
/// the state itself must refuse to carry answers across requests. (#333)
final class QuestionWizardStateTests: XCTestCase {
    private let requestA = UUID()
    private let requestB = UUID()

    func testLastAnswerSubmitsEveryAnswerInQuestionOrder() {
        var wizard = QuestionWizardState(requestId: requestA)

        XCTAssertNil(wizard.record(answer("Q1", "a"), for: requestA, questionCount: 2))
        XCTAssertEqual(wizard.currentQuestionIndex, 1)

        let submission = wizard.record(answer("Q2", "b"), for: requestA, questionCount: 2)
        XCTAssertEqual(submission?.map(\.question), ["Q1", "Q2"])
        XCTAssertEqual(submission?.map(\.answer), ["a", "b"])
    }

    /// The #333 report: session A's card is answered, session B's card is
    /// rendered in its place with A's state, and B's single answer went out
    /// behind A's — so B's question was sent A's answer.
    func testAnswersForOneRequestNeverReachAnotherRequestsSubmission() {
        var wizard = QuestionWizardState(requestId: requestA)
        let first = wizard.record(answer("Pass openURL a bare path?", "openURL 传裸路径"), for: requestA, questionCount: 1)
        XCTAssertEqual(first?.map(\.answer), ["openURL 传裸路径"])

        // Same state instance, next request — the in-place card swap.
        let second = wizard.record(answer("是否立即触发构建？", "触发"), for: requestB, questionCount: 1)

        XCTAssertEqual(second?.map(\.question), ["是否立即触发构建？"])
        XCTAssertEqual(second?.map(\.answer), ["触发"])
    }

    func testRebindingToAnotherRequestDropsProgressAndInput() {
        var wizard = QuestionWizardState(requestId: requestA)
        _ = wizard.record(answer("Q1", "a"), for: requestA, questionCount: 3)
        wizard.selectedIndex = 1
        wizard.selectedIndices = [0, 2]
        wizard.showOtherInput = true
        wizard.otherText = "typed for A"
        wizard.textInput = "also for A"

        wizard.bind(to: requestB)

        XCTAssertEqual(wizard.requestId, requestB)
        XCTAssertEqual(wizard.currentQuestionIndex, 0, "B must start at its own first question")
        XCTAssertTrue(wizard.collectedAnswers.isEmpty)
        XCTAssertNil(wizard.selectedIndex)
        XCTAssertTrue(wizard.selectedIndices.isEmpty)
        XCTAssertFalse(wizard.showOtherInput)
        XCTAssertEqual(wizard.otherText, "")
        XCTAssertEqual(wizard.textInput, "")
    }

    func testRebindingToTheSameRequestKeepsProgress() {
        var wizard = QuestionWizardState(requestId: requestA)
        _ = wizard.record(answer("Q1", "a"), for: requestA, questionCount: 2)
        wizard.otherText = "draft"

        wizard.bind(to: requestA)

        XCTAssertEqual(wizard.currentQuestionIndex, 1)
        XCTAssertEqual(wizard.collectedAnswers.map(\.answer), ["a"])
        XCTAssertEqual(wizard.otherText, "draft")
    }

    /// A refused submission leaves the card up. Answering again must send one
    /// answer per question, not the refused answer plus the new one.
    func testResubmittingTheLastAnswerDoesNotAccumulate() {
        var wizard = QuestionWizardState(requestId: requestA)
        _ = wizard.record(answer("Q1", "a"), for: requestA, questionCount: 1)

        let retry = wizard.record(answer("Q1", "b"), for: requestA, questionCount: 1)

        XCTAssertEqual(retry?.map(\.answer), ["b"])
    }

    func testGoBackDropsTheLastAnswerAndInput() {
        var wizard = QuestionWizardState(requestId: requestA)
        _ = wizard.record(answer("Q1", "a"), for: requestA, questionCount: 2)
        wizard.selectedIndex = 0

        wizard.goBack()

        XCTAssertEqual(wizard.currentQuestionIndex, 0)
        XCTAssertTrue(wizard.collectedAnswers.isEmpty)
        XCTAssertNil(wizard.selectedIndex)
    }

    private func answer(_ question: String, _ text: String) -> AskUserQuestionAnswer {
        AskUserQuestionAnswer(question: question, answer: text, selectedOptions: [text], customInput: nil)
    }

    // MARK: - Drafts outlive the card's view

    /// The island rebuilds its view when it moves to another display or the
    /// displays change. What the user typed and picked on a question card
    /// comes back with the rebuilt card, for as long as the request waits.
    @MainActor
    func testADraftOutlivesTheCardsViewButNotItsRequest() throws {
        let appState = AppState()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": "s-draft",
        ])))
        let request = QuestionRequest(
            event: event,
            question: QuestionPayload(question: "Which name?", options: ["a", "b"], header: nil),
            resolution: .codexAppServer { _ in }
        )
        appState.questionQueue.append(request)

        var typed = QuestionWizardState(requestId: request.id)
        typed.showOtherInput = true
        typed.otherText = "half an ans"
        appState.saveQuestionDraft(typed)
        XCTAssertEqual(appState.questionDraft(for: request.id), typed)

        // No draft for a request that isn't waiting, nor for one without an id.
        appState.saveQuestionDraft(QuestionWizardState(requestId: UUID()))
        appState.saveQuestionDraft(QuestionWizardState())
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.questionQueue.removeAll()
        XCTAssertNil(appState.questionDraft(for: request.id), "answered, skipped or drained: the draft goes too")
    }
}

