import Foundation

/// Codex's plan limits (the 5-hour and weekly windows `/status` shows), read
/// from Codex's own session logs — local files only, no network. Every
/// `token_count` event Codex writes to `<CODEX_HOME>/sessions/YYYY/MM/DD/
/// rollout-*.jsonl` carries the latest `rate_limits` it got from its server,
/// so the newest such event across today's logs is the current reading.
///
/// The windows reuse `ClaudeQuotaLimit` so the footer draws them exactly like
/// Claude's: same bar, colours, countdown and pace.
public enum CodexRateLimits {
    public struct Reading: Equatable, Sendable {
        /// 5h first, then weekly; windows of any other length are left out
        /// (`ClaudeQuotaLimit.Kind` derives pace from a fixed window length).
        public let limits: [ClaudeQuotaLimit]
        /// When Codex logged the event — how fresh the numbers are.
        public let observedAt: Date
        /// "plus", "pro", "team", … as Codex reports it.
        public let planType: String?

        public init(limits: [ClaudeQuotaLimit], observedAt: Date, planType: String? = nil) {
            self.limits = limits
            self.observedAt = observedAt
            self.planType = planType
        }

        /// The reading as a footer snapshot at `now`: a window whose reset
        /// time has passed has started over, so it reads 0% with no reset
        /// time rather than the previous window's number.
        public func snapshot(now: Date = Date()) -> ClaudeQuotaSnapshot {
            let current = limits.map { limit in
                limit.hasReset(now: now) ? ClaudeQuotaLimit(kind: limit.kind, percent: 0) : limit
            }
            return ClaudeQuotaSnapshot(limits: current, fetchedAt: observedAt)
        }
    }

    // MARK: Parsing

    /// One JSONL line → a reading, when it is a `token_count` event with at
    /// least one 5h or weekly window.
    public static func parse(line: Data) -> Reading? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let observedAt = ClaudeQuotaSnapshot.date(obj["timestamp"]) else { return nil }
        var limits: [ClaudeQuotaLimit] = []
        for (key, fallback) in [("primary", ClaudeQuotaLimit.Kind.session), ("secondary", .weeklyAll)] {
            guard let window = rateLimits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let kind: ClaudeQuotaLimit.Kind
            switch (window["window_minutes"] as? NSNumber)?.intValue {
            case nil: kind = fallback
            case 300: kind = .session
            case 10_080: kind = .weeklyAll
            default: continue
            }
            guard !limits.contains(where: { $0.kind == kind }) else { continue }
            let resetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            limits.append(ClaudeQuotaLimit(kind: kind, percent: used, resetsAt: resetsAt))
        }
        guard !limits.isEmpty else { return nil }
        limits.sort { $0.kind == .session && $1.kind != .session }
        return Reading(limits: limits, observedAt: observedAt, planType: rateLimits["plan_type"] as? String)
    }

    /// The last reading in a log's contents.
    public static func latest(in data: Data) -> Reading? {
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let reading = parse(line: Data(line)) { return reading }
        }
        return nil
    }

    /// The last reading in a log file. Logs grow to megabytes over a long
    /// session and the reading sits near the end, so this reads the tail and
    /// widens only while no reading turns up.
    public static func latest(inFileAt path: String, tailBytes: Int = 64 * 1024) -> Reading? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var window = UInt64(max(tailBytes, 1))
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  var data = try? handle.readToEnd() else { return nil }
            // Mid-file, the first line is cut; drop it.
            if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            }
            if let reading = latest(in: data) { return reading }
            if start == 0 { return nil }
            window *= 4
        }
    }

    // MARK: Files

    /// Per-file readings keyed by path, reused while a file's size is
    /// unchanged — a log only grows, so the same size means nothing new.
    /// Value semantics: the caller owns a copy, hands it to the background
    /// read and keeps the returned state.
    public struct FileCache: Sendable {
        struct Entry: Sendable {
            let size: UInt64
            let reading: Reading?
        }
        var files: [String: Entry] = [:]
        public init() {}
    }

    /// Today's logs under each Codex home, plus yesterday's still written to
    /// today (a session that started before midnight keeps its first day's
    /// folder).
    public static func candidateFiles(
        codexHomes: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let fm = FileManager.default
        let dayStart = calendar.startOfDay(for: now)
        var days = [dayStart]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart) { days.append(yesterday) }
        var paths: [String] = []
        for home in codexHomes {
            for day in days {
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                let dir = String(format: "%@/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                    let path = dir + "/" + name
                    guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                          mtime >= dayStart else { continue }
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// The newest reading across today's logs, or nil when Codex has logged
    /// none today. Blocking file IO: call off the main thread.
    public static func read(
        codexHomes: [String],
        now: Date = Date(),
        calendar: Calendar = .current,
        cache: inout FileCache
    ) -> Reading? {
        let paths = candidateFiles(codexHomes: codexHomes, now: now, calendar: calendar)
        var newest: Reading?
        var kept: [String: FileCache.Entry] = [:]
        for path in paths {
            guard let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
            else { continue }
            let entry: FileCache.Entry
            if let cached = cache.files[path], cached.size == size {
                entry = cached
            } else {
                entry = FileCache.Entry(size: size, reading: latest(inFileAt: path))
            }
            kept[path] = entry
            if let reading = entry.reading, reading.observedAt > (newest?.observedAt ?? .distantPast) {
                newest = reading
            }
        }
        // Yesterday's files drop out of the cache once they stop counting.
        cache.files = kept
        return newest
    }
}
