import Combine
import Foundation
import MultipeerConnectivity
import UIKit

@MainActor
final class CompanionConnection: NSObject, ObservableObject {
    @Published private(set) var discoveredPeers: [MCPeerID] = []
    @Published private(set) var connectedPeer: MCPeerID?
    @Published private(set) var latestState: CompanionStatePayload? {
        didSet {
            watchBridge.publish(latestState)
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var browsing = false
    @Published private(set) var bluetoothConnectedPeripheralName: String?
    @Published private(set) var lastStateReceivedAt: Date?
    @Published private(set) var isDemoMode = false

    private static let serviceType = "codeisland"
    private static let refreshAfterSeconds: TimeInterval = 8
    private static let reconnectAfterSeconds: TimeInterval = 24

    private let watchBridge = WatchBridge()
    private let bluetoothBridge = CompanionBluetoothCentral()
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private let mockStatePayload = CompanionConnection.mockStateFromLaunchArguments()
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
    private var stateWatchdogTimer: Timer?
    private var connectedAt: Date?
    private var pendingReconnectPeer: MCPeerID?
    private var demoSequence: UInt64 = 9000
    var onStateReceived: ((CompanionStatePayload) -> Void)?

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
        session.delegate = self
        browser.delegate = self
        watchBridge.commandHandler = { [weak self] command in
            self?.send(command)
        }
        bluetoothBridge.onSummary = { [weak self] summary in
            self?.receiveBluetoothSummary(summary)
        }
        bluetoothBridge.$connectedPeripheralName
            .assign(to: &$bluetoothConnectedPeripheralName)
        bluetoothBridge.$lastError
            .compactMap { $0 }
            .assign(to: &$lastError)

        if let mockStatePayload {
            connectedPeer = MCPeerID(displayName: "CodeIsland Mock Mac")
            receiveState(mockStatePayload)
        }
    }

    deinit {
        stateWatchdogTimer?.invalidate()
    }

    func start() {
        guard !isDemoMode else { return }
        bluetoothBridge.start()
        guard mockStatePayload == nil else { return }
        startStateWatchdog()
        guard !browsing else { return }
        lastError = nil
        browsing = true
        browser.startBrowsingForPeers()
    }

    func stop() {
        if isDemoMode {
            exitDemoMode()
            return
        }
        guard mockStatePayload == nil else { return }
        browsing = false
        stateWatchdogTimer?.invalidate()
        stateWatchdogTimer = nil
        browser.stopBrowsingForPeers()
        session.disconnect()
        discoveredPeers = []
        connectedPeer = nil
        connectedAt = nil
        pendingReconnectPeer = nil
    }

    func connect(to peer: MCPeerID) {
        exitDemoMode()
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 12)
    }

    func enterDemoMode() {
        guard mockStatePayload == nil else { return }
        browser.stopBrowsingForPeers()
        session.disconnect()
        browsing = false
        discoveredPeers = []
        connectedAt = Date()
        connectedPeer = MCPeerID(displayName: "Code Island Demo")
        isDemoMode = true
        receiveState(Self.mockState(named: "question", sequence: nextDemoSequence()))
    }

    func cycleDemoState() {
        guard isDemoMode else { return }
        let states = ["question", "long", "interrupted", "idle"]
        let nextIndex = Int((demoSequence - 9000) % UInt64(states.count))
        receiveState(Self.mockState(named: states[nextIndex], sequence: nextDemoSequence()))
    }

    func exitDemoMode() {
        guard isDemoMode else { return }
        isDemoMode = false
        latestState = nil
        connectedPeer = nil
        connectedAt = nil
        lastStateReceivedAt = nil
        lastError = nil
    }

    func send(_ type: CompanionCommandType) {
        send(type, answer: nil)
    }

    func sendAnswer(_ answer: String) {
        send(.answerQuestion, answer: answer)
    }

    private func send(_ command: CompanionCommandPayload) {
        guard !session.connectedPeers.isEmpty else { return }

        do {
            let data = try encoder.encode(command)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func send(_ type: CompanionCommandType, answer: String?) {
        guard !session.connectedPeers.isEmpty else { return }
        let command = CompanionCommandPayload(
            type: type,
            sessionId: latestState?.sessionId,
            source: latestState?.source,
            answer: answer
        )
        send(command)
    }

    private func requestCurrentState(reason: String) {
        guard !session.connectedPeers.isEmpty else { return }
        let command = CompanionCommandPayload(type: .requestCurrentState)
        send(command)
    }

    private func receiveState(_ state: CompanionStatePayload) {
        lastStateReceivedAt = Date()
        latestState = state
        onStateReceived?(state)
    }

    private func startStateWatchdog() {
        guard stateWatchdogTimer == nil else { return }
        stateWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStateFreshness()
            }
        }
    }

    private func checkStateFreshness() {
        guard mockStatePayload == nil else { return }
        guard !isDemoMode else { return }
        guard let connectedPeer else { return }

        let now = Date()
        let reference = lastStateReceivedAt ?? connectedAt ?? now
        let age = now.timeIntervalSince(reference)

        if age >= Self.reconnectAfterSeconds {
            lastError = "连接在线但长时间没有状态更新，正在重新连接 Mac"
            pendingReconnectPeer = connectedPeer
            session.disconnect()
            self.connectedPeer = nil
            connectedAt = nil
            if !browsing {
                browsing = true
                browser.startBrowsingForPeers()
            }
            if discoveredPeers.contains(connectedPeer) {
                browser.invitePeer(connectedPeer, to: session, withContext: nil, timeout: 12)
            }
            return
        }

        if age >= Self.refreshAfterSeconds {
            requestCurrentState(reason: "stale-\(Int(age))s")
        }
    }

    func injectMockState(named name: String) {
        receiveState(Self.mockState(named: name, sequence: nextDemoSequence()))
    }

    private func nextDemoSequence() -> UInt64 {
        demoSequence += 1
        return demoSequence
    }

    private func receiveBluetoothSummary(_ summary: CompanionBluetoothSummary) {
        guard !isDemoMode else { return }

        if let current = latestState, current.sequence > summary.sequence {
            return
        }

        receiveState(summary.statePayload)
    }

    private static func mockStateFromLaunchArguments() -> CompanionStatePayload? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-CodeIslandCompanionMockState"),
              arguments.indices.contains(flagIndex + 1)
        else {
            return nil
        }

        return mockState(named: arguments[flagIndex + 1])
    }

    private static func mockState(named name: String, sequence: UInt64? = nil) -> CompanionStatePayload {
        let baseMessages = [
            CompanionMessagePreview(role: .user, text: "帮我生成一篇长篇小说"),
            CompanionMessagePreview(role: .assistant, text: "好的，我先确认一下类型和篇幅，再开始组织结构。")
        ]
        let resolvedSequence = sequence ?? 1000

        switch name.lowercased() {
        case "question":
            return CompanionStatePayload(
                version: 1,
                sequence: resolvedSequence,
                sessionId: "mock-question",
                source: "claude",
                status: .waitingQuestion,
                toolName: "AskUserQuestion",
                workspaceName: "workspace",
                messages: baseMessages,
                pendingAction: .question,
                question: CompanionQuestionPayload(
                    header: "小说类型",
                    question: "你想看什么类型的小说？",
                    options: ["都市 / 现实", "科幻", "悬疑 / 推理", "奇幻 / 玄幻"],
                    descriptions: [
                        "现代都市、职场情感、现实生活",
                        "未来科技、AI、太空、时间旅行",
                        "犯罪侦查、谜团解谜、心理悬疑",
                        "魔法世界、修真、异世界冒险"
                    ],
                    index: 1,
                    total: 4,
                    allowsMultipleSelection: false
                ),
                updatedAt: Date()
            )
        case "interrupted":
            return CompanionStatePayload(
                version: 1,
                sequence: resolvedSequence,
                sessionId: "mock-interrupted",
                source: "claude",
                status: .idle,
                toolName: nil,
                workspaceName: "workspace",
                messages: [
                    CompanionMessagePreview(role: .user, text: "帮我生成一篇长篇小说"),
                    CompanionMessagePreview(role: .assistant, text: "[Request interrupted by user]")
                ],
                pendingAction: nil,
                question: nil,
                updatedAt: Date()
            )
        case "long":
            return CompanionStatePayload(
                version: 1,
                sequence: resolvedSequence,
                sessionId: "mock-long",
                source: "codex",
                status: .processing,
                toolName: "WebSearch",
                workspaceName: "workspace",
                messages: [
                    CompanionMessagePreview(role: .user, text: "把 iPhone 端所有容易截断的状态都自己跑一遍"),
                    CompanionMessagePreview(role: .assistant, text: "我会用模拟数据覆盖中断、提问、长文本和实时活动展示，重点检查中文化、滚动区域、最近动态字号以及按钮是否挤压。"),
                    CompanionMessagePreview(role: .assistant, text: "这是一条故意很长的最近动态，用来确认 iPhone 竖屏里不会被卡片裁掉，也不会因为内部嵌套滚动导致内容看不全。")
                ],
                pendingAction: nil,
                question: nil,
                updatedAt: Date()
            )
        default:
            return CompanionStatePayload(
                version: 1,
                sequence: resolvedSequence,
                sessionId: "mock-idle",
                source: "codex",
                status: .idle,
                toolName: nil,
                workspaceName: "workspace",
                messages: [],
                pendingAction: nil,
                question: nil,
                updatedAt: Date()
            )
        }
    }
}

extension CompanionConnection: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard !self.discoveredPeers.contains(peerID) else { return }
            self.discoveredPeers.append(peerID)
            if self.pendingReconnectPeer == peerID {
                self.pendingReconnectPeer = nil
                self.connect(to: peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
            if self.connectedPeer == peerID {
                self.connectedPeer = nil
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.browsing = false
            self.lastError = error.localizedDescription
        }
    }
}

extension CompanionConnection: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.connectedPeer = peerID
                self.connectedAt = Date()
                self.requestCurrentState(reason: "peer-connected")
            case .notConnected:
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                }
                self.connectedAt = nil
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            do {
                self.receiveState(try self.decoder.decode(CompanionStatePayload.self, from: data))
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}
