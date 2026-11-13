import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "NotchNavigation")

/// Coordinates horizontal scroll and trackpad swipe gestures over the notch area
/// to seamlessly navigate between feature tabs (Agents, Workspace, Music).
@MainActor
final class NotchNavigationManager {
    static let shared = NotchNavigationManager()

    private var accumulatedDeltaX: CGFloat = 0
    private var lastSwitchTime: Date = .distantPast
    private var gestureTriggered = false
    private let threshold: CGFloat = 20.0
    private let throttleInterval: TimeInterval = 0.22

    private init() {}

    /// Handle scroll wheel / trackpad gestures over the notch.
    /// Returns true if the event was consumed as a horizontal tab navigation gesture.
    func handleScroll(event: NSEvent, appState: AppState) -> Bool {
        let isEnabled = UserDefaults.standard.object(forKey: SettingsKey.notchScrollTabSwitch) as? Bool ?? SettingsDefaults.notchScrollTabSwitch
        guard isEnabled else { return false }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Only handle predominant horizontal scroll
        guard abs(deltaX) > abs(deltaY) else { return false }
        guard abs(deltaX) > 0.4 else { return false }
        guard !appState.isTabTransitioning else { return true }

        // Handle trackpad phases
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began {
                accumulatedDeltaX = 0
                gestureTriggered = false
            } else if event.phase == [.ended] || event.phase == [.cancelled] {
                accumulatedDeltaX = 0
                gestureTriggered = false
                return true
            } else if !event.momentumPhase.isEmpty {
                // Ignore inertia / momentum after fingers lift
                return true
            }
        }

        // On macOS trackpad:
        // Swiping 2 fingers from RIGHT to LEFT pulls in the next tab (+1: Agents(0) -> Workspace(1) -> Music(2)).
        // Trackpad deltaX is negative when swiping left, so we invert it to positive forward progress:
        let rawDelta: CGFloat = event.hasPreciseScrollingDeltas
            ? deltaX
            : (deltaX > 0 ? 15.0 : -15.0)
        let effectiveDelta = -rawDelta

        accumulatedDeltaX += effectiveDelta

        if event.hasPreciseScrollingDeltas {
            guard !gestureTriggered else { return true }
            if accumulatedDeltaX >= threshold {
                gestureTriggered = true
                accumulatedDeltaX = 0
                navigateTab(forward: true, appState: appState)
                return true
            } else if accumulatedDeltaX <= -threshold {
                gestureTriggered = true
                accumulatedDeltaX = 0
                navigateTab(forward: false, appState: appState)
                return true
            }
        } else {
            // Traditional stepped mouse wheel without phases
            let now = Date()
            guard now.timeIntervalSince(lastSwitchTime) > throttleInterval else { return true }
            if effectiveDelta > 0 {
                lastSwitchTime = now
                navigateTab(forward: true, appState: appState)
                return true
            } else if effectiveDelta < 0 {
                lastSwitchTime = now
                navigateTab(forward: false, appState: appState)
                return true
            }
        }

        return true
    }

    private func navigateTab(forward: Bool, appState: AppState) {
        // Expand surface to sessionList if collapsed
        if !appState.surface.isExpanded {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                appState.surface = .sessionList
            }
        }

        let currentTab = appState.expandedTab
        let currentIndex = currentTab.rawValue
        let targetIndex = currentIndex + (forward ? 1 : -1)

        let allTabs = PrayerTimeManager.shared.isEnabled
            ? ExpandedContentTab.allCases
            : ExpandedContentTab.allCases.filter { $0 != .prayer }
        if targetIndex >= 0 && targetIndex < allTabs.count {
            let targetTab = allTabs[targetIndex]
            appState.transitionToTab(targetTab)
            let hapticOn = UserDefaults.standard.object(forKey: SettingsKey.hapticOnHover) as? Bool ?? SettingsDefaults.hapticOnHover
            if hapticOn {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        } else {
            // Reached boundary edge
            let hapticOn = UserDefaults.standard.object(forKey: SettingsKey.hapticOnHover) as? Bool ?? SettingsDefaults.hapticOnHover
            if hapticOn {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            }
        }
    }
}
