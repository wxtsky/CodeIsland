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
        // 5h at 20% is under the blocking floor → weekly wins. Neither weekly
        // is pressing or in surplus (1.5 days left → 79% elapsed; 70%/78% used
        // is roughly on pace) → the one with more used.
        let snap = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 20, resetsAt: now.addingTimeInterval(2.5 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 70, resetsAt: now.addingTimeInterval(1.5 * 86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 78, resetsAt: now.addingTimeInterval(1.5 * 86_400), scopeLabel: "Fable"),
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

    func testAutoSwitchesToSessionOnlyWhenBlocking() {
        // Blocking = past 50% used AND more than 10pp ahead of pace.
        // 60% used with 4h of 5h left → 20% elapsed → 40pp ahead → blocking.
        let ahead = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 60, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: ahead, mode: .auto, now: now)?.kind, .session)
        // 51% and 27pp ahead → blocking; 49% at the same pace is under the floor → weekly.
        let justOver = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 51, resetsAt: now.addingTimeInterval(3.8 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: justOver, mode: .auto, now: now)?.kind, .session)
        let justUnder = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 49, resetsAt: now.addingTimeInterval(3.8 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: justUnder, mode: .auto, now: now)?.kind, .weeklyAll)
        // 40% used with 4h left is 20pp ahead of pace but under the floor → weekly.
        let underFloor = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 40, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: underFloor, mode: .auto, now: now)?.kind, .weeklyAll)
        // 55% but only 3pp ahead (2.4h left → 52% elapsed) → under the margin → weekly.
        let underMargin = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 55, resetsAt: now.addingTimeInterval(2.4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 60, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: underMargin, mode: .auto, now: now)?.kind, .weeklyAll)
        // 82% with 10 minutes left: behind pace, and the window resets before
        // being blocked would matter → weekly stays.
        let nearReset = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 82, resetsAt: now.addingTimeInterval(600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 10, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: nearReset, mode: .auto, now: now)?.kind, .weeklyAll)
        // No weekly reported at all → session is all there is.
        let only = ClaudeQuotaSnapshot(limits: [ClaudeQuotaLimit(kind: .session, percent: 5)], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: only, mode: .auto, now: now)?.kind, .session)
    }

    func testAutoPrefersSurplusWeeklyWhenCalm() {
        // Both well behind pace with 1 day left (86% elapsed): the one most
        // behind pace is the budget most at risk of expiring unused.
        let bothSurplus = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30, resetsAt: now.addingTimeInterval(86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 48, resetsAt: now.addingTimeInterval(86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: bothSurplus, mode: .auto, now: now)?.kind, .weeklyAll)
        // A surplus scoped window beats a non-surplus weekly-all.
        let scopedSurplus = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 50, resetsAt: now.addingTimeInterval(3 * 86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 20, resetsAt: now.addingTimeInterval(3 * 86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: scopedSurplus, mode: .auto, now: now)?.kind, .weeklyScoped)
        // Surplus needs the week at least half gone: 0% used with 5 days left
        // is "not started", not "plenty left" → default (most used) applies.
        let tooEarly = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 0, resetsAt: now.addingTimeInterval(5 * 86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 10, resetsAt: now.addingTimeInterval(5 * 86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: tooEarly, mode: .auto, now: now)?.kind, .weeklyScoped)
        // A pressing weekly still beats a surplus one.
        let pressingFirst = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 85, resetsAt: now.addingTimeInterval(86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 20, resetsAt: now.addingTimeInterval(86_400), scopeLabel: "Fable"),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: pressingFirst, mode: .auto, now: now)?.kind, .weeklyAll)
        // A blocking session still beats a surplus weekly.
        let sessionFirst = ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 60, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30, resetsAt: now.addingTimeInterval(86_400)),
        ], fetchedAt: now)
        XCTAssertEqual(ClaudeQuotaSelector.pick(from: sessionFirst, mode: .auto, now: now)?.kind, .session)
    }

    func testSessionBlockingPredicate() {
        // Past the floor and ahead of pace → blocking.
        XCTAssertTrue(ClaudeQuotaSelector.sessionIsBlocking(
            ClaudeQuotaLimit(kind: .session, percent: 60, resetsAt: now.addingTimeInterval(4 * 3600)), now: now))
        // Ahead of pace but under the floor → not blocking.
        XCTAssertFalse(ClaudeQuotaSelector.sessionIsBlocking(
            ClaudeQuotaLimit(kind: .session, percent: 40, resetsAt: now.addingTimeInterval(4 * 3600)), now: now))
        // Past the floor but barely ahead of pace → not blocking.
        XCTAssertFalse(ClaudeQuotaSelector.sessionIsBlocking(
            ClaudeQuotaLimit(kind: .session, percent: 55, resetsAt: now.addingTimeInterval(2.4 * 3600)), now: now))
    }

    func testIsSurplusPredicate() {
        // 30% used with 1 day of 7 left → 56pp behind pace → surplus.
        XCTAssertTrue(ClaudeQuotaSelector.isSurplus(
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30, resetsAt: now.addingTimeInterval(86_400)), now: now))
        // Surplus is a weekly concept: a quiet 5h window never counts.
        XCTAssertFalse(ClaudeQuotaSelector.isSurplus(
            ClaudeQuotaLimit(kind: .session, percent: 10, resetsAt: now.addingTimeInterval(3600)), now: now))
        // Too early in the week: 0% used with 5 days left is "not started".
        XCTAssertFalse(ClaudeQuotaSelector.isSurplus(
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 0, resetsAt: now.addingTimeInterval(5 * 86_400)), now: now))
        // No reset time → no way to know the week is late.
        XCTAssertFalse(ClaudeQuotaSelector.isSurplus(
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 30), now: now))
        // Behind pace, but not by enough (1.5 days left, 70% used → 9pp).
        XCTAssertFalse(ClaudeQuotaSelector.isSurplus(
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 70, resetsAt: now.addingTimeInterval(1.5 * 86_400)), now: now))
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

    // MARK: token hygiene

    func testRequestAndSessionKeepTheTokenOffDisk() {
        XCTAssertEqual(ClaudeQuotaClient.request(token: "tok").cachePolicy, .reloadIgnoringLocalCacheData)
        let config = ClaudeQuotaClient.session.configuration
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
    }

    func testRedirectsAreNeverFollowed() async {
        // Never resumed — no network.
        let task = ClaudeQuotaClient.session.dataTask(with: ClaudeQuotaClient.endpoint)
        let redirect = HTTPURLResponse(url: ClaudeQuotaClient.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/"])!
        let next = await ClaudeQuotaClient.RedirectRefusal.shared.urlSession(
            ClaudeQuotaClient.session, task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://example.com/")!)
        )
        XCTAssertNil(next)
    }

    /// Counts requests that reach the wire; answers every one with a 500.
    private final class CountingProtocol: URLProtocol {
        nonisolated(unsafe) static var count = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.count += 1
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testKnownExpiredTokenIsNeverSent() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingProtocol.self]
        let session = URLSession(configuration: config)
        CountingProtocol.count = 0
        // `fetch(using:)` skips the utility-QoS credential hop, which a loaded
        // machine can starve for tens of seconds.
        let expired = ClaudeOAuthCredential(accessToken: "tok", expiresAt: now.addingTimeInterval(-60))
        do {
            _ = try await ClaudeQuotaClient.fetch(using: expired, session: session, now: now)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ClaudeQuotaClientError, .unauthorized)
        }
        XCTAssertEqual(CountingProtocol.count, 0)
        // A live token does go out (and the stubbed 500 maps through).
        let live = ClaudeOAuthCredential(accessToken: "tok", expiresAt: now.addingTimeInterval(3600))
        do {
            _ = try await ClaudeQuotaClient.fetch(using: live, session: session, now: now)
            XCTFail("expected http(500)")
        } catch {
            XCTAssertEqual(error as? ClaudeQuotaClientError, .http(500))
        }
        XCTAssertEqual(CountingProtocol.count, 1)
    }

    // MARK: security(1) runner

    func testRunnerReturnsStdoutAndSecretIsTrimmed() throws {
        let out = try XCTUnwrap(ClaudeCredentialStore.runCapturingStdout(path: "/bin/echo", args: ["secret"], timeout: 5))
        XCTAssertEqual(ClaudeCredentialStore.trimmingSecretOutput(out), Data("secret".utf8))
        XCTAssertNil(ClaudeCredentialStore.trimmingSecretOutput(Data("\n".utf8)))
        XCTAssertNil(ClaudeCredentialStore.runCapturingStdout(path: "/usr/bin/false", args: [], timeout: 5))
        // Larger than a pipe buffer: must not wedge the child.
        let big = ClaudeCredentialStore.runCapturingStdout(
            path: "/bin/dd", args: ["if=/dev/zero", "bs=1024", "count=200"], timeout: 5)
        XCTAssertEqual(big?.count, 200 * 1024)
    }

    func testRunnerDeadlineCoversAChildThatNeverExits() {
        // A security(1) waiting on a keychain dialog looks like this: alive,
        // stdout open, nothing written. The deadline must still fire.
        let started = Date()
        XCTAssertNil(ClaudeCredentialStore.runCapturingStdout(path: "/bin/sleep", args: ["30"], timeout: 0.3))
        // Generous bound for a loaded CI box; the point is "not 30s".
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
