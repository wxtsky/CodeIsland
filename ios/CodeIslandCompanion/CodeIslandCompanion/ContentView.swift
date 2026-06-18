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

    private static let pendingAnchor = "companion.pendingCard"

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    CompactIslandBar()
                        .environmentObject(connection)

                    if let state = connection.latestState {
                        LiveIslandCard(state: state)
                            .environmentObject(connection)
                            .environmentObject(liveActivity)
                            .id(Self.pendingAnchor)
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
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.top, topPadding)
                .padding(.bottom, max(28, proxy.safeAreaInsets.bottom + 20))
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .accessibilityIdentifier("companion.scroll")
            .onChange(of: connection.latestState?.pendingAction) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    scroller.scrollTo(Self.pendingAnchor, anchor: .top)
                }
            }
            }
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
            lineLimit: state.question == nil ? 5 : 3,
            markdown: true
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

    @State private var selected: Set<Int> = []
    @State private var showOther = false
    @State private var textInput = ""

    private let accent = Color(red: 0.38, green: 0.68, blue: 1.0)

    var body: some View {
        if question.options.isEmpty {
            // 纯文本题：直接输入并提交
            VStack(spacing: 8) {
                answerField(placeholder: "输入你的回答")
                submitButton(title: "提交回答", enabled: !trimmed.isEmpty) {
                    connection.sendAnswer(trimmed)
                }
            }
        } else if question.allowsMultipleSelection {
            LazyVStack(spacing: 7) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option, multiSelect: true)
                }
                otherToggleRow
                if showOther {
                    answerField(placeholder: "其他（请输入）")
                }
                submitButton(title: "提交所选", enabled: canSubmitMulti) {
                    connection.sendAnswer(multiAnswer)
                }
            }
        } else {
            LazyVStack(spacing: 7) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option, multiSelect: false)
                }
                otherToggleRow
                if showOther {
                    VStack(spacing: 8) {
                        answerField(placeholder: "其他（请输入）")
                        submitButton(title: "提交", enabled: !trimmed.isEmpty) {
                            connection.sendAnswer(trimmed)
                        }
                    }
                }
            }
        }
    }

    private var trimmed: String {
        textInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitMulti: Bool {
        !selected.isEmpty || (showOther && !trimmed.isEmpty)
    }

    // 多选答案与 Mac 端 notch 一致：所选项标签按下标排序后用 ", " 拼接，"其他" 文本追加在末尾。
    private var multiAnswer: String {
        var parts = selected.sorted().compactMap { question.options.indices.contains($0) ? question.options[$0] : nil }
        if showOther && !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func optionRow(index: Int, option: String, multiSelect: Bool) -> some View {
        let isSelected = selected.contains(index)
        Button {
            if multiSelect {
                if isSelected { selected.remove(index) } else { selected.insert(index) }
            } else {
                connection.sendAnswer(option)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if multiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isSelected ? accent : .white.opacity(0.4))
                        .frame(width: 24, alignment: .leading)
                } else {
                    Text("\(index + 1).")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(accent)
                        .frame(width: 24, alignment: .leading)
                }

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
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? accent.opacity(0.5) : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private var otherToggleRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showOther.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: showOther ? "chevron.down" : "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 24, alignment: .leading)
                Text("其他…")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func answerField(placeholder: String) -> some View {
        TextField("", text: $textInput, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1...4)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1)))
            .accessibilityIdentifier("companion.question.textField")
    }

    private func submitButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? .black : .white.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(enabled ? accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("companion.question.submit")
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
        .overlay(IslandShellShape().stroke(pendingTint ?? Color.white.opacity(0.08), lineWidth: pendingTint == nil ? 1 : 1.5))
        .shadow(color: pendingTint?.opacity(0.35) ?? .black.opacity(0.35), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodeIsland 状态")
        .accessibilityIdentifier("companion.statusCard")
    }

    // 待处理时给卡片描边与光晕：审批=橙、提问=蓝。
    private var pendingTint: Color? {
        switch state.pendingAction {
        case .approval: return .orange
        case .question: return Color(red: 0.38, green: 0.68, blue: 1.0)
        case nil: return nil
        }
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

            Text(CompanionDisplayText.inlineMarkdown(question.question))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(5)

            QuestionOptionsView(question: question)
                .environmentObject(connection)
                .id("\(question.index)/\(question.total)·\(question.question)")
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

                            Text(CompanionDisplayText.inlineMarkdown(CompanionDisplayText.message(message.text) ?? message.text))
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
                    lineLimit: 4,
                    markdown: true
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
            .frame(maxWidth: sessions.count > 1 ? availableSize.width * 0.34 : .infinity, alignment: .leading)
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
            maxWidth: .infinity,
            minHeight: 260,
            maxHeight: .infinity
        )
        .background(IslandShellShape().fill(.black))
        .overlay(IslandShellShape().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private enum StandByGrouping: CaseIterable {
    case none, status, cli

    var label: String {
        switch self {
        case .none: return "全部"
        case .status: return "按状态"
        case .cli: return "按 CLI"
        }
    }

    var next: StandByGrouping {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

private struct StandByGroup: Identifiable {
    let id: String
    let items: [CompanionSessionPreview]
}

private struct StandBySessionBoard: View {
    let sessions: [CompanionSessionPreview]
    let activeCount: Int
    @State private var grouping: StandByGrouping = .none

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                header

                if grouping == .none {
                    flatAdaptiveList(boardHeight: proxy.size.height)
                } else {
                    groupedScrollList
                }

                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("companion.standby.board")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("会话")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            StandByCountBadge(count: sessions.count, activeCount: activeCount)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { grouping = grouping.next }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.3.group")
                    Text(grouping.label)
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("companion.standby.groupToggle")
        }
    }

    // 全部：按高度自适应、不滚动，超出显示「还有 N 个」。
    @ViewBuilder
    private func flatAdaptiveList(boardHeight: CGFloat) -> some View {
        let layout = standbySessionBoardLayout(boardHeight: boardHeight, sessionCount: sessions.count)
        let shown = Array(sessions.prefix(layout.visibleCount))
        let remaining = sessions.count - shown.count

        VStack(spacing: 8) {
            ForEach(shown) { session in
                StandBySessionRow(session: session, messageLineLimit: layout.messageLineLimit)
            }
        }

        if remaining > 0 {
            Text("还有 \(remaining) 个会话")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
                .accessibilityIdentifier("companion.standby.moreSessions")
        }
    }

    // 分组（按状态 / CLI）：可滚动，完整展示所有会话。
    private var groupedScrollList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groupedSessions) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(group.id) · \(group.items.count)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                        ForEach(group.items) { session in
                            StandBySessionRow(session: session, messageLineLimit: 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .accessibilityIdentifier("companion.standby.groupedScroll")
    }

    private var groupedSessions: [StandByGroup] {
        switch grouping {
        case .none:
            return [StandByGroup(id: "全部", items: sessions)]
        case .status:
            let order: [CompanionStatus] = [.waitingApproval, .waitingQuestion, .running, .processing, .idle]
            return order.compactMap { status in
                let items = sessions.filter { $0.status == status }
                return items.isEmpty ? nil : StandByGroup(id: status.label, items: items)
            }
        case .cli:
            let grouped = Dictionary(grouping: sessions) { $0.source.isEmpty ? "CODEISLAND" : $0.source.uppercased() }
            return grouped.keys.sorted().map { StandByGroup(id: $0, items: grouped[$0] ?? []) }
        }
    }
}

private struct StandBySessionRow: View {
    let session: CompanionSessionPreview
    var messageLineLimit: Int = 1

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CompanionMascotView(source: session.source, status: session.status, size: 32)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                // 身份行：名称（按状态着色）+ #短id · 工作区 + time-ago
                HStack(spacing: 6) {
                    Text(session.source.isEmpty ? "CODEISLAND" : session.source.uppercased())
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(statusNameColor)
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let shortId = shortSessionId {
                        Text("#\(shortId)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                    }
                    if let workspace = CompanionDisplayText.workspace(session.workspaceName) {
                        Text("·")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.28))
                        Text(workspace)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 6)
                    SessionTag(standbyTimeAgo(session.updatedAt))
                }

                // 消息行：用户最近输入
                if let message = CompanionDisplayText.message(session.message) {
                    Text(CompanionDisplayText.inlineMarkdown(message))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(messageLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 工作指示行：$ 工具 / 思考中（对齐 notch SessionCard）
                if session.status != .idle {
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                        Text(workingText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((highlightTint ?? .white).opacity(highlightTint == nil ? 0.055 : 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(highlightTint?.opacity(0.55) ?? Color.white.opacity(0.07), lineWidth: highlightTint == nil ? 1 : 1.5))
        .accessibilityIdentifier("companion.standby.sessionRow")
    }

    // 名称按状态着色，对齐 notch SessionCard：运行/处理=绿，待办=橙，空闲=白。
    private var statusNameColor: Color {
        switch session.status {
        case .processing, .running: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .waitingApproval, .waitingQuestion: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .idle: return .white
        }
    }

    // 短会话 id（去掉连字符取末 4 位），对齐 notch 的 #id。
    private var shortSessionId: String? {
        guard let id = session.sessionId else { return nil }
        let clean = id.replacingOccurrences(of: "-", with: "")
        return clean.isEmpty ? nil : String(clean.suffix(4))
    }

    // 工作指示文案：当前工具，否则「思考中」。
    private var workingText: String {
        CompanionDisplayText.tool(session.toolName) ?? "思考中…"
    }

    // 待处理状态高亮：审批=橙、提问=蓝；其余不高亮。
    private var highlightTint: Color? {
        switch session.status {
        case .waitingApproval: return .orange
        case .waitingQuestion: return Color(red: 0.38, green: 0.68, blue: 1.0)
        default: return nil
        }
    }
}

// 小标签胶囊，对齐 notch SessionCard 的 SessionTag。
private struct SessionTag: View {
    let text: String
    var color: Color = .white.opacity(0.7)

    init(_ text: String, color: Color = .white.opacity(0.7)) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
    }
}

// 相对时间，对齐 notch timeAgo 格式。
private func standbyTimeAgo(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60 { return "<1m" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
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
    // 待处理项自动聚焦：按状态优先级（审批>提问>运行>处理>空闲）排序，同级按最近更新。
    return state.sessions.sorted { lhs, rhs in
        if lhs.status.priority != rhs.status.priority {
            return lhs.status.priority > rhs.status.priority
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private struct MorphText: View {
    let text: String
    var font: Font = .system(size: 12)
    var color: Color = .white
    var lineLimit: Int? = 1
    var markdown: Bool = false

    @State private var displayed: String
    @State private var blur: CGFloat = 0
    @State private var generation = 0

    init(text: String, font: Font = .system(size: 12), color: Color = .white, lineLimit: Int? = 1, markdown: Bool = false) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.markdown = markdown
        _displayed = State(initialValue: text)
    }

    private var renderedText: Text {
        markdown ? Text(CompanionDisplayText.inlineMarkdown(displayed)) : Text(displayed)
    }

    var body: some View {
        renderedText
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
