import Foundation

// MARK: - Presence

/// Is anyone at this Mac? Every signal here is readable without a privacy
/// permission (CGSession dictionary, CGDisplayIsAsleep, CGEventSource idle
/// time, screen-saver notifications); the app gathers them, this decides.
public struct PushPresenceSnapshot: Equatable, Sendable {
    public var screenLocked: Bool
    public var screenSaverRunning: Bool
    public var displaysAsleep: Bool
    /// False when another user owns the console (fast user switching).
    public var sessionOnConsole: Bool
    /// Seconds since the last keyboard / mouse / trackpad event.
    public var idleSeconds: TimeInterval

    public init(
        screenLocked: Bool = false,
        screenSaverRunning: Bool = false,
        displaysAsleep: Bool = false,
        sessionOnConsole: Bool = true,
        idleSeconds: TimeInterval = 0
    ) {
        self.screenLocked = screenLocked
        self.screenSaverRunning = screenSaverRunning
        self.displaysAsleep = displaysAsleep
        self.sessionOnConsole = sessionOnConsole
        self.idleSeconds = idleSeconds
    }

    /// A locked or dark screen means away no matter how recent the last
    /// input was (⌃⌘Q locks instantly); otherwise, quiet hands for
    /// `idleThreshold` seconds.
    public func isAway(idleThreshold: TimeInterval) -> Bool {
        if screenLocked || screenSaverRunning || displaysAsleep || !sessionOnConsole { return true }
        return idleSeconds >= max(idleThreshold, 0)
    }
}

// MARK: - Gate

public enum PushSkipReason: String, Equatable, Sendable {
    /// "Only when I'm away" is on and the user is at the Mac.
    case userPresent
    /// The user is at the Mac and Smart Suppress kept the island quiet
    /// because the agent's own terminal is in front.
    case smartSuppressed
    /// A subagent's turn ended; the parent's completion is the one that matters.
    case subagent
    /// The user stopped the turn themselves (Esc / Ctrl-C).
    case interrupted
    /// Same session, same kind, moments ago.
    case duplicate
    /// The global cap on pushes that can wait (finished turns, errors,
    /// reminders) was reached (`PushThrottle.global`). Approvals and
    /// questions are never refused for volume.
    case rateLimited
    /// No enabled, configured channel takes this kind.
    case noChannel
    /// A reminder fired after its request was already answered.
    case nothingPending
}

public struct PushGateInput: Equatable, Sendable {
    public var kind: PushEventKind
    public var onlyWhenAway: Bool
    public var idleThreshold: TimeInterval
    public var presence: PushPresenceSnapshot
    public var smartSuppressed: Bool
    public var isSubagent: Bool
    public var interrupted: Bool

    public init(
        kind: PushEventKind,
        onlyWhenAway: Bool,
        idleThreshold: TimeInterval,
        presence: PushPresenceSnapshot,
        smartSuppressed: Bool = false,
        isSubagent: Bool = false,
        interrupted: Bool = false
    ) {
        self.kind = kind
        self.onlyWhenAway = onlyWhenAway
        self.idleThreshold = idleThreshold
        self.presence = presence
        self.smartSuppressed = smartSuppressed
        self.isSubagent = isSubagent
        self.interrupted = interrupted
    }
}

public enum PushGate {
    /// nil = send. Channel selection and dedupe come after this.
    ///
    /// Smart Suppress only counts while the user is present: it reads "the
    /// agent's terminal is frontmost", and a locked Mac keeps reporting the
    /// last frontmost app — exactly when the push matters most.
    public static func evaluate(_ input: PushGateInput) -> PushSkipReason? {
        if input.kind == .completion {
            if input.isSubagent { return .subagent }
            if input.interrupted { return .interrupted }
        }
        let away = input.presence.isAway(idleThreshold: input.idleThreshold)
        if input.onlyWhenAway && !away { return .userPresent }
        if !away && input.smartSuppressed { return .smartSuppressed }
        return nil
    }
}

// MARK: - Dedupe

public struct PushDeduplicator: Sendable {
    /// Same session + same kind (+ same request, for approvals and
    /// questions) inside this window is one moment: a question re-asked by
    /// a replayed hook, a Stop followed by the idle sweep's own completion.
    /// A different request of the same session is news — the approval that
    /// follows one answered on the iPhone a minute ago — and so is the same
    /// request once it was answered (`forget`).
    public var window: TimeInterval
    /// A completion right after an error in the same session is the same
    /// turn ending; the error already told the story.
    public var errorShadow: TimeInterval
    /// How long `lastSent(kind:sessionId:)` remembers a push.
    public var memory: TimeInterval

    private var lastSent: [String: Date] = [:]

    public init(
        window: TimeInterval = 60,
        errorShadow: TimeInterval = 60,
        memory: TimeInterval = 3_600
    ) {
        self.window = window
        self.errorShadow = errorShadow
        self.memory = memory
    }

    /// When a push of `kind` for `sessionId` was last admitted, within `memory`.
    public func lastSent(kind: PushEventKind, sessionId: String) -> Date? {
        lastSent[key(kind, sessionId)]
    }

    /// nil = admitted, and recorded as sent at `now`.
    ///
    /// - `requestKey`: which approval / question this is (a tool call id, or
    ///   a fingerprint of what is asked); nil for kinds that are about the
    ///   session as a whole.
    public mutating func admit(
        kind: PushEventKind,
        sessionId: String,
        requestKey: String? = nil,
        now: Date
    ) -> PushSkipReason? {
        prune(now: now)
        let slot = key(kind, sessionId, requestKey)
        if let last = lastSent[slot], now.timeIntervalSince(last) < window {
            return .duplicate
        }
        if kind == .completion,
           let error = lastSent[key(.error, sessionId)],
           now.timeIntervalSince(error) < errorShadow {
            return .duplicate
        }
        lastSent[slot] = now
        return nil
    }

    /// The request was answered: its next push is news, not a repeat.
    public mutating func forget(kind: PushEventKind, sessionId: String, requestKey: String?) {
        lastSent[key(kind, sessionId, requestKey)] = nil
    }

    private func key(_ kind: PushEventKind, _ sessionId: String, _ requestKey: String? = nil) -> String {
        guard let requestKey, !requestKey.isEmpty else { return "\(kind.rawValue)|\(sessionId)" }
        return "\(kind.rawValue)|\(sessionId)|\(requestKey)"
    }

    /// Keeps the table bounded by time rather than by session count.
    private mutating func prune(now: Date) {
        let horizon = max(window, errorShadow, memory)
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < horizon }
    }
}

// MARK: - Rate limits

/// At most `count` sends in any rolling `seconds`.
public struct PushRateWindow: Equatable, Sendable {
    public var count: Int
    public var seconds: TimeInterval

    public init(count: Int, seconds: TimeInterval) {
        self.count = count
        self.seconds = seconds
    }
}

/// Sliding-window limiter: when the next send fits every window.
public struct PushRateLimiter: Sendable {
    public let windows: [PushRateWindow]
    private var sends: [Date] = []

    public init(windows: [PushRateWindow]) {
        self.windows = windows
    }

    /// The earliest moment at or after `now` the next send fits every window.
    public func nextSlot(now: Date) -> Date {
        var slot = now
        for window in windows where window.count > 0 {
            let recent = sends.filter { now.timeIntervalSince($0) < window.seconds }.sorted()
            guard recent.count >= window.count else { continue }
            // Room opens when enough of the recent sends age out of the window.
            let frees = recent[recent.count - window.count].addingTimeInterval(window.seconds)
            slot = max(slot, frees)
        }
        return slot
    }

    public mutating func record(_ date: Date) {
        let horizon = windows.map(\.seconds).max() ?? 0
        sends.removeAll { date.timeIntervalSince($0) >= horizon }
        sends.append(date)
    }
}

public enum PushThrottle {
    /// Across all channels and sessions: finished turns, errors and
    /// reminders past it are dropped — a flood of them says less than one.
    public static let global = PushRateWindow(count: 12, seconds: 60)

    /// Approvals and questions keep an agent blocked until someone answers:
    /// never refused by the global cap, and queued (not dropped) when a team
    /// chat's own limit is reached.
    public static func mustDeliver(_ kind: PushEventKind) -> Bool {
        kind == .permission || kind == .question
    }

    /// A push that can be dropped still waits this long for a team chat's
    /// slot — per-second limits (Feishu, Slack) free up that fast.
    public static let dropGrace: TimeInterval = 5
}

extension PushChannelKind {
    /// What the service allows one incoming webhook, with some headroom:
    /// exceeding it gets messages rejected (Feishu, Slack) or the robot
    /// silenced for 10 minutes (DingTalk). Personal channels have none worth
    /// throttling at this volume.
    ///
    /// - DingTalk: 20 messages a minute per robot.
    /// - WeCom: 20 messages a minute per robot.
    /// - Feishu / Lark custom bot: 100 a minute, 5 a second.
    /// - Slack incoming webhook: 1 a second.
    public var rateLimits: [PushRateWindow] {
        switch self {
        case .dingtalk, .wecom: return [PushRateWindow(count: 18, seconds: 60)]
        case .feishu: return [PushRateWindow(count: 90, seconds: 60), PushRateWindow(count: 4, seconds: 1)]
        case .slack: return [PushRateWindow(count: 1, seconds: 1)]
        case .bark, .ntfy, .telegram: return []
        }
    }
}

// MARK: - Classification

public struct PushSessionError: Equatable, Sendable {
    public var type: String?
    public var detail: String?

    public init(type: String?, detail: String?) {
        self.type = type
        self.detail = detail
    }
}

public enum PushEventClassifier {
    /// The error a hook reports when a session stopped on one, or nil.
    ///
    /// - `StopFailure` (Claude Code; Grok as `StopFailure` / `stop_failure`):
    ///   `error` is the class ("rate_limit"), `last_assistant_message` the
    ///   rendered text ("API Error: Rate limit reached"), `error_details`
    ///   extra context. The normalizer folds it onto Stop, so it is matched
    ///   on the raw name.
    /// - Copilot `errorOccurred` / `ErrorOccurred`: `error: {message, name}`
    ///   plus `recoverable`; a recoverable error does not stop the session.
    public static func sessionError(eventName: String, raw: [String: Any]) -> PushSessionError? {
        switch eventName {
        case "StopFailure", "stop_failure":
            let type = text(raw["error"])
            let detail = text(raw["last_assistant_message"]) ?? text(raw["error_details"]) ?? text(raw["message"])
            return PushSessionError(type: type, detail: detail)
        case "errorOccurred", "ErrorOccurred":
            if raw["recoverable"] as? Bool == true { return nil }
            let error = raw["error"] as? [String: Any]
            let type = text(error?["name"])
            let detail = text(error?["message"]) ?? text(raw["error"])
            return PushSessionError(type: type, detail: detail)
        default:
            return nil
        }
    }

    /// Whether a completion belongs to a subagent rather than the
    /// conversation the user started: an explicit subagent id, a Codex
    /// child folded into its parent, or a Cursor Task card kept separate.
    public static func isSubagentCompletion(
        agentId: String?,
        raw: [String: Any],
        sessionId: String,
        session: SessionSnapshot?
    ) -> Bool {
        if let agentId, !agentId.isEmpty { return true }
        if raw["_codex_subagent"] as? Bool == true { return true }
        if CatPawHookPayload.isSource(session?.source ?? raw["_source"] as? String),
           session?.catpawIsSubagent == true || raw["is_sub_agent"] as? Bool == true { return true }
        guard let session, CursorSubsessionRouter.isCursorFamilySource(session.source) else { return false }
        return CursorSubsessionRouter.isLikelyCursorTaskCard(
            sessionId: sessionId,
            providerSessionId: session.providerSessionId,
            transcriptPath: session.transcriptPath
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
