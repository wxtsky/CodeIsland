import SwiftUI

/// Above the session list while the header's trash button waits for the
/// user to confirm removing the idle cards (`AppState.idleSessionRemovalRequest`).
struct IdleSessionRemovalBanner: View {
    let count: Int
    let onCancel: () -> Void
    let onRemove: () -> Void
    @ObservedObject private var l10n = L10n.shared

    /// The banner's trash, and the header button while the banner is up.
    static let tint = Color(red: 1, green: 0.55, blue: 0.5)

    /// "Remove 1 idle card?" / "Remove 3 idle cards?"
    static func title(count: Int, l10n: L10n) -> String {
        String(format: l10n[count == 1 ? "remove_idle_sessions_count_one" : "remove_idle_sessions_count"], count)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(Self.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(count: count, l10n: l10n))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(l10n["remove_idle_sessions_confirm_help"])
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            action(l10n["remove_idle_sessions_cancel"], destructive: false, perform: onCancel)
            action(l10n["remove_idle_sessions_remove"], destructive: true, perform: onRemove)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
        .onExitCommand(perform: onCancel)
        // It opens away from VoiceOver's cursor (on the header button).
        .onAppear { AccessibilityNotification.Announcement(Self.title(count: count, l10n: l10n)).post() }
        .accessibilityIdentifier("idleSessionRemovalBanner")
    }

    private func action(_ title: String, destructive: Bool, perform: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : .cancel, action: perform) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1, green: 0.6, blue: 0.55) : .white.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(destructive ? .red.opacity(0.14) : .white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
