import ActivityKit
import SwiftUI
import WidgetKit

struct CodeIslandLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodeIslandActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Color(red: 0.04, green: 0.05, blue: 0.07))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentBadge(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedStatusDot(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedMessageView(state: context.state)
                }
            } compactLeading: {
                CompactAgentView(state: context.state)
            } compactTrailing: {
                CompactStatusView(state: context.state)
            } minimal: {
                SharedMascotView(source: context.state.source, status: MascotAgentStatus(context.state.status), size: 18)
            }
            .keylineTint(statusColor(context.state.status))
        }
    }
}

private struct LockScreenActivityView: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentBadge(state: state)
                Spacer()
                StatusPill(state: state)
            }

            MetadataRow(state: state)

            if !primaryText(state).isEmpty {
                Text(primaryText(state))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
            } else if let toolName = CompanionDisplayText.tool(state.toolName), !toolName.isEmpty {
                Label(toolName, systemImage: "hammer")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            } else {
                Text("当前没有新的消息")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}

private struct ExpandedMessageView: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(state.compactStatusLabel)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(statusColor(state.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(statusColor(state.status).opacity(0.18), in: Capsule())
                Text(CompanionDisplayText.workspace(state.workspaceName) ?? "CodeIsland")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let toolName = CompanionDisplayText.tool(state.toolName), !toolName.isEmpty {
                    Text(toolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(toolColor(toolName))
                        .lineLimit(1)
                }
                if let progress = state.questionProgress {
                    Text(progress)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
            }
            Text(primaryText(state))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactAgentView: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            SharedMascotView(source: state.source, status: MascotAgentStatus(state.status), size: 20)
            Text(state.sourceLabel)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct ExpandedStatusDot: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        StatusDot(status: state.status, size: 8)
            .padding(8)
            .background(statusColor(state.status).opacity(0.22), in: Circle())
            .accessibilityLabel(state.statusLabel)
    }
}

private struct CompactStatusView: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 3) {
            StatusDot(status: state.status, size: 6)
            Text(state.compactStatusLabel)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
    }
}

private struct AgentBadge: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            SharedMascotView(source: state.source, status: MascotAgentStatus(state.status), size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.sourceLabel)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(CompanionDisplayText.subtitle(
                    workspaceName: state.workspaceName,
                    toolName: state.toolName,
                    fallback: "CodeIsland"
                ))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
    }
}

private struct StatusPill: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: state.status, size: 8)
            Text(state.statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor(state.status).opacity(0.2), in: Capsule())
    }
}

private struct StatusDot: View {
    let status: String
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: size, height: size)
    }
}

private struct MetadataRow: View {
    let state: CodeIslandActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if let workspaceName = CompanionDisplayText.workspace(state.workspaceName), !workspaceName.isEmpty {
                CompactChip(icon: "folder", text: workspaceName)
            }
            if let toolName = CompanionDisplayText.tool(state.toolName), !toolName.isEmpty {
                CompactChip(icon: "hammer", text: toolName, tint: toolColor(toolName))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CompactChip: View {
    let icon: String
    let text: String
    var tint: Color = .white.opacity(0.64)

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private func compactStatusText(_ state: CodeIslandActivityAttributes.ContentState) -> String {
    switch state.status {
    case "waitingApproval": return "批"
    case "waitingQuestion": return "问"
    case "processing": return "跑"
    case "running": return state.toolName?.prefix(1).uppercased() ?? "跑"
    default: return ""
    }
}

private func primaryText(_ state: CodeIslandActivityAttributes.ContentState) -> String {
    if state.status == "waitingQuestion", let questionText = CompanionDisplayText.message(state.questionText), !questionText.isEmpty {
        return questionText
    }
    if let message = CompanionDisplayText.message(state.message), !message.isEmpty {
        return message
    }
    if let toolName = CompanionDisplayText.tool(state.toolName), !toolName.isEmpty {
        return toolName
    }
    return state.statusLabel
}

private func toolColor(_ tool: String) -> Color {
    switch tool.lowercased() {
    case "bash": return Color(red: 0.4, green: 1.0, blue: 0.5)
    case "edit", "write": return Color(red: 0.5, green: 0.7, blue: 1.0)
    case "read": return Color(red: 0.9, green: 0.8, blue: 0.4)
    case "grep", "glob": return Color(red: 0.8, green: 0.6, blue: 1.0)
    case "agent": return Color(red: 1.0, green: 0.6, blue: 0.4)
    default: return .white.opacity(0.7)
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "waitingApproval", "waitingQuestion":
        return Color(red: 1.0, green: 0.74, blue: 0.25)
    case "processing", "running":
        return Color(red: 0.30, green: 0.72, blue: 1.0)
    default:
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    }
}
