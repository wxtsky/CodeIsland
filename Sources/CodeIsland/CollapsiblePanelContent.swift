import Observation
import SwiftUI

@MainActor
@Observable
final class PanelContentVisibility {
    var isVisible: Bool
    init(isVisible: Bool) { self.isVisible = isVisible }
}

private struct PanelContentVisibilityKey: EnvironmentKey {
    static let defaultValue: PanelContentVisibility? = nil
}

extension EnvironmentValues {
    var panelContentVisibility: PanelContentVisibility? {
        get { self[PanelContentVisibilityKey.self] }
        set { self[PanelContentVisibilityKey.self] = newValue }
    }
}

private struct PanelContentHiddenAction: ViewModifier {
    @Environment(\.panelContentVisibility) private var visibility
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: visibility?.isVisible ?? true) { _, visible in
            if !visible { action() }
        }
    }
}

extension View {
    /// Mirrors disappear cleanup when retained content is clipped shut.
    func onPanelContentHidden(perform action: @escaping () -> Void) -> some View {
        modifier(PanelContentHiddenAction(action: action))
    }
}

/// Reveals already laid-out content without rebuilding or reflowing its rows.
struct CollapsiblePanelContent<Content: View>: View {
    let expanded: Bool
    let width: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var visibility = PanelContentVisibility(isVisible: false)

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .frame(height: expanded ? contentHeight : 0, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
            .environment(\.panelContentVisibility, visibility)
            .onChange(of: expanded, initial: true) { _, visible in visibility.isVisible = visible }
    }
}
