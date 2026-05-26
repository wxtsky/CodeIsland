import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let state = connection.latestState {
                        WatchHeroView(state: state)
                        WatchMessageView(state: state)
                        WatchActionView(state: state)
                        WatchRecentView(messages: state.messages)
                    } else {
                        WatchEmptyView(error: connection.lastError)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .background(Color.black)
            .navigationTitle("Code Island")
        }
    }
}

private struct WatchHeroView: View {
    let state: CompanionStatePayload

    var body: some View {
        HStack(spacing: 10) {
            SharedMascotView(source: state.source, status: MascotAgentStatus(state.status.rawValue), size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.source.uppercased())
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(CompanionDisplayText.subtitle(
                    workspaceName: state.workspaceName,
                    toolName: state.toolName,
                    fallback: "Mac"
                ))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            WatchStatusDot(status: state.status)
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct WatchMessageView: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WatchChip(text: CompanionDisplayText.workspace(state.workspaceName) ?? "工作区", icon: "folder")
                if let toolText = CompanionDisplayText.tool(state.toolName) {
                    WatchChip(text: toolText, icon: "hammer")
                }
            }

            Text(primaryText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            if let question = state.question, !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(question.options.prefix(3).enumerated()), id: \.offset) { _, option in
                        Button {
                            connection.send(.answerQuestion, answer: option)
                        } label: {
                            Text(option)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(statusColor(state.status).opacity(0.38), lineWidth: 1)
        )
    }

    private var primaryText: String {
        if let question = state.question?.question {
            return question
        }
        if let message = CompanionDisplayText.message(state.messages.last?.text) {
            return message
        }
        return "当前没有新的消息"
    }
}

private struct WatchActionView: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        VStack(spacing: 7) {
            Button {
                connection.send(.focus)
            } label: {
                Label("打开 Mac", systemImage: "arrow.up.forward.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.12, green: 0.45, blue: 0.20))

            if state.pendingAction == .approval {
                HStack(spacing: 6) {
                    Button("批准") {
                        connection.send(.approveCurrentPermission)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button("拒绝") {
                        connection.send(.denyCurrentPermission)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else if state.pendingAction == .question {
                Button("在 iPhone 上回答") {
                    connection.send(.focus)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        }
    }
}

private struct WatchRecentView: View {
    let messages: [CompanionMessagePreview]

    var body: some View {
        let recent = messages.suffix(2)

        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("最近动态")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))

                ForEach(Array(recent.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 6) {
                        Text(message.role.label)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white.opacity(message.role == .user ? 0.9 : 0.22), in: Capsule())

                        Text(CompanionDisplayText.message(message.text) ?? message.text)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(3)
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct WatchEmptyView: View {
    let error: String?

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            SharedMascotView(source: "codex", status: .idle, size: 54)

            Text("等待 iPhone 同步")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(error ?? "先打开 iPhone 上的 Code Island，并连接 Mac。")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }
}

private struct WatchChip: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct WatchStatusDot: View {
    let status: CompanionStatus

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 10, height: 10)
            .padding(8)
            .background(statusColor(status).opacity(0.16), in: Circle())
            .accessibilityLabel(status.label)
    }
}

private func statusColor(_ status: CompanionStatus) -> Color {
    switch status {
    case .idle:
        return Color(red: 0.62, green: 0.68, blue: 0.76)
    case .processing, .running:
        return Color(red: 0.25, green: 0.86, blue: 0.38)
    case .waitingApproval, .waitingQuestion:
        return Color.orange
    }
}
