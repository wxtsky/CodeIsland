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

    public init(kind: Kind, percent: Double, severity: String = "normal", resetsAt: Date? = nil, scopeLabel: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scopeLabel = scopeLabel
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

    /// Below this share of the window elapsed the pace readout is hidden:
    /// any early burst looks far ahead of pace, so the number means nothing.
    public static let paceMinElapsed: Double = 0.10
    /// Within this many points of even pace the readout is neutral.
    public static let paceNeutralPoints: Double = 5

    /// How this window's usage compares with spending it evenly.
    public struct Pace: Equatable, Sendable {
        public enum Tone: Sendable { case neutral, ahead, behind }
        /// Used share minus elapsed share, in percentage points
        /// (+ = burning faster than even pace).
        public let points: Double
        /// `points` as window time: how much of the window's budget is used
        /// ahead of (+) or behind (−) schedule.
        public let duration: TimeInterval
        /// Percent the window reaches at reset if the current rate holds.
        public let projectedPercent: Double
        /// Time until 100% at the current rate; nil if the window resets
        /// first or is already at its limit.
        public let exhaustsIn: TimeInterval?
        public let tone: Tone
    }

    /// Pace readout, or nil without a reset time or this early in the window.
    public func pace(now: Date = Date()) -> Pace? {
        guard resetsAt != nil, let elapsed = elapsedFraction(now: now),
              elapsed >= Self.paceMinElapsed else { return nil }
        let points = percent - elapsed * 100
        let rounded = points.rounded()
        let tone: Pace.Tone = abs(rounded) <= Self.paceNeutralPoints ? .neutral : (rounded > 0 ? .ahead : .behind)
        let projected = percent / elapsed
        var exhaustsIn: TimeInterval?
        if percent < 100, projected > 100 {
            // percent per second so far; the rest of the budget at that rate.
            let rate = percent / (elapsed * kind.windowSeconds)
            exhaustsIn = (100 - percent) / rate
        }
        return Pace(
            points: points,
            duration: points / 100 * kind.windowSeconds,
            projectedPercent: projected,
            exhaustsIn: exhaustsIn,
            tone: tone
        )
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
                    scopeLabel: scopeLabel
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
    /// Weekly budget by default; the 5-hour window only when it is blocking,
    /// or a weekly in surplus late in the week (see `ClaudeQuotaSelector`).
    case auto
    case session
    case weeklyAll
    case weeklyScoped
}

public enum ClaudeQuotaSelector {
    /// Usage at or above this share counts as pressing regardless of pace.
    public static let alertPercent: Double = 80

    /// Session takeover floor: below this usage the 5-hour window's pace is
    /// noise — any burst early in the window looks "ahead of pace".
    public static let sessionMinPercent: Double = 50
    /// Session takeover margin: how far ahead of pace (as a fraction) the
    /// 5-hour window must be to count as blocking — 0.10 means ten points
    /// more used than elapsed.
    public static let sessionPaceMargin: Double = 0.10
    /// Weekly surplus margin: this far behind pace (as a fraction) means the
    /// budget would mostly expire unused — worth surfacing so it can be spent.
    public static let surplusPaceMargin: Double = 0.25
    /// Weekly surplus only counts once this fraction of the week has elapsed;
    /// earlier, low usage means "not started", not "plenty left".
    public static let surplusMinElapsed: Double = 0.5

    /// Pick the limit for the collapsed chip. Fixed modes return that window,
    /// or nil if the server didn't report it.
    ///
    /// `auto` — the weekly budget is the default face of the chip; everything
    /// else is an interruption that must earn it, in urgency order:
    /// 1. The 5-hour window takes the chip only when genuinely blocking
    ///    (`sessionIsBlocking`) — it is the one that can stop you within the
    ///    hour.
    /// 2. Otherwise a weekly window: a pressing one first; failing that, one
    ///    with a surplus worth burning before it resets; failing that, the
    ///    one with more used (the tighter budget). Weekly (all models) and
    ///    weekly (current model) compete on the same terms.
    /// 3. With no weekly reported, the 5-hour window is all there is.
    ///
    /// "Pressing" = used share exceeds the elapsed share of the window
    /// (ahead of pace), or usage is at or past `alertPercent`.
    public static func pick(from snapshot: ClaudeQuotaSnapshot, mode: ClaudeQuotaChipMode, now: Date = Date()) -> ClaudeQuotaLimit? {
        switch mode {
        case .off: return nil
        case .session: return snapshot.limit(.session)
        case .weeklyAll: return snapshot.limit(.weeklyAll)
        case .weeklyScoped: return snapshot.limit(.weeklyScoped)
        case .auto:
            let session = snapshot.limit(.session)
            if let session, sessionIsBlocking(session, now: now) { return session }
            let weeklies = [snapshot.limit(.weeklyAll), snapshot.limit(.weeklyScoped)].compactMap { $0 }
            return pickWeekly(weeklies, now: now) ?? session
        }
    }

    public static func isPressing(_ limit: ClaudeQuotaLimit, now: Date = Date()) -> Bool {
        limit.percent >= alertPercent || limit.paceDelta(now: now) > 0
    }

    /// The 5-hour window takes the chip only when it can genuinely block
    /// soon: past `sessionMinPercent` and ahead of pace by more than
    /// `sessionPaceMargin`. A window about to reset no longer qualifies —
    /// being blocked for its last ten minutes is not worth the chip.
    public static func sessionIsBlocking(_ limit: ClaudeQuotaLimit, now: Date = Date()) -> Bool {
        limit.percent > sessionMinPercent && limit.paceDelta(now: now) > sessionPaceMargin
    }

    /// A weekly window with plenty of budget left late in the week — the
    /// use-it-or-lose-it case. Session windows never count: they reset
    /// every few hours, so "surplus" is meaningless for them.
    public static func isSurplus(_ limit: ClaudeQuotaLimit, now: Date = Date()) -> Bool {
        guard limit.kind != .session,
              let elapsed = limit.elapsedFraction(now: now), elapsed >= surplusMinElapsed
        else { return false }
        return limit.paceDelta(now: now) <= -surplusPaceMargin
    }

    /// Among the weekly windows: the one furthest ahead of pace if any is
    /// pressing; else the one most behind pace if any is in surplus; else
    /// the one with the most used.
    static func pickWeekly(_ weeklies: [ClaudeQuotaLimit], now: Date) -> ClaudeQuotaLimit? {
        let pressing = weeklies.filter { isPressing($0, now: now) }
        if !pressing.isEmpty {
            return pressing.max { $0.paceDelta(now: now) < $1.paceDelta(now: now) }
        }
        let surplus = weeklies.filter { isSurplus($0, now: now) }
        if !surplus.isEmpty {
            return surplus.min { $0.paceDelta(now: now) < $1.paceDelta(now: now) }
        }
        return weeklies.max { $0.percent < $1.percent }
    }
}

public enum ClaudeQuotaFormat {
    /// "2d 4h" / "1h20m" / "45m" (minutes round up, so 30s shows "1m");
    /// nil once the reset time has passed.
    public static func countdown(until resetsAt: Date, now: Date = Date()) -> String? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard Int(remaining.rounded(.down)) > 0 else { return nil }
        return duration(remaining)
    }

    /// Countdown-style length of any span, sign dropped: "2d 17h" / "1h36m" / "47m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(abs(seconds).rounded(.down)), 1)
        let minutes = (total + 59) / 60
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

    /// Signed pace points: "+32" / "−39" / "±0". U+2212 so the minus is as
    /// long as the plus rather than a hyphen.
    public static func paceDelta(_ points: Double) -> String {
        let n = Int(points.rounded())
        if n == 0 { return "\u{00B1}0" }
        return n > 0 ? "+\(n)" : "\u{2212}\(-n)"
    }
}
