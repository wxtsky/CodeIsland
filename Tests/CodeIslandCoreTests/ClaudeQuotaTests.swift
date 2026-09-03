import XCTest
@testable import CodeIslandCore

final class ClaudeQuotaTests: XCTestCase {
    /// Trimmed copy of a real `/api/oauth/usage` response (Max plan, 2026-09-03).
    static let fixture = """
    {"five_hour":{"utilization":3.0,"resets_at":"2026-09-03T19:50:00.017533+00:00"},
     "seven_day":{"utilization":30.0,"resets_at":"2026-09-04T00:00:00.017553+00:00"},
     "seven_day_opus":null,
     "limits":[
       {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-09-03T19:50:00.017533+00:00","scope":null,"is_active":false},
       {"kind":"weekly_all","group":"weekly","percent":30,"severity":"normal","resets_at":"2026-09-04T00:00:00.017553+00:00","scope":null,"is_active":false},
       {"kind":"weekly_scoped","group":"weekly","percent":48,"severity":"normal","resets_at":"2026-09-04T00:00:00.017765+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true},
       {"kind":"something_new","percent":1}
     ]}
    """.data(using: .utf8)!

    private let now = ISO8601DateFormatter().date(from: "2026-09-03T15:00:00Z")!

    func testParsesNormalisedLimitsAndIgnoresUnknownKinds() throws {
        let snap = try ClaudeQuotaSnapshot.parse(Self.fixture, fetchedAt: now)
        XCTAssertEqual(snap.limits.count, 3)
        XCTAssertEqual(snap.ordered.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        let scoped = try XCTUnwrap(snap.limit(.weeklyScoped))
        XCTAssertEqual(scoped.percent, 48)
        XCTAssertEqual(scoped.scopeLabel, "Fable")
        XCTAssertTrue(scoped.isActive)
        let resets = try XCTUnwrap(snap.limit(.session)?.resetsAt)
        XCTAssertEqual(resets.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-09-03T19:50:00Z")!.timeIntervalSince1970, accuracy: 0.1)
    }

    func testFallsBackToLegacyFieldsWhenLimitsMissing() throws {
        let json = """
        {"five_hour":{"utilization":12.5,"resets_at":"2026-09-03T19:50:00Z"},
         "seven_day":{"utilization":70,"resets_at":null},
         "seven_day_sonnet":{"utilization":5,"resets_at":null}}
        """.data(using: .utf8)!
        let snap = try ClaudeQuotaSnapshot.parse(json, fetchedAt: now)
        XCTAssertEqual(snap.limit(.session)?.percent, 12.5)
        XCTAssertEqual(snap.limit(.weeklyAll)?.percent, 70)
        XCTAssertNil(snap.limit(.weeklyAll)?.resetsAt)
        XCTAssertEqual(snap.limit(.weeklyScoped)?.scopeLabel, "Sonnet")
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try ClaudeQuotaSnapshot.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try ClaudeQuotaSnapshot.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ClaudeQuotaSnapshot.ParseError, .noLimits)
        }
    }

    // MARK: pace + selector

    func testElapsedFractionDerivesFromResetTime() {
        // 5h window, resets in 4h → 20% elapsed.
        let limit = ClaudeQuotaLimit(kind: .session, percent: 40, resetsAt: now.addingTimeInterval(4 * 3600))
        XCTAssertEqual(limit.elapsedFraction(now: now)!, 0.2, accuracy: 0.001)
        XCTAssertEqual(limit.paceDelta(now: now), 0.2, accuracy: 0.001)
        // Past reset clamps to 1.
        let stale = ClaudeQuotaLimit(kind: .session, percent: 40, resetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(stale.elapsedFraction(now: now), 1)
    }

    func testAutoShowsTighterWeeklyWindowByDefault() {
        // 5h at 20% with 2.5h left is behind pace → weekly wins. Both weeklies
        // behind pace (1 day of 7 left, so 86% elapsed) → the one with more used.
        let snap = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 20, resetsAt: now.addingTimeInterval(2.5 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30, resetsAt: now.addingTimeInterval(86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 48, resetsAt: now.addingTimeInterval(86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: snap, mode: .auto, now: now)?.kind, .weeklyScoped)
        let allTighter = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 10, scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: allTighter, mode: .auto, now: now)?.kind, .weeklyAll)
    }

    func testAutoPrefersTheWeeklyWindowAheadOfPace() {
        // Weekly-all has more used but is behind pace (1 day left → 86%
        // elapsed, 40% used); Fable is ahead of pace (6 days left → 14%
        // elapsed, 25% used) → Fable.
        let fableAhead = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 5, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 40, resetsAt: now.addingTimeInterval(86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 25, resetsAt: now.addingTimeInterval(6 * 86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: fableAhead, mode: .auto, now: now)?.kind, .weeklyScoped)
        // Both ahead of pace (6 days left, 14% elapsed): the one further ahead wins, not the higher percent.
        let bothAhead = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30, resetsAt: now.addingTimeInterval(6 * 86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 28, resetsAt: now.addingTimeInterval(6.5 * 86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        // weekly-all: 0.30 - 0.143 = 0.157; Fable: 0.28 - 0.071 = 0.209 → Fable.
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: bothAhead, mode: .auto, now: now)?.kind, .weeklyScoped)
        // A weekly past the alert line is pressing even when behind pace.
        let hotWeekly = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 85, resetsAt: now.addingTimeInterval(3600)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 20, resetsAt: now.addingTimeInterval(3600), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: hotWeekly, mode: .auto, now: now)?.kind, .weeklyAll)
    }

    func testAutoSwitchesToSessionWhenAheadOfPaceOrPastThreshold() {
        // 40% used with 4h of 5h left → 20% elapsed → ahead of pace.
        let ahead = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 40, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: ahead, mode: .auto, now: now)?.kind, .session)
        // 82% used with 10 minutes left is behind pace but past the 80% alert line.
        let hot = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 82, resetsAt: now.addingTimeInterval(600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 10, resetsAt: now.addingTimeInterval(86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: hot, mode: .auto, now: now)?.kind, .session)
        // 75% with 10 minutes left: behind pace and under the line → weekly stays.
        let warm = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 75, resetsAt: now.addingTimeInterval(600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 10, resetsAt: now.addingTimeInterval(86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: warm, mode: .auto, now: now)?.kind, .weeklyAll)
        // No weekly reported at all → session is all there is.
        let only = ClaudeQuotaSnapshot(limits: [ClaudeQuotaLimit(kind: .session, percent: 5)], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: only, mode: .auto, now: now)?.kind, .session)
    }

    func testFixedModesReturnThatWindowOrNil() throws {
        let snap = try ClaudeQuotaSnapshot.parse(Self.fixture, fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: snap, mode: .session)?.kind, .session)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: snap, mode: .weeklyAll)?.kind, .weeklyAll)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: snap, mode: .weeklyScoped)?.scopeLabel, "Fable")
        XCTAssertNil(ClaudeQuotaSelector.pick(from: snap, mode: .off))
        let noScoped = ClaudeQuotaSnapshot(limits: [ClaudeQuotaLimit(kind: .session, percent: 1)], fetchedAt: now)
        XCTAssertNil(ClaudeQuotaSelector.pick(from: noScoped, mode: .weeklyScoped))
    }

    // MARK: formatting + levels

    func testCountdownFormats() {
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(30), now: now), "1m")
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(80 * 60), now: now), "1h20m")
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(3 * 3600), now: now), "3h")
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(2 * 86_400 + 4 * 3600), now: now), "2d 4h")
        XCTAssertEqual(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(7 * 86_400), now: now), "7d")
        XCTAssertNil(ClaudeQuotaFormat.countdown(until: now.addingTimeInterval(-1), now: now))
        XCTAssertEqual(ClaudeQuotaFormat.percent(47.6), "48%")
    }

    func testSeverityLevels() {
        XCTAssertEqual(ClaudeQuotaLimit(kind: .session, percent: 10, severity: "normal").level, .normal)
        XCTAssertEqual(ClaudeQuotaLimit(kind: .session, percent: 10, severity: "warning").level, .warning)
        XCTAssertEqual(ClaudeQuotaLimit(kind: .session, percent: 10, severity: "exceeded").level, .critical)
        XCTAssertEqual(ClaudeQuotaLimit(kind: .session, percent: 100, severity: "normal").level, .critical)
    }

    // MARK: credential + client

    func testCredentialParse() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1788472382000,"subscriptionType":"max"}}
        """.data(using: .utf8)!
        let cred = try XCTUnwrap(ClaudeCredentialStore.parse(json))
        XCTAssertEqual(cred.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(cred.subscriptionType, "max")
        XCTAssertEqual(cred.expiresAt?.timeIntervalSince1970, 1_788_472_382)
        XCTAssertNil(ClaudeCredentialStore.parse(Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)))
    }

    func testRequestCarriesBearerAndBetaHeader() {
        let req = ClaudeQuotaClient.request(token: "tok")
        XCTAssertEqual(req.url, ClaudeQuotaClient.endpoint)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: ClaudeQuotaClient.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testInterpretMapsStatusCodes() {
        XCTAssertNoThrow(try ClaudeQuotaClient.interpret(data: Self.fixture, response: response(200)))
        func err(_ status: Int, _ data: Data = Data()) -> ClaudeQuotaClientError? {
            do { _ = try ClaudeQuotaClient.interpret(data: data, response: response(status)); return nil }
            catch { return error as? ClaudeQuotaClientError }
        }
        XCTAssertEqual(err(401), .unauthorized)
        XCTAssertEqual(err(403), .unauthorized)
        XCTAssertEqual(err(429), .rateLimited)
        XCTAssertEqual(err(503), .http(503))
        XCTAssertEqual(err(200, Data("{}".utf8)), .parse)
    }
}
