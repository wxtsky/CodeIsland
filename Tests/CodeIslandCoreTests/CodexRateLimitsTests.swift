import XCTest
@testable import CodeIslandCore

final class CodexRateLimitsTests: XCTestCase {
    private var home: String!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "codex-limits-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    /// Noon local time: "an hour ago" stays on today's date whenever the
    /// test runs.
    private var noon: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func tokenCountLine(at date: Date, primary: Double = 30, secondary: Double = 22,
                                primaryResets: Date? = nil, secondaryResets: Date? = nil,
                                primaryMinutes: Int = 300) -> String {
        let p = Int((primaryResets ?? date.addingTimeInterval(3600)).timeIntervalSince1970)
        let s = Int((secondaryResets ?? date.addingTimeInterval(3 * 86_400)).timeIntervalSince1970)
        return """
        {"timestamp":"\(iso(date))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primary),"window_minutes":\(primaryMinutes),"resets_at":\(p)},"secondary":{"used_percent":\(secondary),"window_minutes":10080,"resets_at":\(s)},"plan_type":"plus"}}}
        """
    }

    @discardableResult
    private func writeLog(_ lines: [String], day: Date, name: String = "rollout-a.jsonl", mtime: Date? = nil) throws -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let dir = String(format: "%@/sessions/%04d/%02d/%02d", home, c.year!, c.month!, c.day!)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + name
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        return path
    }

    func testParsesBothWindowsFromATokenCountLine() throws {
        let line = tokenCountLine(at: noon, primary: 30, secondary: 22)
        let reading = try XCTUnwrap(CodexRateLimits.parse(line: Data(line.utf8)))
        XCTAssertEqual(reading.limits.map(\.kind), [.session, .weeklyAll])
        XCTAssertEqual(reading.limits.map(\.percent), [30, 22])
        XCTAssertEqual(reading.limits[0].resetsAt, Date(timeIntervalSince1970: (noon.timeIntervalSince1970 + 3600).rounded(.down)))
        XCTAssertEqual(reading.planType, "plus")
        XCTAssertEqual(reading.observedAt.timeIntervalSince1970, noon.timeIntervalSince1970, accuracy: 0.001)
    }

    func testIgnoresOtherLinesAndUnknownWindowLengths() throws {
        XCTAssertNil(CodexRateLimits.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)))
        XCTAssertNil(CodexRateLimits.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#.utf8)))
        XCTAssertNil(CodexRateLimits.parse(line: Data("not json".utf8)))
        // A primary window that is not five hours is dropped; the weekly stays.
        let odd = try XCTUnwrap(CodexRateLimits.parse(line: Data(tokenCountLine(at: noon, primaryMinutes: 60).utf8)))
        XCTAssertEqual(odd.limits.map(\.kind), [.weeklyAll])
    }

    func testLatestReadingInAFileIsTheLastOne() throws {
        let path = try writeLog([
            tokenCountLine(at: noon.addingTimeInterval(-600), primary: 10),
            #"{"timestamp":"\#(iso(noon))","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#,
            tokenCountLine(at: noon.addingTimeInterval(-60), primary: 12),
            #"{"timestamp":"\#(iso(noon))","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
        ], day: noon)
        XCTAssertEqual(CodexRateLimits.latest(inFileAt: path)?.limits.first?.percent, 12)
    }

    func testTailReadWidensUntilItFindsAReading() throws {
        let filler = String(repeating: #"{"type":"response_item","payload":{"text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"#, count: 1)
        let path = try writeLog([tokenCountLine(at: noon, primary: 41)] + Array(repeating: filler, count: 400), day: noon)
        // ~30 KB of non-reading lines after the reading; a 1 KB tail must widen.
        XCTAssertEqual(CodexRateLimits.latest(inFileAt: path, tailBytes: 1024)?.limits.first?.percent, 41)
    }

    func testNewestReadingAcrossTodaysLogsWins() throws {
        try writeLog([tokenCountLine(at: noon.addingTimeInterval(-3600), primary: 50)], day: noon, name: "rollout-a.jsonl")
        try writeLog([tokenCountLine(at: noon.addingTimeInterval(-60), primary: 33)], day: noon, name: "rollout-b.jsonl")
        var cache = CodexRateLimits.FileCache()
        let reading = CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache)
        XCTAssertEqual(reading?.limits.first?.percent, 33)
    }

    func testYesterdaysLogCountsOnlyWhileWrittenToday() throws {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        let path = try writeLog([tokenCountLine(at: noon.addingTimeInterval(-60), primary: 61)], day: yesterday, mtime: noon)
        var cache = CodexRateLimits.FileCache()
        XCTAssertEqual(CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache)?.limits.first?.percent, 61)

        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: path)
        XCTAssertNil(CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache))
        XCTAssertTrue(cache.files.isEmpty)
    }

    func testCacheIsReusedUntilTheFileGrows() throws {
        let path = try writeLog([tokenCountLine(at: noon.addingTimeInterval(-120), primary: 20)], day: noon)
        var cache = CodexRateLimits.FileCache()
        XCTAssertEqual(CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache)?.limits.first?.percent, 20)

        // Same size, different contents: the cached reading stands.
        let sameSize = tokenCountLine(at: noon.addingTimeInterval(-120), primary: 21)
        try (sameSize + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: noon], ofItemAtPath: path)
        XCTAssertEqual(CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache)?.limits.first?.percent, 20)

        // Appended: re-read.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((tokenCountLine(at: noon.addingTimeInterval(-30), primary: 25) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(CodexRateLimits.read(codexHomes: [home], now: noon, calendar: calendar, cache: &cache)?.limits.first?.percent, 25)
    }

    func testNoLogsMeansNoReading() {
        var cache = CodexRateLimits.FileCache()
        XCTAssertNil(CodexRateLimits.read(codexHomes: [home + "/missing"], now: noon, calendar: calendar, cache: &cache))
    }

    func testAWindowPastItsResetReadsZero() {
        let reading = CodexRateLimits.Reading(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 80, resetsAt: noon.addingTimeInterval(-1)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 40, resetsAt: noon.addingTimeInterval(86_400)),
        ], observedAt: noon.addingTimeInterval(-7200))
        let snapshot = reading.snapshot(now: noon)
        XCTAssertEqual(snapshot.limit(.session)?.percent, 0)
        XCTAssertNil(snapshot.limit(.session)?.resetsAt)
        XCTAssertEqual(snapshot.limit(.weeklyAll)?.percent, 40)
        XCTAssertEqual(snapshot.fetchedAt, reading.observedAt)
    }
}
