import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Global card shortcuts act only on the card on screen. A request the user
/// cannot see is never approved, denied or skipped: the press opens its card
/// instead, and the next press acts on it.
@MainActor
final class CardShortcutTests: XCTestCase {
    private var appState: AppState!
    private var pending: [Task<Data, Never>] = []
    private var responses: [String: Task<Data, Never>] = [:]
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.completionNotificationStyle,
        SettingsKey.followUpReminderMinutes,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
        pending = []
        responses = [:]
        appState = AppState()
    }

    override func tearDown() async throws {
        let waiters = appState.permissionQueue.map(\.event) + appState.questionQueue.map(\.event)
        for event in waiters {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        // `try?`: a stuck request is already recorded as a failure; the
        // rest of the teardown must still run so the defaults are restored.
        for t in pending { _ = try? await awaitValue(of: t) }
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    // MARK: - Skip

    /// "Auto-expand on question" off: the question waits behind its badge.
    /// The skip shortcut must not skip what nobody has seen.
    func testSkipShortcutDoesNotSkipAHiddenQuestion() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QH")
        XCTAssertEqual(appState.surface, .collapsed)

        XCTAssertEqual(appState.performCardShortcut(.skipQuestion), .opened(.questionCard(sessionId: "QH")))
        XCTAssertEqual(appState.questionQueue.count, 1, "an unseen question should not be skipped")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QH"))

        // Now it is on screen: the next press skips it.
        XCTAssertEqual(appState.performCardShortcut(.skipQuestion), .acted(sessionId: "QH"))
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    /// An approval card is up and a question waits unseen: skip opens the
    /// question, the approval is untouched.
    func testSkipShortcutOverAnApprovalCardOnlyOpensTheQuestion() async throws {
        try await requestApproval("PQ")
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        try await ask("QQ")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PQ"))

        XCTAssertEqual(appState.performCardShortcut(.skipQuestion), .opened(.questionCard(sessionId: "QQ")))
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.count, 1)
    }

    // MARK: - Approve / deny

    /// "Auto-expand on approval" off: approve opens the card first.
    func testApproveShortcutOpensAHiddenApprovalInsteadOfApprovingIt() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("PH")
        XCTAssertEqual(appState.surface, .collapsed)

        XCTAssertEqual(appState.performCardShortcut(.approve), .opened(.approvalCard(sessionId: "PH")))
        XCTAssertEqual(appState.permissionQueue.count, 1, "an unseen approval must not be approved")

        XCTAssertEqual(appState.performCardShortcut(.approve), .acted(sessionId: "PH"))
        XCTAssertEqual(appState.permissionQueue.count, 0)
        let response = try XCTUnwrap(responses["PH"])
        let body = String(decoding: try await awaitValue(of: response), as: UTF8.self)
        XCTAssertTrue(body.contains("\"allow\""), body)
    }

    /// A question card is on screen and an approval waits behind it: approve
    /// (or deny) brings the approval up but does not decide it.
    func testApproveOrDenyOverAQuestionCardOnlyOpensTheApproval() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await ask("QV")
        try await requestApproval("PV")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QV"))

        XCTAssertEqual(appState.performCardShortcut(.deny), .opened(.approvalCard(sessionId: "PV")))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue.count, 1)
    }

    /// The card on screen is not the head: the shortcut acts on the card.
    func testApproveShortcutActsOnTheCardNotTheHead() async throws {
        try await requestApproval("head")
        try await requestApproval("shown")
        appState.surface = .approvalCard(sessionId: "shown")

        XCTAssertEqual(appState.performCardShortcut(.approveAlways), .acted(sessionId: "shown"))
        XCTAssertEqual(appState.permissionQueue.map(\.event.sessionId), ["head"])
    }

    /// A request the user dismissed stays put away; nothing else waits, so
    /// the press does nothing.
    func testApproveShortcutLeavesADismissedApprovalAlone() async throws {
        try await requestApproval("dismissed")
        appState.dismissPermissionPrompt(expectedSessionId: "dismissed")
        XCTAssertEqual(appState.surface, .collapsed)

        XCTAssertEqual(appState.performCardShortcut(.approve), .ignored)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)
    }

    func testCardShortcutsDoNothingWithNothingWaiting() {
        appState.surface = .sessionList
        for action in [ShortcutAction.approve, .approveAlways, .deny, .skipQuestion] {
            XCTAssertEqual(appState.performCardShortcut(action), .ignored)
        }
        XCTAssertEqual(appState.surface, .sessionList)
    }

    // MARK: - Island off screen (#384)

    /// The approval card opened by itself while Hide in Fullscreen kept the
    /// island hidden over a fullscreen app: the press brings it up instead
    /// of approving what nobody saw.
    func testApproveShortcutOnAHiddenIslandOnlyBringsUpItsCard() async throws {
        try await requestApproval("PF")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PF"))

        XCTAssertEqual(
            appState.performCardShortcut(.approve, islandOnScreen: false),
            .opened(.approvalCard(sessionId: "PF"))
        )
        XCTAssertEqual(appState.permissionQueue.count, 1, "a card off screen must not be approved")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PF"))

        // Up now: the next press approves.
        XCTAssertEqual(appState.performCardShortcut(.approve), .acted(sessionId: "PF"))
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testDenyShortcutOnAHiddenIslandKeepsTheCardItShows() async throws {
        try await requestApproval("head")
        try await requestApproval("shown")
        appState.surface = .approvalCard(sessionId: "shown")

        XCTAssertEqual(
            appState.performCardShortcut(.deny, islandOnScreen: false),
            .opened(.approvalCard(sessionId: "shown"))
        )
        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "shown"))
    }

    func testSkipShortcutOnAHiddenIslandOnlyBringsUpItsCard() async throws {
        try await ask("QF")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "QF"))

        XCTAssertEqual(
            appState.performCardShortcut(.skipQuestion, islandOnScreen: false),
            .opened(.questionCard(sessionId: "QF"))
        )
        XCTAssertEqual(appState.questionQueue.count, 1, "a card off screen must not be skipped")

        XCTAssertEqual(appState.performCardShortcut(.skipQuestion), .acted(sessionId: "QF"))
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    /// Hidden and collapsed, with an approval waiting: its card opens, as on
    /// screen.
    func testApproveShortcutOnAHiddenCollapsedIslandOpensTheWaitingCard() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnPermission)
        try await requestApproval("PC")
        XCTAssertEqual(appState.surface, .collapsed)

        XCTAssertEqual(
            appState.performCardShortcut(.approve, islandOnScreen: false),
            .opened(.approvalCard(sessionId: "PC"))
        )
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PC"))
        XCTAssertEqual(appState.permissionQueue.count, 1)
    }

    func testCardShortcutsOnAHiddenIslandDoNothingWithNothingWaiting() {
        for action in [ShortcutAction.approve, .approveAlways, .deny, .skipQuestion] {
            XCTAssertEqual(appState.performCardShortcut(action, islandOnScreen: false), .ignored)
        }
        XCTAssertEqual(appState.surface, .collapsed)
    }

    // MARK: - Toggle Panel (#384)

    func testToggleOpensACollapsedIsland() {
        XCTAssertEqual(appState.togglePanelFromShortcut(islandAway: false), .opened)
        XCTAssertEqual(appState.surface, .sessionList)
    }

    /// Collapsed and away is the same: it opens, and is brought to the user.
    func testToggleOpensACollapsedIslandThatIsAway() {
        XCTAssertEqual(appState.togglePanelFromShortcut(islandAway: true), .opened)
        XCTAssertEqual(appState.surface, .sessionList)
    }

    func testToggleClosesAnIslandInSight() {
        appState.surface = .sessionList
        XCTAssertEqual(appState.togglePanelFromShortcut(islandAway: false), .collapsed)
        XCTAssertEqual(appState.surface, .collapsed)
    }

    /// Open on the other display, or hidden over a fullscreen app: the press
    /// keeps it open, card and all, rather than closing it unseen.
    func testToggleKeepsAnIslandOpenOutOfSight() async throws {
        try await requestApproval("PA")
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PA"))

        XCTAssertEqual(appState.togglePanelFromShortcut(islandAway: true), .keptOpen)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "PA"))
        XCTAssertEqual(appState.permissionQueue.count, 1)
    }

    // MARK: - Helpers

    private func requestApproval(_ sid: String) async throws {
        let e = try event(["hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "Bash", "tool_input": ["command": "echo \(sid)"]])
        let task = await startHookRequest { [appState] in appState!.handlePermissionRequest(e, continuation: $0) }
        pending.append(task)
        responses[sid] = task
    }

    private func ask(_ sid: String) async throws {
        let e = try event([
            "hook_event_name": "PermissionRequest", "session_id": sid, "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]],
        ])
        pending.append(await startHookRequest { [appState] in appState!.handleAskUserQuestion(e, continuation: $0) })
    }

    private func event(_ p: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: p)))
    }
}
