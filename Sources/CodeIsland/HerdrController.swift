import Foundation
import CodeIslandCore

struct HerdrRoutingIdentity: Equatable {
    let paneId: String
    let socketPath: String
    let binaryPath: String?
}

enum HerdrController {
    typealias Runner = (
        _ path: String,
        _ args: [String],
        _ env: [String: String],
        _ timeout: TimeInterval
    ) -> Data?

    static func identity(from session: SessionSnapshot) -> HerdrRoutingIdentity? {
        let pane = session.herdrPaneId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let socket = session.herdrSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pane.isEmpty, socket.hasPrefix("/") else { return nil }
        let binary = session.herdrBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HerdrRoutingIdentity(
            paneId: pane,
            socketPath: socket,
            binaryPath: binary?.isEmpty == false ? binary : nil
        )
    }

    static func shouldRoute(_ session: SessionSnapshot) -> Bool {
        !session.isRemote
            && session.tmuxPane?.isEmpty != false
            && session.zellijPaneId?.isEmpty != false
            && identity(from: session) != nil
    }

    static func focus(
        _ identity: HerdrRoutingIdentity,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(for: identity) else { return false }
        return runner(
            executable,
            ["agent", "focus", identity.paneId],
            ["HERDR_SOCKET_PATH": identity.socketPath],
            2
        ) != nil
    }

    static func isFocused(
        _ identity: HerdrRoutingIdentity,
        runner: Runner = productionRunner
    ) -> Bool {
        guard let executable = executable(for: identity),
              let data = runner(
                executable,
                ["agent", "get", identity.paneId],
                ["HERDR_SOCKET_PATH": identity.socketPath],
                1
              ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let agent = result["agent"] as? [String: Any] else {
            return false
        }
        return agent["focused"] as? Bool == true
    }

    private static func executable(for identity: HerdrRoutingIdentity) -> String? {
        let fm = FileManager.default
        if let captured = identity.binaryPath,
           captured.hasPrefix("/"),
           fm.isExecutableFile(atPath: captured) {
            return captured
        }
        return [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSHomeDirectory() + "/.local/bin/herdr",
            "/usr/bin/herdr",
        ].first(where: fm.isExecutableFile(atPath:))
    }

    private static func productionRunner(
        path: String,
        args: [String],
        env: [String: String],
        timeout: TimeInterval
    ) -> Data? {
        ProcessRunner.run(path: path, args: args, env: env, timeout: timeout)
    }
}
