import SwiftUI

enum NotchAnimation {
    /// 展开面板：微弹，有少许回弹感
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// 收起面板：临界阻尼，无过冲（防止 NotchPanelShape 底边露出刘海）
    static let close = Animation.spring(response: 0.38, dampingFraction: 1.0)
    /// 通知弹出：快速弹跳，用于 completion/approval 自动展开
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    /// 微交互：hover 状态变化、按钮高亮等
    static let micro = Animation.easeOut(duration: 0.12)
    /// Hover 预备段：全量展开的延迟计时期间，先给一个轻量的"我看到你了"反馈
    static let hoverPrehover = Animation.easeOut(duration: NotchHoverInteraction.prehoverAnimationDuration)
}

// MARK: - Blur + Fade transition

private struct BlurFadeModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        // No compositingGroup here: macOS 26 renders compositingGroup + blur
        // (even with radius 0 in the identity state) transparent until a forced
        // re-composition, which made the approval card invisible except on hover
        // (issue #100).
        content
            .blur(radius: active ? 5 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    /// Blur out + fade — smoother than plain opacity for notch content switches.
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(active: true),
            identity: BlurFadeModifier(active: false)
        )
    }
}

// MARK: - MorphText — blur morph on text change

/// Text that briefly blurs when its content changes, creating a smooth "morph" effect.
///
/// Opt in with `streamsRapidly` for sources that push token-level deltas (AiWork /
/// Agentix `stream.text_delta` into the `$` row): those updates swap text
/// immediately instead of morphing, because each change would otherwise restart the
/// blur cycle and leave the label permanently unreadable. Every other caller keeps
/// the original morph behaviour — this is deliberately not a global change.
struct MorphText: View {
    let text: String
    var font: Font = .system(size: 12)
    var color: Color = .white
    var lineLimit: Int? = 1
    /// True only for sources in `SessionSnapshot.rapidStreamingSources`.
    var streamsRapidly: Bool = false

    @State private var displayed: String
    @State private var blur: CGFloat = 0
    @State private var generation = 0
    /// Monotonic (`systemUptime`), not wall-clock: an NTP correction or a
    /// sleep/wake that steps the clock backward would make the elapsed test
    /// negative and pin the label into no-morph mode. Same posture as
    /// MascotAnimationGate's wake-drift handling (#225).
    @State private var lastChangeAt: TimeInterval = -.greatestFiniteMagnitude

    /// Updates arriving within this window are treated as a stream, not a morph.
    private static let streamWindow: TimeInterval = 0.22

    init(
        text: String,
        font: Font = .system(size: 12),
        color: Color = .white,
        lineLimit: Int? = 1,
        streamsRapidly: Bool = false
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.streamsRapidly = streamsRapidly
        _displayed = State(initialValue: text)
    }

    var body: some View {
        Text(displayed)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .blur(radius: blur * 4)
            .opacity(1 - blur * 0.15)
            .compositingGroup()
            .onChange(of: text) { _, newText in
                guard newText != displayed else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let streaming = streamsRapidly
                    && (now - lastChangeAt < Self.streamWindow || blur > 0.01)
                lastChangeAt = now
                generation += 1
                let gen = generation

                if streaming {
                    // Keep the label sharp while content is still arriving.
                    displayed = newText
                    if blur != 0 {
                        withAnimation(.easeOut(duration: 0.12)) { blur = 0 }
                    }
                    return
                }

                withAnimation(.easeOut(duration: 0.1)) { blur = 1 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard gen == generation else { return }
                    displayed = newText
                    withAnimation(.easeOut(duration: 0.15)) { blur = 0 }
                }
            }
    }
}
