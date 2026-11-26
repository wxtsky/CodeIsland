import Foundation
import Testing
@testable import CodeIsland

struct GeminiDesktopTests {
    typealias Chat = GeminiDesktop.Chat

    @Test func discoversAnActiveTurnAtLaunchAndCompletesItOnce() {
        var tracker = GeminiDesktop.Tracker()
        let running = Chat(generating: true, window: 1, turn: "question")
        let finished = Chat(window: 1, turn: "question", reply: "the actual answer")
        let start = tracker.update(["Chat": running])
        #expect(start.map(\.event) == ["UserPromptSubmit"])
        #expect(tracker.update(["Chat": running]).isEmpty)
        let stop = tracker.update(["Chat": finished])
        #expect(stop.map(\.event) == ["Stop"])
        #expect(stop.first?.sessionID == start.first?.sessionID)
        #expect(stop.first?.payload["last_assistant_message"] == "the actual answer")
        #expect(tracker.update(["Chat": finished]).isEmpty)
    }

    @Test func generatedTitleKeepsTheOriginalCard() {
        var tracker = GeminiDesktop.Tracker()
        let start = tracker.update(["Temporary": Chat(generating: true, window: 4, turn: "prompt")])
        let stop = tracker.update(["Generated title": Chat(window: 4, turn: "prompt", reply: "answer")])
        #expect(stop.map(\.event) == ["Stop"])
        #expect(stop.first?.sessionID == start.first?.sessionID)
        #expect(stop.first?.title == "Generated title")
    }

    @Test func backgroundCompletionNeverBorrowsTheOpenChatsReply() {
        var tracker = GeminiDesktop.Tracker()
        _ = tracker.update(["A": Chat(badge: .working), "B": Chat(generating: true, window: 2, turn: "B1")])
        let changes = tracker.update(["A": Chat(badge: .ready),
                                      "B": Chat(window: 2, turn: "B1", reply: "only for B")])
        #expect(changes.count == 2)
        #expect(changes.first { $0.title == "A" }?.reply == nil)
        #expect(changes.first { $0.title == "B" }?.reply == "only for B")
    }

    @Test func historicalRepliesAndDisappearingOrBlockedChatsNeverChime() {
        var tracker = GeminiDesktop.Tracker()
        let now = Date()
        #expect(tracker.update(["Past": Chat(badge: .ready, window: 2, turn: "old", reply: "old answer")]).isEmpty)
        _ = tracker.update(["A": Chat(badge: .working)], now: now)
        #expect(tracker.update([:], now: now.addingTimeInterval(1)).isEmpty)
        #expect(tracker.update([:], now: now.addingTimeInterval(65)).map(\.event) == ["SessionEnd"])
        _ = tracker.update(["B": Chat(generating: true, turn: "new")])
        #expect(tracker.update(["B": Chat(badge: .attention)]).map(\.event) == ["SessionEnd"])
        #expect(tracker.reset().isEmpty)
    }

    @Test func rapidTurnInSameChatHasItsOwnAnswer() {
        var tracker = GeminiDesktop.Tracker()
        _ = tracker.update(["A": Chat(window: 1, turn: "first", turnNumber: 1, reply: "previous reply")])
        let changes = tracker.update(["A": Chat(window: 1, turn: "second", turnNumber: 2, reply: "new reply")])
        #expect(changes.map(\.reply) == ["new reply"])
    }

    @Test func revisitingAnOlderTurnDoesNotReportACompletion() {
        var tracker = GeminiDesktop.Tracker()
        _ = tracker.update(["A": Chat(window: 1, turn: "second", turnNumber: 2, reply: "two")])
        #expect(tracker.update(["A": Chat(window: 1, turn: "first", turnNumber: 1, reply: "one")]).isEmpty)
    }

    @Test func repeatedWorkingAndReadyForTheSameTurnProduceOneStop() {
        var tracker = GeminiDesktop.Tracker()
        let working = Chat(badge: .working, generating: true, window: 1, turn: "prompt", turnNumber: 1)
        let ready = Chat(badge: .ready, window: 1, turn: "prompt", turnNumber: 1, reply: "answer")
        let phases = [working, ready, working, ready, working, ready, working, ready]
        let events = phases.flatMap { tracker.update(["A": $0]) }
        #expect(events.map(\.event) == ["UserPromptSubmit", "Stop"])
        let next = Chat(generating: true, window: 1, turn: "prompt", turnNumber: 2)
        #expect(tracker.update(["A": next]).map(\.event) == ["UserPromptSubmit"])
    }

    @Test func successiveTurnsAndAFastCompletionReuseTheConversationCard() {
        var tracker = GeminiDesktop.Tracker()
        let now = Date()
        var events: [GeminiDesktop.Change] = []
        for number in 1...2 {
            // More time than the duplicate-completion suppression interval.
            let at = now.addingTimeInterval(Double(number) * 1000)
            let prompt = "question \(number)"
            events += tracker.update(["A": Chat(generating: true, window: 1, turn: prompt, turnNumber: number)], now: at)
            events += tracker.update(["A": Chat(window: 1, turn: prompt, turnNumber: number, reply: "answer")], now: at)
        }
        events += tracker.update(["A": Chat(window: 1, turn: "quick", turnNumber: 3, reply: "quick reply")], now: now.addingTimeInterval(3000))
        #expect(events.map(\.event) == ["UserPromptSubmit", "Stop", "UserPromptSubmit", "Stop", "Stop"])
        #expect(Set(events.map(\.sessionID)).count == 1)
        #expect(events.last?.reply == "quick reply")
    }

    @Test func renamedChatKeepsItsCardButANewChatCanReuseTheTemporaryTitle() {
        var tracker = GeminiDesktop.Tracker()
        let start = tracker.update(["Temporary": Chat(generating: true, window: 3, turn: "one")])
        _ = tracker.update(["Generated": Chat(window: 3, turn: "one", reply: "done")])
        let next = tracker.update(["Generated": Chat(generating: true, window: 3, turn: "two")])
        let other = tracker.update(["Generated": Chat(badge: .working),
                                    "Temporary": Chat(generating: true, window: 3, turn: "two")])
        #expect(start.first?.sessionID == next.first?.sessionID)
        #expect(other.count == 1)
        #expect(other.first?.sessionID != start.first?.sessionID)
    }

    @Test func duplicateTitlesDoNotInheritAnAmbiguousCard() {
        var tracker = GeminiDesktop.Tracker()
        let first = tracker.update(["Shared": Chat(generating: true, window: 1, turn: "first")])
        let ambiguous = Chat(badge: .working, ambiguous: true)
        #expect(tracker.update(["Shared": ambiguous]).map(\.event) == ["SessionEnd"])
        #expect(tracker.update(["Shared": ambiguous]).isEmpty)
        let second = tracker.update(["Shared": Chat(generating: true, window: 2, turn: "another")])
        #expect(second.count == 1)
        #expect(second.first?.sessionID != first.first?.sessionID)
    }

    @Test func restoredBackgroundConversationKeepsItsCardAcrossMonitorResets() {
        let restored = GeminiDesktop.conversationSessionPrefix + UUID().uuidString
        var tracker = GeminiDesktop.Tracker(sessionIDsByTitle: ["A": restored])
        let first = tracker.update(["A": Chat(badge: .working), "B": Chat(badge: .working)])
        #expect(first.first { $0.title == "A" }?.sessionID == restored)
        #expect(Set(first.map(\.sessionID)).count == 2)
        _ = tracker.update(["A": Chat(badge: .ready), "B": Chat(badge: .ready)])
        _ = tracker.reset()
        #expect(tracker.update(["A": Chat(badge: .working)]).first?.sessionID == restored)
    }

    @Test func localizedBadgesPreservePunctuationInTheTitle() {
        let chinese = GeminiDesktop.BadgeLabels(format: "“%1$@”，%2$@", labels: [("进行中", .working)])
        #expect(chinese.parse("“A，B”，进行中")?.0 == "A，B")
        #expect(chinese.parse("进行中") == nil)
        let reversed = GeminiDesktop.BadgeLabels(format: "%2$@: %1$@", labels: [("Ready", .ready)])
        #expect(reversed.parse("Ready: A: B")?.0 == "A: B")
    }
}
