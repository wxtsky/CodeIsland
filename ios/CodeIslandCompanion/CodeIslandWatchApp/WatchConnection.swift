import Foundation
import WatchKit
import WatchConnectivity

@MainActor
final class WatchConnection: NSObject, ObservableObject {
    @Published private(set) var latestState: CompanionStatePayload?
    @Published private(set) var lastError: String?
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    private var lastHapticSequence: UInt64?

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

        guard WCSession.isSupported() else {
            lastError = "这台设备不支持与 iPhone 同步"
            return
        }

        WCSession.default.delegate = self
        WCSession.default.activate()

        if let data = WCSession.default.receivedApplicationContext["state"] as? Data {
            decodeState(data)
        }
    }

    func send(_ type: CompanionCommandType, answer: String? = nil) {
        WKInterfaceDevice.current().play(.click)

        guard WCSession.default.isReachable else {
            lastError = "iPhone 暂不可达"
            WKInterfaceDevice.current().play(.failure)
            return
        }

        let command = CompanionCommandPayload(
            type: type,
            sessionId: latestState?.sessionId,
            source: latestState?.source,
            answer: answer
        )

        do {
            let data = try encoder.encode(command)
            WCSession.default.sendMessage(["command": data], replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    WKInterfaceDevice.current().play(.failure)
                }
            }
        } catch {
            lastError = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func decodeState(_ data: Data) {
        do {
            let previousState = latestState
            let nextState = try decoder.decode(CompanionStatePayload.self, from: data)
            latestState = nextState
            lastError = nil
            playHapticIfNeeded(previous: previousState, next: nextState)
        } catch {
            lastError = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func playHapticIfNeeded(previous: CompanionStatePayload?, next: CompanionStatePayload) {
        guard lastHapticSequence != next.sequence else { return }
        lastHapticSequence = next.sequence

        guard let previous else { return }

        if next.pendingAction == .approval || next.pendingAction == .question {
            WKInterfaceDevice.current().play(.notification)
        } else if previous.status != next.status || previous.messages.count != next.messages.count {
            WKInterfaceDevice.current().play(.click)
        }
    }
}

extension WatchConnection: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.activationState = activationState
            self.lastError = error?.localizedDescription
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private nonisolated func receive(_ message: [String: Any]) {
        guard let data = message["state"] as? Data else { return }

        Task { @MainActor in
            decodeState(data)
        }
    }
}
