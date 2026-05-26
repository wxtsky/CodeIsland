import Foundation
import UserNotifications
import WatchKit
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchConnection: NSObject, ObservableObject {
    @Published private(set) var latestState: CompanionStatePayload?
    @Published private(set) var lastError: String?
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    private var lastHapticSequence: UInt64?
    private var lastNotificationSequence: UInt64?

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

        requestNotificationAuthorization()
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
            WatchStateStore.save(nextState)
            WidgetCenter.shared.reloadAllTimelines()
            playHapticIfNeeded(previous: previousState, next: nextState)
            scheduleNotificationIfNeeded(previous: previousState, next: nextState)
        } catch {
            lastError = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    private func scheduleNotificationIfNeeded(previous: CompanionStatePayload?, next: CompanionStatePayload) {
        guard previous != nil else { return }
        guard lastNotificationSequence != next.sequence else { return }
        guard next.pendingAction == .approval || next.pendingAction == .question else { return }

        lastNotificationSequence = next.sequence

        let content = UNMutableNotificationContent()
        content.title = "\(CompanionDisplayText.source(next.source)) 需要处理"
        content.body = next.question?.question
            ?? CompanionDisplayText.message(next.messages.last?.text)
            ?? next.status.label
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "code-island-\(next.sequence)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
