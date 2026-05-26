import ActivityKit
import Foundation

@MainActor
final class LiveActivityController: ObservableObject {
    @Published private(set) var activityID: String?
    @Published private(set) var lastError: String?

    private var activity: Activity<CodeIslandActivityAttributes>?
    private var lastContentState: CodeIslandActivityAttributes.ContentState?
    private var activityStateTask: Task<Void, Never>?

    var isRunning: Bool {
        activity != nil
    }

    deinit {
        activityStateTask?.cancel()
    }

    func startOrUpdate(with payload: CompanionStatePayload) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "这台 iPhone 没有开启实时活动。"
            return
        }

        Task {
            do {
                let contentState = CodeIslandActivityAttributes.ContentState(payload: payload)
                lastContentState = contentState

                if let activity {
                    await activity.update(ActivityContent(
                        state: contentState,
                        staleDate: Date().addingTimeInterval(90),
                        relevanceScore: relevanceScore(for: payload.status)
                    ))
                    lastError = nil
                    return
                }

                let attributes = CodeIslandActivityAttributes(sessionId: payload.sessionId)
                let content = ActivityContent(
                    state: contentState,
                    staleDate: Date().addingTimeInterval(90),
                    relevanceScore: relevanceScore(for: payload.status)
                )
                let created = try Activity.request(attributes: attributes, content: content)
                activity = created
                activityID = created.id
                observeState(of: created)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        guard let activity else { return }
        Task {
            let finalContent = lastContentState.map {
                ActivityContent(state: $0, staleDate: Date(), relevanceScore: 0)
            }
            await activity.end(finalContent, dismissalPolicy: .immediate)
            clearActivity(id: activity.id)
        }
    }

    private func observeState(of activity: Activity<CodeIslandActivityAttributes>) {
        activityStateTask?.cancel()
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self?.clearActivity(id: activity.id)
                break
            }
        }
    }

    private func clearActivity(id: String) {
        guard activityID == nil || activityID == id else { return }
        activity = nil
        activityID = nil
        lastContentState = nil
        activityStateTask?.cancel()
        activityStateTask = nil
    }

    private func relevanceScore(for status: CompanionStatus) -> Double {
        switch status {
        case .waitingApproval, .waitingQuestion:
            return 1
        case .processing, .running:
            return 0.7
        case .idle:
            return 0.25
        }
    }
}
