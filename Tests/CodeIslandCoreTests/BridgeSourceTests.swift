import XCTest
@testable import CodeIslandCore

/// `codeisland-bridge` stamps every event with a source and marks hooks that
/// reached it through another agent `_via_plugin` (#123). Direct plugins
/// (OpenCode, MiMo Code, Pi / OMP, OpenClaw) pipe their own blocking requests
/// in without `--source` but with `_source` set: that is declared, not
/// proxied — Agent Sub-Sessions' "hide" mode answers `_via_plugin` permission
/// requests with an automatic allow.
final class BridgeSourceTests: XCTestCase {
    private let underMimo: [(pid: Int32, executablePath: String?)] = [
        (800, "/Users/u/.mimocode/bin/mimo"),
        (700, "/bin/zsh"),
    ]
    private let underOpenCode: [(pid: Int32, executablePath: String?)] = [
        (800, "/Users/u/.opencode/bin/opencode"),
    ]

    func testPluginsOwnRequestIsDeclaredNotProxied() {
        for (payload, ancestry) in [("mimo", underMimo), ("opencode", underOpenCode), ("pi", underMimo)] {
            let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: payload, ancestry: ancestry)
            XCTAssertEqual(resolved.source, payload)
            XCTAssertFalse(resolved.viaPlugin, payload)
        }
    }

    func testAncestryDoesNotRelabelADeclaredPayloadSource() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "opencode", ancestry: underMimo)
        XCTAssertEqual(resolved.source, "opencode")
    }

    func testPayloadAliasesNormalise() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "MiMo Code", ancestry: [])
        XCTAssertEqual(resolved.source, "mimo")
        XCTAssertFalse(resolved.viaPlugin)
    }

    /// #95 / #123 unchanged: a Claude-format hook with no source anywhere is
    /// attributed by ancestry and marked as proxied.
    func testSourcelessHookIsInferredAndMarked() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: underOpenCode)
        XCTAssertEqual(resolved.source, "opencode")
        XCTAssertTrue(resolved.viaPlugin)
    }

    /// An unknown payload source is no declaration: fall back to ancestry.
    func testUnknownPayloadSourceFallsBackToAncestry() {
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: "nonsense", ancestry: underMimo)
        XCTAssertEqual(resolved.source, "mimo")
        XCTAssertTrue(resolved.viaPlugin)
    }

    func testSourceFlagStillWinsAndStillPromotesCLIVariants() {
        let cursorAgent: [(pid: Int32, executablePath: String?)] = [
            (900, "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent"),
        ]
        let resolved = CLIProcessResolver.bridgeSource(sourceTag: "cursor", payloadSource: "opencode", ancestry: cursorAgent)
        XCTAssertEqual(resolved.source, "cursor-cli")
        XCTAssertFalse(resolved.viaPlugin)

        let nothing = CLIProcessResolver.bridgeSource(sourceTag: nil, payloadSource: nil, ancestry: [(1, "/bin/zsh")])
        XCTAssertNil(nothing.source)
        XCTAssertFalse(nothing.viaPlugin)
    }
}
