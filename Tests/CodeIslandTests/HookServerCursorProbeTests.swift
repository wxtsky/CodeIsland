import XCTest
@testable import CodeIsland

@MainActor
final class HookServerCursorProbeTests: XCTestCase {
    func testMayNeedCursorRequiresExactSourceAndAgentTranscripts() {
        let path = "/x/agent-transcripts/p/c.jsonl"

        let compactCursor = Data(#"{"_source":"cursor","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: compactCursor))

        let spacedCursor = Data(#"{"_source": "cursor","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: spacedCursor))

        let spaceBeforeColon = Data(#"{"_source" :"cursor","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: spaceBeforeColon))

        let spaceBothSides = Data(#"{"_source" : "cursor","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: spaceBothSides))

        let compactCli = Data(#"{"_source":"cursor-cli","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: compactCli))

        let spacedCli = Data(#"{"_source": "cursor-cli","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: spacedCli))

        // `\u0063` = c — literal regex misses; JSON fallback must still accept.
        let unicodeCursor = Data(
            #"{"_source":"\u0063ursor","transcript_path":"\#(path)"}"#.utf8
        )
        XCTAssertTrue(HookServer.mayNeedCursorSubsessionRouting(data: unicodeCursor))

        let missingSourceKey = Data(#"{"source":"cursor","transcript_path":"\#(path)"}"#.utf8)
        XCTAssertFalse(
            HookServer.mayNeedCursorSubsessionRouting(data: missingSourceKey),
            "Bare source without _source must not force a Cursor JSON parse"
        )

        let cursorInTextOnly = Data(#"{"text":"move cursor here","path":"\#(path)"}"#.utf8)
        XCTAssertFalse(HookServer.mayNeedCursorSubsessionRouting(data: cursorInTextOnly))

        let wrongSource = Data(
            #"{"_source":"claude","text":"cursor","transcript_path":"\#(path)"}"#.utf8
        )
        XCTAssertFalse(
            HookServer.mayNeedCursorSubsessionRouting(data: wrongSource),
            "Unrelated _source plus bare cursor text must not force a parse"
        )

        // Non-cursor + agent-transcripts + unrelated `\u` must not claim Cursor.
        let wrongSourceWithUnicodeElsewhere = Data(
            #"{"_source":"claude","text":"\u0041","transcript_path":"\#(path)"}"#.utf8
        )
        XCTAssertFalse(
            HookServer.mayNeedCursorSubsessionRouting(data: wrongSourceWithUnicodeElsewhere)
        )

        let noTranscripts = Data(#"{"_source":"cursor","session_id":"abc"}"#.utf8)
        XCTAssertFalse(HookServer.mayNeedCursorSubsessionRouting(data: noTranscripts))
    }
}
