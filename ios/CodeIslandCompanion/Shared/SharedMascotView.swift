import SwiftUI

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

enum MascotAgentStatus {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion

    init(_ rawValue: String) {
        switch rawValue {
        case "processing":
            self = .processing
        case "running":
            self = .running
        case "waitingApproval":
            self = .waitingApproval
        case "waitingQuestion":
            self = .waitingQuestion
        default:
            self = .idle
        }
    }
}

struct SharedMascotView: View {
    let source: String
    let status: MascotAgentStatus
    var size: CGFloat = 27

    var body: some View {
        Group {
            switch source.lowercased() {
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
            case "codebuddy", "codybuddycn":
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
        .environment(\.mascotSpeed, 1.0)
    }
}
