import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let state = connection.latestState {
                    WatchIslandHeader(state: state)
                    WatchSessionCard(state: state)
                    WatchActionStrip(state: state)
                    WatchRecentView(messages: state.messages)
                } else {
                    WatchEmptyView(error: connection.lastError)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct WatchIslandHeader: View {
    let state: CompanionStatePayload

    var body: some View {
        HStack(spacing: 8) {
            SharedMascotView(source: state.source, status: MascotAgentStatus(state.status.rawValue), size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(CompanionDisplayText.source(state.source))
                    .font(.system(size: 15, weight: .black, design: .rounded))
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
            WatchStatusBadge(status: state.status, compact: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.055), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct WatchSessionCard: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                SharedMascotView(source: state.source, status: MascotAgentStatus(state.status.rawValue), size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(CompanionDisplayText.source(state.source))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Text(CompanionDisplayText.subtitle(
                        workspaceName: state.workspaceName,
                        toolName: state.toolName,
                        fallback: "Mac"
                    ))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
                WatchStatusBadge(status: state.status)
            }

            Text(primaryText)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                WatchChip(text: CompanionDisplayText.workspace(state.workspaceName) ?? "工作区", icon: "folder")
                if let toolText = CompanionDisplayText.tool(state.toolName) {
                    WatchChip(text: toolText, icon: "hammer")
                }
            }

            if let question = state.question, !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        if let header = question.header, !header.isEmpty {
                            Text(header)
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.18), in: Capsule())
                        }

                        Text("\(question.index + 1)/\(question.total)")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.10), in: Capsule())
                    }

                    ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { index, option in
                        Button {
                            connection.send(.answerQuestion, answer: option)
                        } label: {
                            HStack(spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(.blue)
                                    .frame(width: 18, alignment: .leading)

                                Text(option)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.90))
                                    .lineLimit(2)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
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

private struct WatchActionStrip: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: WatchConnection

    var body: some View {
        VStack(spacing: 6) {
            Button {
                connection.send(.focus)
            } label: {
                WatchActionLabel(title: "打开 Mac", systemImage: "arrow.up.forward.app.fill", color: .green)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            if state.pendingAction == .approval {
                HStack(spacing: 6) {
                    Button {
                        connection.send(.approveCurrentPermission)
                    } label: {
                        WatchActionLabel(title: "批准", systemImage: "checkmark", color: .orange)
                    }
                    .buttonStyle(.plain)

                    Button {
                        connection.send(.denyCurrentPermission)
                    } label: {
                        WatchActionLabel(title: "拒绝", systemImage: "xmark", color: .red)
                    }
                    .buttonStyle(.plain)
                }
            } else if state.pendingAction == .question {
                Button {
                    connection.send(.focus)
                } label: {
                    WatchActionLabel(title: "去 iPhone 回答", systemImage: "questionmark.bubble.fill", color: .blue)
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))

                ForEach(Array(recent.enumerated()), id: \.offset) { _, message in
                    HStack(alignment: .top, spacing: 6) {
                        Text(message.role.label)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white.opacity(message.role == .user ? 0.9 : 0.22), in: Capsule())

                        Text(CompanionDisplayText.message(message.text) ?? message.text)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(4)
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
        VStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                SharedMascotView(source: "codex", status: .idle, size: 34)
                Text("Code Island")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            SharedMascotView(source: "codex", status: .idle, size: 60)

            Text("等待 iPhone 同步")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(error ?? "先打开 iPhone 上的 Code Island，并连接 Mac。")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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

private struct WatchStatusBadge: View {
    let status: CompanionStatus
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
            if !compact {
                Text(status.shortLabel)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 6 : 7)
        .background(statusColor(status).opacity(0.16), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

private struct WatchActionLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(color.opacity(0.34), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.72), lineWidth: 1)
            )
            .accessibilityLabel(title)
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
