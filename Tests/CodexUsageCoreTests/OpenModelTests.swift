import Foundation
import Testing
@testable import CodexUsageCore

@Suite(.serialized) struct OpenModelTests {
    @Test func legacyAccountsAndCredentialsStaySeparate() throws {
        let id = UUID()
        let data = Data("""
        {"version":1,"preferences":{},"accounts":[{"id":"\(id)","alias":"old","identity":{"subject":"s","workspace":"w","plan":"pro"}}]}
        """.utf8)
        let state = try JSONDecoder().decode(DiskState.self, from: data)
        #expect(!state.accounts[0].isOpenModel)
        #expect(state.accounts[0].provider == nil)
        let encoded = try JSONEncoder().encode(state)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("accessToken"))
    }
    @Test func moneyIsExactAndMalformedMetricsNeverBecomeZero() throws {
        let data = Data(#"{"success":true,"data":{"id":7,"email":"example@example.com","balance":4868832,"frozen_balance":100000}}"#.utf8)
        let (_, balance, frozen) = try OpenModelParser.identity(data)
        #expect(balance - frozen == 4_768_832)
        let metrics = try OpenModelParser.metrics(Data(StubOpenModel.metrics.utf8))
        #expect(metrics.cost == 131_168)
        for malformed in [#"{"success":true,"data":{}}"#, #"{"success":false,"data":{"cost":{"current":0}}}"#] {
            #expect(throws: (any Error).self) { try OpenModelParser.metrics(Data(malformed.utf8)) }
        }
        #expect(throws: (any Error).self) { try OpenModelParser.integer(true) }
        #expect(throws: (any Error).self) { try OpenModelParser.integer(1.5) }
    }
    @Test func dateBoundariesUseDisplayedTimeZone() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-01T00:30:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let result = OpenModelParser.periods(now: now, timeZone: zone)
        let formatter = ISO8601DateFormatter()
        #expect(formatter.string(from: result.today) == "2026-08-31T07:00:00Z")
        #expect(formatter.string(from: result.month) == "2026-08-01T07:00:00Z")
    }
    @Test func cookiesCannotEscapeOpenModelOrCookiePath() throws {
        let cookie = try #require(HTTPCookie(properties: [.name:"session", .value:"test", .domain:".openmodel.ai", .path:"/web/v1/auth", .secure:"TRUE"]))
        let saved = OpenModelCookie(cookie)
        #expect(saved.applies(to: URL(string: "https://api.openmodel.ai/web/v1/auth/refresh")!))
        #expect(!saved.applies(to: URL(string: "https://api.openmodel.ai/web/v1/auth-other")!))
        #expect(!saved.applies(to: URL(string: "https://example.com/web/v1/auth/refresh")!))
        #expect(!saved.applies(to: URL(string: "http://api.openmodel.ai/web/v1/auth/refresh")!))
    }
    @Test func expiredAccessTokenRefreshesOnceAndRetriesOriginalRequest() async throws {
        StubOpenModel.state.reset(mode: .success)
        let client = client()
        let (identity, snapshot) = try await client.fetch()
        #expect(identity.subject == "7")
        #expect(snapshot.available == 4_868_832)
        #expect(snapshot.today.cost == 131_168)
        #expect(snapshot.month.requests == 2)
        #expect(snapshot.tokenBreakdown == OpenModelTokenBreakdown(input: 11, output: 5))
        let auth = await client.currentCredential()
        #expect(auth.accessToken == "renewed-test-token")
        #expect(auth.cookies.contains { $0.value == "rotated-test-cookie" })
        let requests = StubOpenModel.state.requests()
        #expect(requests.filter { $0.url?.path.hasSuffix("auth/refresh") == true }.count == 1)
        #expect(requests.filter { $0.url?.path.hasSuffix("/self") == true }.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "api.openmodel.ai" })
    }
    @Test func failedRefreshDoesNotLoop() async throws {
        StubOpenModel.state.reset(mode: .expired)
        do { _ = try await client().fetch(); Issue.record("Expired login should fail") }
        catch OpenModelError.authentication { }
        #expect(StubOpenModel.state.requests().count == 2)
    }
    @Test func wrongIdentityStopsBeforeUsageRequests() async throws {
        StubOpenModel.state.reset(mode: .success)
        do {
            _ = try await client().fetch(expected: AccountIdentity(subject: "another-user", workspace: "openmodel", email: nil, plan: "OpenModel"))
            Issue.record("Another account must not be accepted")
        } catch OpenModelError.identity { }
        #expect(!StubOpenModel.state.requests().contains { $0.url?.path.contains("dashboard") == true })
    }
    @Test func partialLogsDoNotDisplayPartialTotals() async throws {
        StubOpenModel.state.reset(mode: .partial)
        let (_, snapshot) = try await client().fetch()
        #expect(snapshot.tokenBreakdown == nil)
        #expect(snapshot.month.tokens == 130_218)
    }
    @Test func dashboardsUsePeriodSpecificRequestsAndServerModels() async throws {
        StubOpenModel.state.reset(mode: .success)
        let (_, snapshot) = try await client().fetch()
        let dashboards = try #require(snapshot.dashboards)
        #expect(dashboards.count == 3)
        for dashboard in dashboards {
            #expect(dashboard.usage?.models.first?.model == "example-model")
            #expect(dashboard.usage?.models.first?.metrics.cost == 131_168)
            #expect(dashboard.metrics.averageTPM == 90.5)
            #expect(dashboard.to == snapshot.fetchedAt)
        }
        let recent = try #require(dashboards.first { $0.period == .last24Hours })
        #expect(recent.to.timeIntervalSince(recent.from) == 86_400)
        let queries = StubOpenModel.state.requests().filter { $0.url?.path.hasSuffix("model-usage") == true }
            .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(queries.count == 3)
        #expect(queries.filter { $0.contains(URLQueryItem(name: "granularity", value: "hourly")) }.count == 2)
        #expect(queries.filter { $0.contains(URLQueryItem(name: "granularity", value: "daily")) }.count == 1)
    }
    @Test func optionalDashboardFailurePreservesBalanceAndDoesNotInventZeros() async throws {
        StubOpenModel.state.reset(mode: .dashboardUnavailable)
        let (_, snapshot) = try await client().fetch()
        #expect(snapshot.available == 4_868_832)
        #expect(snapshot.month.requests == 2)
        #expect(snapshot.dashboards?.count == 2)
        #expect(snapshot.dashboards?.allSatisfy { $0.usage == nil } == true)
        #expect(snapshot.dashboards?.contains { $0.period == .last24Hours } == false)
    }
    @Test func modelUsageRejectsMalformedOrDuplicateSeries() throws {
        let valid = try OpenModelParser.modelUsage(Data(StubOpenModel.usage.utf8))
        #expect(valid.models.count == 1)
        #expect(valid.buckets.first?.models.first?.metrics.tokens == 130_218)
        for invalid in [
            StubOpenModel.usage.replacingOccurrences(of: "131168", with: "-1"),
            StubOpenModel.usage.replacingOccurrences(of: "130218", with: "true"),
            StubOpenModel.usage.replacingOccurrences(of: "2026-09-18T00:00:00Z", with: "invalid"),
            StubOpenModel.usage.replacingOccurrences(of: "\"model_id\":\"example-model\"", with: "\"model_id\":\"different-model\"")
        ] {
            #expect(throws: (any Error).self) { try OpenModelParser.modelUsage(Data(invalid.utf8)) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(StubOpenModel.usage.utf8)) as? [String: Any])
        var body = try #require(object["data"] as? [String: Any])
        let models = try #require(body["models"] as? [[String: Any]])
        body["models"] = models + models; object["data"] = body
        let duplicate = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try OpenModelParser.modelUsage(duplicate) }
        let empty = try OpenModelParser.modelUsage(Data(#"{"success":true,"data":{"models":[],"buckets":[]}}"#.utf8))
        #expect(empty.models.isEmpty)
    }
    @Test func legacySnapshotDecodesWithoutDashboardOrTPM() throws {
        let data = Data(#"{"balance":1000000,"frozen":0,"today":{"cost":0,"requests":0,"tokens":0},"month":{"cost":0,"requests":0,"tokens":0},"fetchedAt":0,"timeZone":"Asia/Seoul"}"#.utf8)
        let snapshot = try JSONDecoder().decode(OpenModelSnapshot.self, from: data)
        #expect(snapshot.dashboards == nil)
        #expect(snapshot.month.averageTPM == nil)
        #expect(snapshot.available == 1_000_000)
    }
    @Test func rollingPeriodRemains24HoursAcrossDST() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T19:00:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(now.timeIntervalSince(OpenModelPeriod.last24Hours.start(now: now, timeZone: zone)) == 86_400)
        #expect(OpenModelPeriod.today.start(now: now, timeZone: zone) == ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z"))
    }
    private func client() -> OpenModelClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOpenModel.self]; config.httpCookieStorage = nil
        return OpenModelClient(credential: OpenModelCredential(accessToken: "expired-test-token", cookies: []), session: URLSession(configuration: config))
    }
}

private final class StubOpenModel: URLProtocol, @unchecked Sendable {
    enum Mode { case success, expired, partial, dashboardUnavailable }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var mode: Mode = .success
        private var captured: [URLRequest] = []
        func reset(mode: Mode) { lock.lock(); defer { lock.unlock() }; self.mode = mode; captured = [] }
        func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
        func record(_ request: URLRequest) -> Mode { lock.lock(); defer { lock.unlock() }; captured.append(request); return mode }
    }
    static let state = State()
    static let metrics = #"{"success":true,"data":{"cost":{"current":131168},"requests":{"current":2},"tokens":{"current":130218},"avg_tpm":{"current":90.5}}}"#
    static let usage = #"{"success":true,"data":{"models":[{"model_id":"example-model","total_cost":131168,"total_requests":2,"total_tokens":130218}],"buckets":[{"timestamp":"2026-09-18T00:00:00Z","models":{"example-model":{"cost":131168,"requests":2,"tokens":130218}}}]}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.record(request)
        let path = request.url!.path
        var status = 200, headers = ["Content-Type":"application/json"], body = Self.metrics
        if path.hasSuffix("auth/refresh") {
            status = mode == .expired ? 401 : 200
            headers["Set-Cookie"] = "refresh=rotated-test-cookie; Path=/web/v1/auth; Secure; HttpOnly"
            body = #"{"success":true,"data":{"access_token":"renewed-test-token"}}"#
        } else if path.hasSuffix("/self") {
            status = request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-test-token" ? 200 : 401
            body = #"{"success":true,"data":{"id":7,"email":"example@example.com","balance":4868832,"frozen_balance":0}}"#
        } else if path.hasSuffix("model-usage") {
            status = mode == .dashboardUnavailable ? 503 : 200
            body = Self.usage
        } else if path.hasSuffix("dashboard/metrics"), mode == .dashboardUnavailable,
                  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "granularity", value: "hourly")) == true {
            status = 503
        } else if path.hasSuffix("/logs") {
            body = """
            {"success":true,"data":[{"created_at":"2026-09-18T05:32:09Z","tokens":{"input":11,"output":3,"reasoning":2}}],"meta":{"pagination":{"total":\(mode == .partial ? 2 : 1),"totalPages":1}}}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
