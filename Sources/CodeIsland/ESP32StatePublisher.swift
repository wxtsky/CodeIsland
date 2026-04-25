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
        if enabled {
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
            bridge.stop()
        }
    }

    /// Called from `AppState.refreshDerivedState()` after session mutations.
    func notifyDirty() {
        flush(reason: "change")
    }

    private func flush(reason: String) {
        guard let appState else { return }
        guard bridge.status == .connected else { return }
        let frame = appState.esp32DisplayFrame()
        bridge.send(frame)
        Self.log.debug("push(\(reason)): mascot=\(frame.mascot.sourceName) status=\(frame.status.rawValue) tool=\(frame.toolName ?? "")")
    }

    private func syncConfig() {
        bridge.sendBrightness(percent: brightnessPercent)
        bridge.sendScreenOrientation(screenOrientation)
    }
}

// MARK: - AppState bridge

extension AppState {
    /// The `MascotFramePayload` that matches what the notch currently shows.
    /// Keep in sync with `NotchPanelView.CompactLeftWing.displaySession`.
    func esp32DisplayFrame() -> MascotFramePayload {
        let sid = rotatingSessionId ?? activeSessionId ?? sessions.keys.sorted().first
        let session = sid.flatMap { sessions[$0] }
        let source = session?.source ?? primarySource
        let status = session?.status ?? .idle
        let tool = (status == .running || status == .processing) ? session?.currentTool : nil
        let mascot = MascotID(sourceName: source) ?? .claude
        return MascotFramePayload(mascot: mascot, status: MascotStatusCode(status), toolName: tool)
    }
}
