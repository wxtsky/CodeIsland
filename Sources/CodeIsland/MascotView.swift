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

// MARK: - Panel Occlusion Environment

private struct PanelOccludedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var panelOccluded: Bool {
        get { self[PanelOccludedKey.self] }
        set { self[PanelOccludedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27
    var respectOcclusion: Bool = true
    @AppStorage(SettingsKey.mascotSpeed) private var speedPct = SettingsDefaults.mascotSpeed
    @Environment(\.panelOccluded) private var panelOccluded

    var body: some View {
        Group {
            if respectOcclusion && panelOccluded {
                Color.clear
            } else {
                mascotBody
            }
        }
        .frame(width: size, height: size)
        .environment(\.mascotSpeed, Double(speedPct) / 100.0)
    }

    @ViewBuilder
    private var mascotBody: some View {
        switch source {
        case "codex":
            DexView(status: status, size: size)
        case "gemini":
            GeminiView(status: status, size: size)
        case "cursor":
            CursorView(status: status, size: size)
        case "trae", "traecn", "traecli":
            TraeView(status: status, size: size)
        case "copilot":
            CopilotView(status: status, size: size)
        case "qoder":
            QoderView(status: status, size: size)
        case "droid":
            DroidView(status: status, size: size)
        case "codebuddy":
            BuddyView(status: status, size: size)
        case "codybuddycn":
            BuddyView(status: status, size: size)
        case "stepfun":
            StepFunView(status: status, size: size)
        case "opencode":
            OpenCodeView(status: status, size: size)
        case "qwen":
            QwenView(status: status, size: size)
        case "antigravity":
            AntiGravityView(status: status, size: size)
        case "workbuddy":
            WorkBuddyView(status: status, size: size)
        case "hermes":
            HermesView(status: status, size: size)
        case "kimi":
            KimiView(status: status, size: size)
        case "cline":
            ClineView(status: status, size: size)
        default:
            ClawdView(status: status, size: size)
        }
    }
}
