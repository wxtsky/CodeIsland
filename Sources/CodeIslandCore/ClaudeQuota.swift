import Foundation

/// One rate-limit window from Anthropic's subscription usage endpoint —
/// the same numbers Claude Code's `/usage` shows.
public struct ClaudeQuotaLimit: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Rolling 5-hour window.
        case session
        /// 7-day window across all models.
        case weeklyAll = "weekly_all"
        /// 7-day window scoped to one model (e.g. the plan's flagship model).
        case weeklyScoped = "weekly_scoped"

        public var windowSeconds: TimeInterval {
            switch self {
            case .session: return 5 * 3600
            case .weeklyAll, .weeklyScoped: return 7 * 86_400
            }
        }
    }

    public let kind: Kind
    /// 0…100 (may exceed 100 when the account is over its limit).
    public let percent: Double
    /// Server-side severity, e.g. "normal" / "warning" / "critical". Free-form.
    public let severity: String
    public let resetsAt: Date?
    /// Model display name for `.weeklyScoped` ("Fable", "Opus", …), nil otherwise.
    public let scopeLabel: String?
    /// Server hint that this is the currently governing limit.
    public let isActive: Bool

    public init(kind: Kind, percent: Double, severity: String = "normal", resetsAt: Date? = nil, scopeLabel: String? = nil, isActive: Bool = false) {
        self.kind = kind
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scopeLabel = scopeLabel
        self.isActive = isActive
    }

    /// Fraction of the window already elapsed (0…1), derived from `resetsAt`.
    /// nil when the server gave no reset time.
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = 1 - remaining / kind.windowSeconds
        return min(max(elapsed, 0), 1)
    }

    /// How far ahead of pace this window is: used fraction minus elapsed
    /// fraction. Positive means the limit will be hit before it resets if
    /// usage continues at the same rate. Falls back to the used fraction when
    /// there is no reset time, so windows stay comparable.
    public func paceDelta(now: Date = Date()) -> Double {
        let used = percent / 100
        guard let elapsed = elapsedFraction(now: now) else { return used }
        return used - elapsed
    }

    public var isOverLimit: Bool { percent >= 100 }

    /// Severity bucket for colouring; tolerant of unknown server strings.
    public enum Level: Sendable { case normal, warning, critical }
    public var level: Level {
        if isOverLimit { return .critical }
        switch severity.lowercased() {
        case "normal", "": return .normal
        case "warning", "warn", "elevated": return .warning
        default: return .critical
        }
    }
}

public struct ClaudeQuotaSnapshot: Equatable, Sendable {
    public let limits: [ClaudeQuotaLimit]
    public let fetchedAt: Date

    public init(limits: [ClaudeQuotaLimit], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { limits.isEmpty }
    public func limit(_ kind: ClaudeQuotaLimit.Kind) -> ClaudeQuotaLimit? {
        limits.first { $0.kind == kind }
    }

    /// Display order: 5h, weekly, weekly (model).
    public var ordered: [ClaudeQuotaLimit] {
        ClaudeQuotaLimit.Kind.allCases.compactMap { limit($0) }
    }

    public enum ParseError: Error, Equatable { case notJSON, noLimits }

    /// Parse the `/api/oauth/usage` response. Prefers the normalised `limits[]`
    /// array; falls back to the legacy top-level `five_hour` / `seven_day*`
    /// objects so accounts that only get those still render.
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> ClaudeQuotaSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        var limits: [ClaudeQuotaLimit] = []
        if let raw = obj["limits"] as? [[String: Any]] {
            for item in raw {
                guard let kindRaw = item["kind"] as? String,
                      let kind = ClaudeQuotaLimit.Kind(rawValue: kindRaw),
                      let percent = number(item["percent"]) else { continue }
                var scopeLabel: String?
                if let scope = item["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any] {
                    scopeLabel = model["display_name"] as? String ?? model["id"] as? String
                }
                limits.append(ClaudeQuotaLimit(
                    kind: kind,
                    percent: percent,
                    severity: item["severity"] as? String ?? "normal",
                    resetsAt: date(item["resets_at"]),
                    scopeLabel: scopeLabel,
                    isActive: item["is_active"] as? Bool ?? false
                ))
            }
        }
        if limits.isEmpty {
            func legacy(_ key: String, _ kind: ClaudeQuotaLimit.Kind, label: String? = nil) {
                guard let item = obj[key] as? [String: Any], let util = number(item["utilization"]) else { return }
                limits.append(ClaudeQuotaLimit(kind: kind, percent: util, resetsAt: date(item["resets_at"]), scopeLabel: label))
            }
            legacy("five_hour", .session)
            legacy("seven_day", .weeklyAll)
            legacy("seven_day_opus", .weeklyScoped, label: "Opus")
            if limits.first(where: { $0.kind == .weeklyScoped }) == nil {
                legacy("seven_day_sonnet", .weeklyScoped, label: "Sonnet")
            }
        }
        // One entry per kind, first wins.
        var seen = Set<ClaudeQuotaLimit.Kind>()
        limits = limits.filter { seen.insert($0.kind).inserted }
        guard !limits.isEmpty else { throw ParseError.noLimits }
        return ClaudeQuotaSnapshot(limits: limits, fetchedAt: fetchedAt)
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }
}

/// What the collapsed island shows when plan limits are enabled.
public enum ClaudeQuotaChipMode: String, CaseIterable, Sendable {
    case off
    /// The window most likely to run out first (see `ClaudeQuotaSelector`).
    case auto
    case session
    case weeklyAll
    case weeklyScoped
}

public enum ClaudeQuotaSelector {
    /// 5h usage at or above this share always takes the chip in `auto`.
    public static let sessionAlertPercent: Double = 70

    /// Pick the limit for the collapsed chip. Fixed modes return that window,
    /// or nil if the server didn't report it.
    ///
    /// `auto` shows the weekly budget by default — the tighter of the two
    /// weekly windows — because that is the one that runs out for days. The
    /// 5-hour window takes over only while it is the pressing one: running
    /// ahead of pace (used share exceeds elapsed share) or past
    /// `sessionAlertPercent`.
    public static func pick(from snapshot: ClaudeQuotaSnapshot, mode: ClaudeQuotaChipMode, now: Date = Date()) -> ClaudeQuotaLimit? {
        switch mode {
        case .off: return nil
        case .session: return snapshot.limit(.session)
        case .weeklyAll: return snapshot.limit(.weeklyAll)
        case .weeklyScoped: return snapshot.limit(.weeklyScoped)
        case .auto:
            let session = snapshot.limit(.session)
            let weekly = [snapshot.limit(.weeklyAll), snapshot.limit(.weeklyScoped)]
                .compactMap { $0 }
                .max { $0.percent < $1.percent }
            if let session, sessionIsPressing(session, now: now) { return session }
            return weekly ?? session
        }
    }

    public static func sessionIsPressing(_ session: ClaudeQuotaLimit, now: Date = Date()) -> Bool {
        session.percent >= sessionAlertPercent || session.paceDelta(now: now) > 0
    }
}

public enum ClaudeQuotaFormat {
    /// "2d 4h" / "1h20m" / "45m" (minutes round up, so 30s shows "1m");
    /// nil once the reset time has passed.
    public static func countdown(until resetsAt: Date, now: Date = Date()) -> String? {
        let remaining = Int(resetsAt.timeIntervalSince(now).rounded(.down))
        guard remaining > 0 else { return nil }
        let minutes = (remaining + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h\(String(format: "%02d", m))m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
