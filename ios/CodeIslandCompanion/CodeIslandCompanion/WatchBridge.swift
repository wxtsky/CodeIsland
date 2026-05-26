import Foundation
import WatchConnectivity

@MainActor
final class WatchBridge: NSObject {
    var commandHandler: ((CompanionCommandPayload) -> Void)?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    override init() {
        super.init()

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ state: CompanionStatePayload?) {
        guard let state, WCSession.isSupported() else { return }

        do {
            let data = try encoder.encode(state)
            let message: [String: Any] = ["state": data]
            try WCSession.default.updateApplicationContext(message)

            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil)
            }
        } catch {
            // Watch sync is best-effort; the iPhone app should keep running even
            // when the watch is unavailable or the session is still activating.
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private nonisolated func receive(_ message: [String: Any]) {
        guard let data = message["command"] as? Data else { return }

        Task { @MainActor in
            do {
                let command = try decoder.decode(CompanionCommandPayload.self, from: data)
                commandHandler?(command)
            } catch {
                // Ignore malformed watch commands.
            }
        }
    }
}
