import Foundation
import os
import CodeIslandCore

/// Drives the Buddy bridge: pushes the *currently displayed* mascot/status
/// both on every AppState mutation (via `notifyDirty()`) and on a fixed
/// heartbeat so the firmware (60s inactivity timeout) never drops out of
/// AGENT mode and reconnects/power-cycles resync immediately.
///
/// Display selection mirrors `NotchPanelView.CompactLeftWing`:
///     rotatingSessionId ?? activeSessionId ?? first sorted session.
/// Falls back to `appState.primarySource` + `.idle` when no sessions exist.
@MainActor
final class ESP32StatePublisher {
    static let shared = ESP32StatePublisher()

    private static let log = Logger(subsystem: "com.codeisland", category: "esp32-publisher")

    private weak var appState: AppState?
    private let bridge: ESP32BridgeManager
    private var heartbeatTimer: Timer?
    private var heartbeatInterval: TimeInterval = 5.0
    private var brightnessPercent: Double = Double(ESP32Protocol.defaultBrightnessPercent)
    private var screenOrientation: BuddyScreenOrientation = .up
    private var keepAliveActivity: NSObjectProtocol?
    private var interactiveRetryTask: Task<Void, Never>?

    private init() {
        self.bridge = ESP32BridgeManager.shared
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func attach(_ appState: AppState) {
        self.appState = appState
        bridge.onConnected = { [weak self] in
            self?.syncConfig()
            self?.flush(reason: "connected")
        }
    }

    /// Invoke when a knob that changes what the island displays may have
    /// changed (new Settings value, toggled enabled flag, etc).
    func configure(
        enabled: Bool,
        heartbeatSeconds: Double,
        brightnessPercent: Double,
        screenOrientation: BuddyScreenOrientation
    ) {
        self.heartbeatInterval = max(1.0, heartbeatSeconds)
        self.brightnessPercent = Double(ESP32Protocol.clampedBrightnessPercent(brightnessPercent))
        self.screenOrientation = screenOrientation
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        interactiveRetryTask?.cancel()
        interactiveRetryTask = nil
        if enabled {
            beginKeepAliveActivityIfNeeded()
            if bridge.status == .off {
                bridge.start()
            }
            syncConfig()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.flush(reason: "heartbeat")
                }
            }
        } else {
            endKeepAliveActivity()
            bridge.stop()
        }
    }

    /// Called from `AppState.refreshDerivedState()` after session mutations.
    func notifyDirty() {
        flush(reason: "change")
        scheduleInteractiveRetriesIfNeeded()
    }

    private func flush(reason: String) {
        guard let appState else { return }
        guard bridge.status == .connected else { return }
        let session = appState.esp32DisplaySession()
        let frame = appState.esp32DisplayFrame(session: session)
        bridge.send(frame)
        bridge.sendWorkspace(appState.esp32WorkspacePayload(session: session))
        appState.esp32MessagePreviewPayloads(session: session).forEach { bridge.sendMessagePreview($0) }
        Self.log.debug("push(\(reason)): mascot=\(frame.mascot.sourceName) status=\(frame.status.rawValue) tool=\(frame.toolName ?? "")")
    }

    private func syncConfig() {
        bridge.sendBrightness(percent: brightnessPercent)
        bridge.sendScreenOrientation(screenOrientation)
    }

    private func beginKeepAliveActivityIfNeeded() {
        guard keepAliveActivity == nil else { return }
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Buddy Bluetooth bridge responsive while app is backgrounded"
        )
    }

    private func endKeepAliveActivity() {
        guard let keepAliveActivity else { return }
        ProcessInfo.processInfo.endActivity(keepAliveActivity)
        self.keepAliveActivity = nil
    }

    private func scheduleInteractiveRetriesIfNeeded() {
        interactiveRetryTask?.cancel()
        guard let appState, let deliveryKey = appState.esp32InteractiveDeliveryKey() else { return }
        interactiveRetryTask = Task { [weak self] in
            let delays: [UInt64] = [600_000_000, 1_800_000_000]
            for delayNs in delays {
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.appState?.esp32InteractiveDeliveryKey() == deliveryKey else { return }
                    self.flush(reason: "interactive-retry")
                }
            }
        }
    }
}

// MARK: - AppState bridge

extension AppState {
    private struct BuddyDisplayContext {
        let source: String
        let status: AgentStatus
        let tool: String?
        let workspace: String?
        let messages: [ChatMessage]
    }

    func esp32DisplaySession() -> SessionSnapshot? {
        let sid = rotatingSessionId ?? activeSessionId ?? sessions.keys.sorted().first
        return sid.flatMap { sessions[$0] }
    }

    private func esp32DisplayContext(session: SessionSnapshot? = nil) -> BuddyDisplayContext {
        if let pending = pendingPermission {
            let sessionId = pending.event.sessionId ?? activeSessionId ?? "default"
            let pendingSession = sessions[sessionId]
            var messages = pendingSession?.recentMessages ?? []
            let detailText = (pending.event.toolDescription ?? pendingSession?.toolDescription)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detailText, !detailText.isEmpty, messages.last?.text != detailText {
                messages.append(ChatMessage(isUser: false, text: detailText))
            }
            return BuddyDisplayContext(
                source: pendingSession?.source ?? primarySource,
                status: .waitingApproval,
                tool: pending.event.toolName ?? pendingSession?.currentTool,
                workspace: pendingSession?.projectDisplayName,
                messages: Array(messages.suffix(3)),
            )
        }

        if let pending = pendingQuestion {
            let sessionId = pending.event.sessionId ?? activeSessionId ?? "default"
            let pendingSession = sessions[sessionId]
            var messages = pendingSession?.recentMessages ?? []
            let questionText = pending.question.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !questionText.isEmpty && messages.last?.text != questionText {
                messages.append(ChatMessage(isUser: true, text: questionText))
            }
            return BuddyDisplayContext(
                source: pendingSession?.source ?? primarySource,
                status: .waitingQuestion,
                tool: pending.event.toolName ?? "AskUserQuestion",
                workspace: pendingSession?.projectDisplayName,
                messages: Array(messages.suffix(3)),
            )
        }

        return BuddyDisplayContext(
            source: session?.source ?? primarySource,
            status: session?.status ?? .idle,
            tool: (session?.status == .running || session?.status == .processing || session?.status == .waitingApproval || session?.status == .waitingQuestion)
                ? session?.currentTool
                : nil,
            workspace: session?.projectDisplayName,
            messages: Array((session?.recentMessages ?? []).suffix(3)),
        )
    }

    /// The `MascotFramePayload` that matches what the notch currently shows.
    /// Keep in sync with `NotchPanelView.CompactLeftWing.displaySession`.
    func esp32DisplayFrame(session: SessionSnapshot? = nil) -> MascotFramePayload {
        let context = esp32DisplayContext(session: session)
        let mascot = MascotID(sourceName: context.source) ?? .claude
        return MascotFramePayload(mascot: mascot, status: MascotStatusCode(context.status), toolName: context.tool)
    }

    func esp32WorkspacePayload(session: SessionSnapshot? = nil) -> BuddyWorkspacePayload {
        BuddyWorkspacePayload(workspaceName: esp32DisplayContext(session: session).workspace)
    }

    func esp32MessagePreviewPayloads(session: SessionSnapshot? = nil) -> [BuddyMessagePreviewPayload] {
        let previews = esp32DisplayContext(session: session).messages
        let flattened = previews.flatMap { message in
            esp32MessagePreviewSegments(text: message.text).map { ChatMessage(isUser: message.isUser, text: $0) }
        }
        guard !flattened.isEmpty else {
            return [BuddyMessagePreviewPayload(index: 0, total: 0, isUser: false, text: nil)]
        }
        let total = flattened.count
        return flattened.enumerated().map { index, message in
            BuddyMessagePreviewPayload(index: index, total: total, isUser: message.isUser, text: message.text)
        }
    }

    func esp32InteractiveDeliveryKey(session: SessionSnapshot? = nil) -> String? {
        let context = esp32DisplayContext(session: session)
        guard context.status == .waitingApproval || context.status == .waitingQuestion else { return nil }
        let messageKey = context.messages
            .flatMap { esp32MessagePreviewSegments(text: $0.text) }
            .joined(separator: "\n")
        return [
            context.source,
            String(MascotStatusCode(context.status).rawValue),
            context.tool ?? "",
            context.workspace ?? "",
            messageKey,
        ].joined(separator: "|")
    }

    func esp32MessagePreviewSegments(text: String?) -> [String] {
        guard let text else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var segments: [String] = []
        var current = ""
        var currentCount = 0

        for character in trimmed {
            let scalar = String(character)
            let byteCount = scalar.lengthOfBytes(using: .utf8)
            if currentCount > 0 && currentCount + byteCount > ESP32Protocol.maxMessagePreviewBytes {
                segments.append(current)
                current = scalar
                currentCount = byteCount
            } else if byteCount > ESP32Protocol.maxMessagePreviewBytes {
                if !current.isEmpty {
                    segments.append(current)
                    current = ""
                    currentCount = 0
                }
                segments.append(String(bytes: scalar.utf8.prefix(ESP32Protocol.maxMessagePreviewBytes), encoding: .utf8) ?? scalar)
            } else {
                current.append(character)
                currentCount += byteCount
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }

        return segments
    }
}
