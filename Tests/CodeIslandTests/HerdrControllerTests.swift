import XCTest
import CodeIslandCore
@testable import CodeIsland

final class HerdrControllerTests: XCTestCase {
    func testIdentityRequiresPaneAndAbsoluteSocket() {
        var session = SessionSnapshot()
        session.herdrPaneId = " w1:p2 "
        session.herdrSocketPath = " /tmp/herdr.sock "
        session.herdrBinaryPath = " /tmp/herdr "

        XCTAssertEqual(
            HerdrController.identity(from: session),
            HerdrRoutingIdentity(
                paneId: "w1:p2",
                socketPath: "/tmp/herdr.sock",
                binaryPath: "/tmp/herdr"
            )
        )

        session.herdrSocketPath = "relative.sock"
        XCTAssertNil(HerdrController.identity(from: session))
    }

    func testFocusUsesCapturedSocketAndTimeout() throws {
        let binary = try temporaryExecutable()
        var invocation: Invocation?
        let identity = HerdrRoutingIdentity(
            paneId: "w2:p1",
            socketPath: "/tmp/named/herdr.sock",
            binaryPath: binary.path
        )

        let focused = HerdrController.focus(identity) { path, args, env, timeout in
            invocation = Invocation(path: path, args: args, env: env, timeout: timeout)
            return Data()
        }

        XCTAssertTrue(focused)
        XCTAssertEqual(invocation?.path, binary.path)
        XCTAssertEqual(invocation?.args, ["agent", "focus", "w2:p1"])
        XCTAssertEqual(invocation?.env["HERDR_SOCKET_PATH"], "/tmp/named/herdr.sock")
        XCTAssertEqual(invocation?.timeout, 2)
    }

    func testIsFocusedParsesAgentResponse() throws {
        let binary = try temporaryExecutable()
        let identity = HerdrRoutingIdentity(
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock",
            binaryPath: binary.path
        )
        var invocation: Invocation?

        let focused = HerdrController.isFocused(identity) { path, args, env, timeout in
            invocation = Invocation(path: path, args: args, env: env, timeout: timeout)
            return Data(#"{"result":{"agent":{"focused":true}}}"#.utf8)
        }

        XCTAssertTrue(focused)
        XCTAssertEqual(invocation?.args, ["agent", "get", "w1:p1"])
        XCTAssertEqual(invocation?.timeout, 1)
    }

    func testIsFocusedRejectsMalformedOrUnfocusedResponse() throws {
        let binary = try temporaryExecutable()
        let identity = HerdrRoutingIdentity(
            paneId: "w1:p1",
            socketPath: "/tmp/herdr.sock",
            binaryPath: binary.path
        )

        XCTAssertFalse(HerdrController.isFocused(identity) { _, _, _, _ in
            Data(#"{"result":{"agent":{"focused":false}}}"#.utf8)
        })
        XCTAssertFalse(HerdrController.isFocused(identity) { _, _, _, _ in Data("nope".utf8) })
        XCTAssertFalse(HerdrController.focus(identity) { _, _, _, _ in nil })
    }

    func testRoutingPreservesRemoteAndNestedMultiplexerPrecedence() {
        var session = SessionSnapshot()
        session.herdrPaneId = "w1:p1"
        session.herdrSocketPath = "/tmp/herdr.sock"
        XCTAssertTrue(HerdrController.shouldRoute(session))

        session.tmuxPane = "%1"
        XCTAssertFalse(HerdrController.shouldRoute(session))
        session.tmuxPane = nil
        session.zellijPaneId = "3"
        XCTAssertFalse(HerdrController.shouldRoute(session))
        session.zellijPaneId = nil
        session.remoteHostId = "remote"
        XCTAssertFalse(HerdrController.shouldRoute(session))
    }

    private struct Invocation {
        let path: String
        let args: [String]
        let env: [String: String]
        let timeout: TimeInterval
    }

    private func temporaryExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
