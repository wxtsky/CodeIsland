import SwiftUI
import CodeIslandCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

func effectiveMascotStatus(_ status: AgentStatus, silentWorkMode: Bool) -> AgentStatus {
    guard silentWorkMode else { return status }

    switch status {
    case .running, .processing:
        return .idle
    default:
        return status
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27
    @AppStorage(SettingsKey.mascotSpeed) private var speedPct = SettingsDefaults.mascotSpeed
    @AppStorage(SettingsKey.silentWorkMode) private var silentWorkMode = SettingsDefaults.silentWorkMode

    private var displayStatus: AgentStatus {
        effectiveMascotStatus(status, silentWorkMode: silentWorkMode)
    }

    var body: some View {
        Group {
            switch source {
            case "codex":
                DexView(status: displayStatus, size: size)
            case "gemini":
                GeminiView(status: displayStatus, size: size)
            case "cursor":
                CursorView(status: displayStatus, size: size)
            case "copilot":
                CopilotView(status: displayStatus, size: size)
            case "qoder":
                QoderView(status: displayStatus, size: size)
            case "droid":
                DroidView(status: displayStatus, size: size)
            case "codebuddy":
                BuddyView(status: displayStatus, size: size)
            case "opencode":
                OpenCodeView(status: displayStatus, size: size)
            default:
                ClawdView(status: displayStatus, size: size)
            }
        }
        .environment(\.mascotSpeed, Double(speedPct) / 100.0)
    }
}
