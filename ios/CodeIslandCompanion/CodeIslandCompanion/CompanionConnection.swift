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

    private static let serviceType = "codeisland"

    private let watchBridge = WatchBridge()
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private let mockStatePayload = CompanionConnection.mockStateFromLaunchArguments()
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)

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

        if let mockStatePayload {
            connectedPeer = MCPeerID(displayName: "CodeIsland Mock Mac")
            latestState = mockStatePayload
            watchBridge.publish(mockStatePayload)
        }
    }

    func start() {
        guard mockStatePayload == nil else { return }
        guard !browsing else { return }
        lastError = nil
        browsing = true
        browser.startBrowsingForPeers()
    }

    func stop() {
        guard mockStatePayload == nil else { return }
        browsing = false
        browser.stopBrowsingForPeers()
        session.disconnect()
        discoveredPeers = []
        connectedPeer = nil
    }

    func connect(to peer: MCPeerID) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 12)
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

    private static func mockStateFromLaunchArguments() -> CompanionStatePayload? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-CodeIslandCompanionMockState"),
              arguments.indices.contains(flagIndex + 1)
        else {
            return nil
        }

        return mockState(named: arguments[flagIndex + 1])
    }

    private static func mockState(named name: String) -> CompanionStatePayload {
        let baseMessages = [
            CompanionMessagePreview(role: .user, text: "帮我生成一篇长篇小说"),
            CompanionMessagePreview(role: .assistant, text: "好的，我先确认一下类型和篇幅，再开始组织结构。")
        ]

        switch name.lowercased() {
        case "question":
            return CompanionStatePayload(
                version: 1,
                sequence: 1002,
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
                sequence: 1003,
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
                sequence: 1004,
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
                sequence: 1001,
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
            case .notConnected:
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                }
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
                self.latestState = try self.decoder.decode(CompanionStatePayload.self, from: data)
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
