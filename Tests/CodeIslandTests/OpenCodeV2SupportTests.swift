import XCTest
@testable import CodeIsland

/// #332 — OpenCode 2 runs plugins in one shared background server per user
/// (`opencode serve --service`), spawned by the first client and outliving it.
final class OpenCodeV2SupportTests: XCTestCase {
    /// Binding a session to the shared service would get it SIGTERMed by the
    /// orphan sweep once the client that spawned it quits, so the pid scan
    /// must be able to tell it apart from the TUI (same executable).
    func testSharedServiceIsRecognisedFromArgv() {
        XCTAssertTrue(AppState.isOpenCodeSharedService(arguments: ["/Users/u/.opencode/bin/opencode", "serve", "--service"]))
        XCTAssertFalse(AppState.isOpenCodeSharedService(arguments: ["/Users/u/.opencode/bin/opencode"]), "the TUI client")
        XCTAssertFalse(
            AppState.isOpenCodeSharedService(arguments: ["opencode", "serve", "--stdio", "--port", "0"]),
            "a standalone server is its client's child and dies with it"
        )
        XCTAssertFalse(AppState.isOpenCodeSharedService(arguments: ["opencode", "run", "--service"]))
    }

    func testBundledPluginServesBothPluginAPIs() throws {
        let url = try XCTUnwrap(
            Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js", subdirectory: "Resources")
                ?? Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js")
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("// version: v9"), "bump ConfigInstaller.opencodePluginVersion with the plugin")
        XCTAssertTrue(source.contains("setup: setupV2"), "OpenCode 2 loads {id, setup}")
        XCTAssertTrue(source.contains("server: async"), "OpenCode 1.x loads {id, server}")
        XCTAssertTrue(source.contains("_untracked_process: true"), "the shared service must never become a session's pid")
    }
}
