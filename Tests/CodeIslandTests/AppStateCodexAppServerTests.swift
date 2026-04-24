import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateCodexAppServerTests: XCTestCase {

    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToRunningAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdle() {
        var s1 = SessionSnapshot()
        s1.status = .running
        AppState.applyCodexThreadStatus(&s1, status: ["type": .string("notLoaded")])
        XCTAssertEqual(s1.status, .idle)

        var s2 = SessionSnapshot()
        s2.status = .running
        AppState.applyCodexThreadStatus(&s2, status: ["type": .string("systemError")])
        XCTAssertEqual(s2.status, .idle)
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        AppState.applyCodexThreadStatus(&snapshot, status: nil)
        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        // Codex can theoretically emit both flags at once; approval is strictly
        // more actionable, so we should route to .waitingApproval.
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }
}
