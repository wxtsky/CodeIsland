import XCTest
@testable import CodeIslandCore

final class GrokHookForwardingPolicyTests: XCTestCase {
    func testGrokRuntimeAcceptsEitherSignalAndRejectsBlankValues() {
        XCTAssertTrue(GrokHookForwardingPolicy.isGrokRuntime(environment: [
            "GROK_SESSION_ID": "session-123",
        ]))
        XCTAssertFalse(GrokHookForwardingPolicy.shouldForward(
            source: "cursor",
            environment: ["GROK_SESSION_ID": "session-123"]
        ))
        XCTAssertTrue(GrokHookForwardingPolicy.isGrokRuntime(environment: [
            "GROK_HOOK_EVENT": "SessionStart",
        ]))
        XCTAssertFalse(GrokHookForwardingPolicy.shouldForward(
            source: nil,
            environment: ["GROK_HOOK_EVENT": "SessionStart"]
        ))
        XCTAssertTrue(GrokHookForwardingPolicy.isGrokRuntime(environment: [
            "GROK_SESSION_ID": " \n\t ",
            "GROK_HOOK_EVENT": "Stop",
        ]))

        XCTAssertFalse(GrokHookForwardingPolicy.isGrokRuntime(environment: [:]))
        XCTAssertFalse(GrokHookForwardingPolicy.isGrokRuntime(environment: [
            "GROK_SESSION_ID": " \n\t ",
            "GROK_HOOK_EVENT": "  ",
        ]))
    }

    func testImportedHooksDeliverEachManagedGrokEventExactlyOnce() {
        let invocations: [(label: String, source: String?)] = [
            ("managed-grok", "grok"),
            ("imported-claude-untagged", nil),
            ("imported-claude-tagged", "claude"),
            ("imported-cursor", "cursor"),
        ]

        for event in GrokHookForwardingPolicy.managedHookEvents {
            let environment = [
                "GROK_SESSION_ID": "session-123",
                "GROK_HOOK_EVENT": event,
            ]
            let forwarded = invocations.filter {
                GrokHookForwardingPolicy.shouldForward(
                    source: $0.source,
                    environment: environment
                )
            }

            XCTAssertEqual(
                forwarded.map { $0.label },
                ["managed-grok"],
                "\(event) must be forwarded exactly once"
            )
        }
    }

    func testNonGrokRuntimeDoesNotSuppressExistingSources() {
        let sources: [String?] = [nil, "claude", "cursor"]
        let environments = [
            [String: String](),
            [
                "GROK_SESSION_ID": " \n\t ",
                "GROK_HOOK_EVENT": "  ",
            ],
        ]

        for environment in environments {
            for source in sources {
                XCTAssertTrue(
                    GrokHookForwardingPolicy.shouldForward(
                        source: source,
                        environment: environment
                    ),
                    "Non-Grok source \(source ?? "nil") must not be suppressed"
                )
            }
        }
    }
}
