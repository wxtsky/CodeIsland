import AppKit
import CodeIslandCore
import Foundation

/// Owns the plan-limit snapshot and drives fetches through
/// `ClaudeQuotaScheduler`. Event-driven: AppState reports Stop hooks and
/// panel expansion; this class turns them into at most one scheduled fetch.
@MainActor
@Observable
final class ClaudeQuotaMonitor {
    private(set) var snapshot: ClaudeQuotaSnapshot?
    private(set) var lastError: ClaudeQuotaClientError?
    private(set) var scheduler: ClaudeQuotaScheduler
    private(set) var isExpanded = false

    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let fetcher: @Sendable () async throws -> ClaudeQuotaSnapshot
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// `defaults` is injectable so tests never flip the real setting — a
    /// stray enabled monitor would hit the keychain and block on its prompt.
    init(
        scheduler: ClaudeQuotaScheduler = ClaudeQuotaScheduler(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetcher: @escaping @Sendable () async throws -> ClaudeQuotaSnapshot = { try await ClaudeQuotaClient.fetch() }
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        self.fetcher = fetcher
        self.wasEnabled = defaults.bool(forKey: SettingsKey.showClaudeQuota)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reschedule() }
            })
        }
    }

    deinit {
        scheduledTask?.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    // MARK: Settings

    var isEnabled: Bool {
        defaults.bool(forKey: SettingsKey.showClaudeQuota)
    }

    var chipMode: ClaudeQuotaChipMode {
        ClaudeQuotaChipMode(rawValue: defaults.string(forKey: SettingsKey.claudeQuotaChip) ?? "") ?? .auto
    }

    /// The collapsed chip is on screen (setting-wise) — keeps the idle tick alive.
    var chipVisible: Bool { isEnabled && chipMode != .off }

    /// Something on screen shows the numbers right now.
    var wantsLive: Bool { isEnabled && (chipVisible || isExpanded) }

    /// Limit for the collapsed chip under the current mode, nil to hide it.
    func chipLimit(now: Date = Date()) -> ClaudeQuotaLimit? {
        guard chipVisible, let snapshot else { return nil }
        return ClaudeQuotaSelector.pick(from: snapshot, mode: chipMode, now: now)
    }

    // MARK: Events

    /// A local Claude Code turn finished — its usage is now booked server-side.
    func noteStop() {
        guard isEnabled else { return }
        scheduler.recordStop(now: now())
        reschedule()
    }

    func noteExpanded() {
        isExpanded = true
        guard isEnabled else { return }
        if scheduler.shouldFetchOnExpand(now: now()) {
            fetchNow()
        } else {
            reschedule()
        }
    }

    func noteCollapsed() {
        isExpanded = false
        reschedule()
    }

    @ObservationIgnored private var wasEnabled: Bool
    private func settingsChanged() {
        let enabled = isEnabled
        if enabled != wasEnabled {
            wasEnabled = enabled
            if !enabled {
                snapshot = nil
                lastError = nil
                scheduler = ClaudeQuotaScheduler(config: scheduler.config)
            }
        }
        reschedule()
    }

    // MARK: Scheduling

    private func reschedule() {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard let fireAt = scheduler.nextFireTime(wantsLive: wantsLive, now: now()) else { return }
        let delay = max(0, fireAt.timeIntervalSince(now()))
        scheduledTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.fireScheduled()
        }
    }

    private func fireScheduled() {
        // Asleep: skip; the wake observer reschedules.
        guard MascotAnimationGate.shared.isAwake else { return }
        guard wantsLive else { return }
        fetchNow()
    }

    /// Kick off one fetch immediately (respects an in-flight request).
    func fetchNow() {
        guard isEnabled, !inFlight else { return }
        inFlight = true
        scheduler.recordFetchStart(now: now())
        let fetcher = self.fetcher
        // The fetcher only suspends (URLSession); the keychain read, which can
        // block on the system access prompt, is hopped off-main inside it.
        Task { [weak self] in
            let result: Result<ClaudeQuotaSnapshot, Error>
            do { result = .success(try await fetcher()) } catch { result = .failure(error) }
            self?.apply(result)
        }
    }

    private func apply(_ result: Result<ClaudeQuotaSnapshot, Error>) {
        inFlight = false
        switch result {
        case .success(let snap):
            snapshot = snap
            lastError = nil
            scheduler.recordSuccess()
        case .failure(let error):
            let typed = (error as? ClaudeQuotaClientError) ?? .transport(error.localizedDescription)
            lastError = typed
            scheduler.recordFailure(unauthorized: typed == .unauthorized || typed == .noCredential)
        }
        reschedule()
    }
}

extension ClaudeQuotaMonitor {
    /// Debug harness / tests: inject a snapshot without any fetch.
    func applyPreview(_ snap: ClaudeQuotaSnapshot) {
        snapshot = snap
        lastError = nil
    }
}
