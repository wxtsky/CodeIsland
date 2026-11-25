import XCTest
@testable import CodeIslandCore

final class SessionHeadlineTests: XCTestCase {
    private func snapshot(cwd: String?, title: String?, source: String = "claude") -> SessionSnapshot {
        var s = SessionSnapshot()
        s.cwd = cwd
        s.sessionTitle = title
        s.source = source
        return s
    }

    func testProjectNameLeadsAndTitleTrailsByDefault() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "Fix hover delay")
            .headline(showProjectName: true)
        XCTAssertEqual(headline, SessionHeadline(text: "island", kind: .project, trailingSessionLabel: "Fix hover delay"))
    }

    func testHiddenProjectNamePromotesTheSessionTitle() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "  Fix hover delay ")
            .headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .sessionTitle)
        XCTAssertEqual(headline.text, "Fix hover delay")
        XCTAssertNil(headline.trailingSessionLabel, "the title is not repeated after itself")
    }

    /// Without a title the card must not fall back to the folder it was told
    /// to hide — the agent name is the neutral stand-in.
    func testHiddenProjectNameWithoutTitleFallsBackToTheAgentNotTheFolder() {
        let headline = snapshot(cwd: "/Users/me/code/secret-client", title: nil, source: "codex")
            .headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .agent)
        XCTAssertEqual(headline.text, "Codex")
        XCTAssertFalse(headline.text.contains("secret-client"))
    }

    func testBlankTitleCountsAsNoTitle() {
        let headline = snapshot(cwd: "/tmp/x", title: "   ", source: "claude").headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .agent)
        XCTAssertEqual(headline.text, "Claude")
    }

    func testGeminiDesktopLeadsWithTheConversationInCardsAndCollapsedContext() {
        var session = snapshot(cwd: nil, title: "  对话 A  ", source: "gemini")
        session.termBundleId = "com.google.GeminiMacOS"
        for showProject in [true, false] {
            XCTAssertEqual(session.headline(showProjectName: showProject),
                           SessionHeadline(text: "对话 A", kind: .sessionTitle, trailingSessionLabel: nil))
            XCTAssertEqual(SessionHeadline.contextLabel(projectName: nil, session: session, showProjectName: showProject), "对话 A")
        }
        session.sessionTitle = " "
        XCTAssertEqual(session.headline(showProjectName: true).text, session.sourceLabel)
        XCTAssertEqual(SessionHeadline.contextLabel(projectName: nil, session: session, showProjectName: true), session.sourceLabel)

        session.termBundleId = nil // Gemini CLI still uses its working directory.
        session.cwd = "/tmp/project"
        session.sessionTitle = "CLI task"
        XCTAssertEqual(session.headline(showProjectName: true).text, "project")
        XCTAssertEqual(SessionHeadline.contextLabel(projectName: "project", session: session, showProjectName: true), "project")
    }

    func testContextLabelFollowsTheSetting() {
        XCTAssertEqual(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: "Refactor", showProjectName: true),
            "island"
        )
        XCTAssertEqual(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: "Refactor", showProjectName: false),
            "Refactor"
        )
        XCTAssertNil(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: nil, showProjectName: false),
            "no title: show nothing rather than the folder"
        )
    }
}
