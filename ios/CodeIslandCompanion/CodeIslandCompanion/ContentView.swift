import MultipeerConnectivity
import SwiftUI

private enum CodeIslandMotion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let close = Animation.spring(response: 0.38, dampingFraction: 1.0)
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    static let micro = Animation.easeOut(duration: 0.12)
}

struct ContentView: View {
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(red: 0.015, green: 0.016, blue: 0.018)
                    .ignoresSafeArea()

                if proxy.size.width > proxy.size.height, let state = connection.latestState {
                    StandByIsland(state: state, availableSize: proxy.size)
                        .environmentObject(connection)
                        .environmentObject(liveActivity)
                } else {
                    PortraitIslandView(topPadding: max(86, proxy.safeAreaInsets.top + 8))
                        .environmentObject(connection)
                        .environmentObject(liveActivity)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
            .onAppear {
                connection.start()
            }
            .onChange(of: connection.latestState?.sequence) { _, _ in
                guard liveActivity.isRunning, let state = connection.latestState else { return }
                liveActivity.startOrUpdate(with: state)
            }
            .animation(CodeIslandMotion.open, value: connection.connectedPeer)
            .animation(CodeIslandMotion.pop, value: connection.latestState?.status)
            .animation(CodeIslandMotion.micro, value: connection.browsing)
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("companion.root")
    }
}

private struct PortraitIslandView: View {
    let topPadding: CGFloat
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    CompactIslandBar()
                        .environmentObject(connection)

                    if let state = connection.latestState {
                        LiveIslandCard(state: state)
                            .environmentObject(connection)
                            .environmentObject(liveActivity)
                            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .top)))

                        MessageStrip(messages: state.messages)
                    } else {
                        DiscoveryIsland()
                            .environmentObject(connection)
                            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .top)))

                        DiscoveryFill()
                    }

                    if let error = connection.lastError {
                        DiagnosticStrip(message: error)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    }

                    if let error = liveActivity.lastError {
                        LiveActivityDiagnosticStrip(message: error)
                            .environmentObject(liveActivity)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, topPadding)
                .padding(.bottom, max(28, proxy.safeAreaInsets.bottom + 20))
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .accessibilityIdentifier("companion.scroll")
        }
    }
}

private struct PrimaryMessageView: View {
    let state: CompanionStatePayload

    var body: some View {
        let text = state.question?.question
            ?? CompanionDisplayText.message(state.messages.last?.text)
            ?? "当前没有新的消息"

        MorphText(
            text: text,
            font: .system(size: 16, weight: .medium),
            color: .white.opacity(state.messages.isEmpty && state.question == nil ? 0.55 : 0.86),
            lineLimit: state.question == nil ? 5 : 3
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MetadataChipRow: View {
    let workspaceName: String?
    let toolName: String?

    private var workspaceText: String? {
        CompanionDisplayText.workspace(workspaceName)
    }

    private var toolText: String? {
        CompanionDisplayText.tool(toolName)
    }

    var body: some View {
        if workspaceText != nil || toolText != nil {
            HStack(spacing: 8) {
                if let workspaceText {
                    TinyChip(icon: "folder", text: workspaceText)
                }
                if let toolText {
                    TinyChip(icon: "hammer", text: toolText)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct QuestionOptionsView: View {
    let question: CompanionQuestionPayload
    @EnvironmentObject private var connection: CompanionConnection

    var body: some View {
        if question.allowsMultipleSelection {
            Text("多选问题请先在 Mac 上回答")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        } else if question.options.isEmpty {
            Text("文本回答请先在 Mac 上输入")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        } else {
            LazyVStack(spacing: 7) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        connection.sendAnswer(option)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundStyle(Color(red: 0.38, green: 0.68, blue: 1.0))
                                .frame(width: 24, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if question.descriptions.indices.contains(index) {
                                    Text(question.descriptions[index])
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DiscoveryFill: View {
    @EnvironmentObject private var connection: CompanionConnection

    var body: some View {
        VStack(spacing: 12) {
            DividerLine()
                .padding(.top, 2)

            Text("保持 iPhone 与 Mac 在同一网络，CodeIsland 会持续同步当前状态。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)

            IslandButton(
                title: "进入演示模式",
                icon: "play.rectangle.fill",
                tint: Color(red: 0.25, green: 0.76, blue: 1.0),
                accessibilityIdentifier: "companion.enterDemoMode"
            ) {
                connection.enterDemoMode()
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct CompactIslandBar: View {
    @EnvironmentObject private var connection: CompanionConnection

    var body: some View {
        HStack(spacing: 8) {
            CompanionMascotView(source: connection.latestState?.source ?? "codex", status: compactStatus, size: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                MorphText(
                    text: connection.latestState?.source.uppercased() ?? "CODEISLAND",
                    font: .system(size: 12, weight: .black, design: .rounded),
                    color: .white
                )
                MorphText(
                    text: compactSubtitle,
                    font: .system(size: 10, weight: .medium, design: .monospaced),
                    color: .white.opacity(0.52)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Spacer()

            ConnectionDot(active: connection.connectedPeer != nil, browsing: connection.browsing)

            Button {
                connection.browsing ? connection.stop() : connection.start()
            } label: {
                Image(systemName: connection.browsing ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(connection.browsing ? "停止搜索 Mac" : "搜索 Mac")
            .accessibilityIdentifier("companion.search.toggle")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 46)
        .background(IslandShellShape().fill(.black))
        .overlay(IslandShellShape().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
    }

    private var compactStatus: CompanionStatus {
        connection.latestState?.status ?? (connection.browsing ? .processing : .idle)
    }

    private var compactSubtitle: String {
        if let state = connection.latestState {
            if let toolName = state.toolName, !toolName.isEmpty {
                return CompanionDisplayText.tool(toolName) ?? toolName
            }
            if let workspaceName = state.workspaceName, !workspaceName.isEmpty {
                return CompanionDisplayText.workspace(workspaceName) ?? workspaceName
            }
            return state.status.label
        }
        if let peer = connection.connectedPeer {
            return peer.displayName
        }
        return connection.browsing ? "搜索中" : "离线"
    }
}

private struct LiveIslandCard: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    MorphText(
                        text: state.source.isEmpty ? "CodeIsland" : state.source.uppercased(),
                        font: .system(size: 15, weight: .bold, design: .rounded),
                        color: .white
                    )
                    MorphText(
                        text: CompanionDisplayText.subtitle(
                            workspaceName: state.workspaceName,
                            toolName: state.toolName,
                            fallback: "Mac 已连接"
                        ),
                        font: .system(size: 12, weight: .medium),
                        color: .white.opacity(0.58)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 10)

                if state.pendingAction != nil {
                    StatusPill(status: state.status)
                } else {
                    HeaderStatusDot(status: state.status)
                }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            DividerLine()

            VStack(alignment: .leading, spacing: state.question == nil ? 14 : 10) {
                PrimaryMessageView(state: state)

                MetadataChipRow(workspaceName: state.workspaceName, toolName: state.toolName)

                if let question = state.question {
                    QuestionPromptCard(question: question)
                        .environmentObject(connection)
                        .transition(.blurFade.combined(with: .move(edge: .top)))
                }

                CommandRow(state: state)
                    .environmentObject(connection)
                    .environmentObject(liveActivity)
            }
            .padding(14)
            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
        .background(IslandShellShape().fill(.black))
        .overlay(IslandShellShape().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodeIsland 状态")
        .accessibilityIdentifier("companion.statusCard")
    }
}

private struct QuestionPromptCard: View {
    let question: CompanionQuestionPayload
    @EnvironmentObject private var connection: CompanionConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("?")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 0.38, green: 0.68, blue: 1.0))
                if let header = question.header, !header.isEmpty {
                    Text(header)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(Color(red: 0.38, green: 0.68, blue: 1.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.38, green: 0.68, blue: 1.0).opacity(0.14), in: Capsule())
                }
                Spacer()
                if question.total > 1 {
                    Text("\(question.index)/\(question.total)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            Text(question.question)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(5)

            QuestionOptionsView(question: question)
                .environmentObject(connection)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.04, green: 0.05, blue: 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.orange.opacity(0.24)))
        .accessibilityIdentifier("companion.questionCard")
    }
}

private struct DiscoveryIsland: View {
    @EnvironmentObject private var connection: CompanionConnection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    MorphText(
                        text: connection.connectedPeer == nil ? "等待 Mac" : "已连接 Mac",
                        font: .system(size: 15, weight: .bold, design: .rounded),
                        color: .white
                    )
                    MorphText(
                        text: subtitle,
                        font: .system(size: 12, weight: .medium),
                        color: .white.opacity(0.58)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                ConnectionDot(active: connection.connectedPeer != nil, browsing: connection.browsing)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            DividerLine()

            VStack(spacing: 10) {
                if connection.discoveredPeers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.green)
                        Text(connection.browsing ? "正在搜索附近的 CodeIsland" : "搜索已停止")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                        Spacer()
                    }
                    .frame(minHeight: 48)
                } else {
                    ForEach(connection.discoveredPeers, id: \.self) { peer in
                        Button {
                            connection.connect(to: peer)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "macbook")
                                    .font(.headline)
                                    .foregroundStyle(.green)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                Text(peer.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)

                                Spacer()

                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .background(IslandShellShape().fill(.black))
        .overlay(IslandShellShape().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .accessibilityIdentifier("companion.discoveryCard")
    }

    private var subtitle: String {
        if let peer = connection.connectedPeer {
            return peer.displayName
        }
        if connection.discoveredPeers.isEmpty {
            return connection.browsing ? "广播握手中" : "点右上角继续搜索"
        }
        return "发现 \(connection.discoveredPeers.count) 台设备"
    }
}

private struct CommandRow: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        VStack(spacing: 8) {
            if connection.isDemoMode {
                HStack(spacing: 8) {
                    IslandButton(
                        title: "切换演示状态",
                        icon: "arrow.triangle.2.circlepath",
                        tint: Color(red: 0.25, green: 0.76, blue: 1.0),
                        accessibilityIdentifier: "companion.demo.nextState"
                    ) {
                        connection.cycleDemoState()
                    }
                    IslandButton(
                        title: "退出演示",
                        icon: "xmark",
                        tint: .red,
                        accessibilityIdentifier: "companion.demo.exit"
                    ) {
                        connection.exitDemoMode()
                    }
                }
            }

            if state.pendingAction == .question {
                HStack(spacing: 8) {
                    IslandButton(
                        title: "在 Mac 回答",
                        icon: "arrow.up.forward.app.fill",
                        tint: Color(red: 0.35, green: 0.85, blue: 0.45),
                        accessibilityIdentifier: "companion.command.focus"
                    ) {
                        connection.send(.focus)
                    }
                    IslandButton(
                        title: "跳过",
                        icon: "forward.fill",
                        tint: .orange,
                        accessibilityIdentifier: "companion.command.skip"
                    ) {
                        connection.send(.skipCurrentQuestion)
                    }
                }
                .transition(.blurFade.combined(with: .move(edge: .top)))

                LiveActivityInlineButton(state: state)
            } else {
                HStack(spacing: 8) {
                    IslandButton(
                        title: "打开 Mac 会话",
                        icon: "arrow.up.forward.app.fill",
                        tint: Color(red: 0.35, green: 0.85, blue: 0.45),
                        accessibilityIdentifier: "companion.command.focus"
                    ) {
                        connection.send(.focus)
                    }

                    IslandButton(
                        title: liveActivity.isRunning ? "更新实时活动" : "开启实时活动",
                        icon: liveActivity.isRunning ? "arrow.clockwise" : "bolt.horizontal.fill",
                        tint: Color(red: 0.25, green: 0.76, blue: 1.0),
                        accessibilityIdentifier: "companion.liveActivity.primaryButton"
                    ) {
                        liveActivity.startOrUpdate(with: state)
                    }
                }

                if state.pendingAction == .approval {
                    HStack(spacing: 8) {
                        IslandButton(title: "批准", icon: "checkmark", tint: .orange, accessibilityIdentifier: "companion.command.approve") {
                            connection.send(.approveCurrentPermission)
                        }
                        IslandButton(title: "拒绝", icon: "xmark", tint: .red, accessibilityIdentifier: "companion.command.deny") {
                            connection.send(.denyCurrentPermission)
                        }
                    }
                    .transition(.blurFade.combined(with: .move(edge: .top)))
                }

                if liveActivity.isRunning {
                    LiveActivityInlineButton(state: state)
                }
            }
        }
    }
}

private struct LiveActivityInlineButton: View {
    let state: CompanionStatePayload
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        Button {
            if liveActivity.isRunning {
                liveActivity.stop()
            } else {
                liveActivity.startOrUpdate(with: state)
            }
        } label: {
            Label(
                liveActivity.isRunning ? "停止实时活动" : "同步到实时活动",
                systemImage: liveActivity.isRunning ? "stop.circle.fill" : "bolt.horizontal.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(liveActivity.isRunning ? .white.opacity(0.62) : Color(red: 0.25, green: 0.76, blue: 1.0).opacity(0.86))
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.liveActivity.inlineButton")
    }
}

private struct MessageStrip: View {
    let messages: [CompanionMessagePreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                    Text("最近动态")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .textCase(.uppercase)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 0.5)
            }

            if messages.isEmpty {
                HStack(spacing: 8) {
                    PulseDot(status: .idle)
                    Text("等待下一条同步消息")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(messages.suffix(3))) { message in
                        HStack(alignment: .top, spacing: 12) {
                            Text(message.role.label)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(message.role == .user ? .black : .white)
                                .frame(width: 42, height: 28)
                                .background(message.role == .user ? Color.white.opacity(0.86) : Color.white.opacity(0.12), in: Capsule())

                            Text(CompanionDisplayText.message(message.text) ?? message.text)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.76))
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .transition(.blurFade.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06)))
        .accessibilityIdentifier("companion.messages")
    }
}

private struct StandByIsland: View {
    let state: CompanionStatePayload
    let availableSize: CGSize
    @EnvironmentObject private var connection: CompanionConnection
    @EnvironmentObject private var liveActivity: LiveActivityController

    private var sessions: [CompanionSessionPreview] {
        standbySessions(for: state)
    }

    private var activeCount: Int {
        sessions.filter { $0.status != .idle }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    CompanionMascotView(source: state.source, status: state.status, size: 78)

                    VStack(alignment: .leading, spacing: 5) {
                        MorphText(
                            text: sessions.count > 1 ? "CODE ISLAND" : (state.source.isEmpty ? "CODEISLAND" : state.source.uppercased()),
                            font: .system(size: 32, weight: .black, design: .rounded),
                            color: .white
                        )
                        MorphText(
                            text: sessions.count > 1 ? "\(sessions.count) 个会话 · \(activeCount) 个活跃" : state.status.label,
                            font: .system(size: 22, weight: .semibold, design: .rounded),
                            color: activeCount > 0 ? .green : statusColor(state.status)
                        )
                    }
                }

                MorphText(
                    text: CompanionDisplayText.message(state.messages.last?.text)
                        ?? CompanionDisplayText.workspace(state.workspaceName)
                        ?? "CodeIsland 已连接",
                    font: .system(size: 24, weight: .medium, design: .rounded),
                    color: .white.opacity(0.82),
                    lineLimit: 4
                )
                .minimumScaleFactor(0.72)

                HStack(spacing: 10) {
                    if let workspaceText = CompanionDisplayText.workspace(state.workspaceName) {
                        TinyChip(icon: "folder", text: workspaceText)
                    }
                    if let toolText = CompanionDisplayText.tool(state.toolName) {
                        TinyChip(icon: "hammer", text: toolText)
                    }
                }
            }
            .frame(maxWidth: sessions.count > 1 ? availableSize.width * 0.42 : .infinity, alignment: .leading)
            .padding(24)

            DividerLine(vertical: true)

            if sessions.count > 1 {
                StandBySessionBoard(sessions: sessions, activeCount: activeCount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(20)
            } else {
                VStack(spacing: 10) {
                    IconIslandButton(icon: "arrow.up.forward.app.fill", tint: Color(red: 0.35, green: 0.85, blue: 0.45)) {
                        connection.send(.focus)
                    }
                    IconIslandButton(icon: liveActivity.isRunning ? "arrow.clockwise" : "bolt.horizontal.fill", tint: Color(red: 0.25, green: 0.76, blue: 1.0)) {
                        liveActivity.startOrUpdate(with: state)
                    }
                    if state.pendingAction != nil {
                        IconIslandButton(icon: "checkmark", tint: .orange) {
                            connection.send(.approveCurrentPermission)
                        }
                        IconIslandButton(icon: "xmark", tint: .red) {
                            connection.send(.denyCurrentPermission)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(
            width: min(760, max(0, availableSize.width - 28)),
            height: max(260, availableSize.height - 24)
        )
        .background(IslandShellShape().fill(.black))
        .overlay(IslandShellShape().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct StandBySessionBoard: View {
    let sessions: [CompanionSessionPreview]
    let activeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("会话")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                StandByCountBadge(count: sessions.count, activeCount: activeCount)
                Spacer(minLength: 0)
            }

            VStack(spacing: 8) {
                ForEach(Array(sessions.prefix(4))) { session in
                    StandBySessionRow(session: session)
                }
            }

            if sessions.count > 4 {
                Text("还有 \(sessions.count - 4) 个会话")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }
    }
}

private struct StandBySessionRow: View {
    let session: CompanionSessionPreview

    var body: some View {
        HStack(spacing: 10) {
            CompanionMascotView(source: session.source, status: session.status, size: 38)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.source.isEmpty ? "CODEISLAND" : session.source.uppercased())
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let workspace = CompanionDisplayText.workspace(session.workspaceName) {
                        Text(workspace)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
                }
                Text(standbySessionText(session))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PulseDot(status: session.status)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

private struct StandByCountBadge: View {
    let count: Int
    let activeCount: Int

    var body: some View {
        Text(activeCount > 0 ? "\(activeCount) 活跃" : "\(count) 总计")
            .font(.system(size: 12, weight: .black, design: .rounded))
            .foregroundStyle(activeCount > 0 ? .green : .white.opacity(0.64))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((activeCount > 0 ? Color.green : Color.white).opacity(0.12), in: Capsule())
    }
}

private func standbySessions(for state: CompanionStatePayload) -> [CompanionSessionPreview] {
    guard !state.sessions.isEmpty else {
        return [
            CompanionSessionPreview(
                sessionId: state.sessionId,
                source: state.source,
                status: state.status,
                toolName: state.toolName,
                workspaceName: state.workspaceName,
                message: state.question?.question ?? state.messages.last?.text,
                updatedAt: state.updatedAt
            )
        ]
    }
    return state.sessions
}

private func standbySessionText(_ session: CompanionSessionPreview) -> String {
    if let message = CompanionDisplayText.message(session.message), !message.isEmpty {
        return message
    }
    if let toolName = CompanionDisplayText.tool(session.toolName), !toolName.isEmpty {
        return toolName
    }
    return session.status.label
}

private struct MorphText: View {
    let text: String
    var font: Font = .system(size: 12)
    var color: Color = .white
    var lineLimit: Int? = 1

    @State private var displayed: String
    @State private var blur: CGFloat = 0
    @State private var generation = 0

    init(text: String, font: Font = .system(size: 12), color: Color = .white, lineLimit: Int? = 1) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        _displayed = State(initialValue: text)
    }

    var body: some View {
        Text(displayed)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .blur(radius: blur * 4)
            .opacity(1 - blur * 0.15)
            .animation(CodeIslandMotion.micro, value: blur)
            .onChange(of: text) { _, newText in
                guard newText != displayed else { return }
                generation += 1
                let current = generation
                withAnimation(.easeOut(duration: 0.1)) { blur = 1 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard current == generation else { return }
                    displayed = newText
                    withAnimation(.easeOut(duration: 0.15)) { blur = 0 }
                }
            }
    }
}

private struct IslandShellShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: rect)
    }
}

private struct DividerLine: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

private struct StatusPill: View {
    let status: CompanionStatus

    var body: some View {
        HStack(spacing: 6) {
            PulseDot(status: status)
            Text(status.shortLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct HeaderStatusDot: View {
    let status: CompanionStatus

    var body: some View {
        PulseDot(status: status)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.07), in: Capsule())
            .accessibilityLabel(status.label)
    }
}

private struct PulseDot: View {
    let status: CompanionStatus

    var body: some View {
        TimelineView(.animation) { timeline in
            let scale = pulseScale(timeline.date.timeIntervalSinceReferenceDate)
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(statusColor(status).opacity(0.5), lineWidth: 1)
                        .scaleEffect(scale)
                        .opacity(max(0, 1.2 - scale))
                }
        }
        .frame(width: 14, height: 14)
    }

    private func pulseScale(_ phase: TimeInterval) -> CGFloat {
        switch status {
        case .idle:
            return 1
        case .processing, .running:
            return 1 + CGFloat((sin(phase * 4.2) + 1) * 0.28)
        case .waitingApproval, .waitingQuestion:
            return 1 + CGFloat((sin(phase * 7.0) + 1) * 0.42)
        }
    }
}

private struct ConnectionDot: View {
    let active: Bool
    let browsing: Bool

    var body: some View {
        PulseDot(status: active ? .running : (browsing ? .processing : .idle))
        .frame(width: 30, height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityLabel(active ? "Mac 已连接" : (browsing ? "正在搜索 Mac" : "Mac 未连接"))
    }
}

private struct TinyChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.64))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.07), in: Capsule())
    }
}

private struct IslandButton: View {
    let title: String
    let icon: String
    let tint: Color
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(tint == .orange ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(buttonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.42)))
        }
        .buttonStyle(.plain)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }

    private var buttonBackground: Color {
        tint == .orange ? .orange : tint.opacity(0.20)
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private struct IconIslandButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint == .orange ? .black : .white)
                .frame(width: 52, height: 52)
                .background(tint == .orange ? .orange : tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }
}

private struct DiagnosticStrip: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

private struct LiveActivityDiagnosticStrip: View {
    let message: String
    @EnvironmentObject private var liveActivity: LiveActivityController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "bolt.horizontal.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 1.0))

            Button {
                liveActivity.stopAll()
            } label: {
                Label("清理已有实时活动后重试", systemImage: "trash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.10, green: 0.18, blue: 0.24)))
    }
}

private struct BlurFadeModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 5 : 0)
            .opacity(active ? 0 : 1)
    }
}

private extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(active: true),
            identity: BlurFadeModifier(active: false)
        )
    }
}

private func statusColor(_ status: CompanionStatus) -> Color {
    switch status {
    case .idle:
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    case .processing, .running:
        return Color(red: 0.30, green: 0.85, blue: 0.40)
    case .waitingApproval, .waitingQuestion:
        return Color(red: 1.0, green: 0.55, blue: 0.0)
    }
}

#Preview {
    ContentView()
        .environmentObject(CompanionConnection())
        .environmentObject(LiveActivityController())
}
