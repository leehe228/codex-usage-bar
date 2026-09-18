import Foundation
import CoreFoundation
import Security

public struct OpenModelMetrics: Codable, Sendable, Equatable {
    public var cost: Int64
    public var requests: Int64
    public var tokens: Int64
    public var averageTPM: Double?
}

public struct OpenModelSnapshot: Codable, Sendable, Equatable {
    public var balance: Int64
    public var frozen: Int64
    public var today: OpenModelMetrics
    public var month: OpenModelMetrics
    public var fetchedAt: Date
    public var timeZone: String
    public var tokenBreakdown: OpenModelTokenBreakdown?
    public var dashboards: [OpenModelDashboard]?
    public var available: Int64 { balance - frozen }
    public static func dollars(_ microdollars: Int64) -> String {
        (Decimal(microdollars) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
}

public struct OpenModelTokenBreakdown: Codable, Sendable, Equatable {
    public var input: Int64
    /// Matches the console: output includes reasoning tokens.
    public var output: Int64
}

public enum OpenModelError: Error, LocalizedError, Sendable {
    case authentication, malformed, http(Int), keychain, identity
    public var errorDescription: String? {
        switch self {
        case .authentication: "OpenModel 로그인이 만료되었습니다. 계정을 재인증하세요."
        case .malformed: "OpenModel 응답 형식을 확인하지 못했습니다."
        case .http(let status): "OpenModel 조회에 실패했습니다 (HTTP \(status))."
        case .keychain: "OpenModel 인증 정보를 Keychain에서 읽거나 저장하지 못했습니다."
        case .identity: "기존에 연결한 OpenModel 계정과 다릅니다."
        }
    }
}

public struct OpenModelCookie: Codable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var expires: Date?
    public init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain
        path = cookie.path; secure = cookie.isSecure; expires = cookie.expiresDate
    }
    public var allowed: Bool {
        ["api.openmodel.ai", ".api.openmodel.ai", ".openmodel.ai", "openmodel.ai"].contains(domain) && secure
    }
    public func applies(to url: URL, now: Date = .now) -> Bool {
        guard allowed, url.scheme == "https", url.host == "api.openmodel.ai", expires.map({ $0 > now }) ?? true else { return false }
        return url.path == path || (url.path.hasPrefix(path) && (path.hasSuffix("/") || url.path.dropFirst(path.count).first == "/"))
    }
}

public struct OpenModelCredential: Codable, Sendable {
    public var accessToken: String
    public var cookies: [OpenModelCookie]
    public init(accessToken: String, cookies: [OpenModelCookie]) {
        self.accessToken = accessToken; self.cookies = cookies.filter(\.allowed)
    }
}

public enum OpenModelKeychain {
    private static let service = "com.hoeun.codex-usage-bar.openmodel"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public static func load(_ id: UUID) throws -> OpenModelCredential {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw OpenModelError.authentication }
        guard status == errSecSuccess, let data = result as? Data else { throw OpenModelError.keychain }
        return try JSONDecoder().decode(OpenModelCredential.self, from: data)
    }
    public static func save(_ credential: OpenModelCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let values: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw OpenModelError.keychain }
        } else if status != errSecSuccess { throw OpenModelError.keychain }
    }
    public static func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenModelError.keychain }
    }
}

public enum OpenModelParser {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["success"] as? Bool == true, let body = value["data"] as? [String: Any] else { throw OpenModelError.malformed }
        return body
    }
    public static func integer(_ value: Any?) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let integer = Int64(n.stringValue) else { throw OpenModelError.malformed }
        return integer
    }
    public static func identity(_ data: Data) throws -> (AccountIdentity, Int64, Int64) {
        let body = try object(data)
        let id: String
        if let s = body["id"] as? String, !s.isEmpty { id = s }
        else { id = String(try integer(body["id"])) }
        let balance = try integer(body["balance"])
        let frozen = try integer(body["frozen_balance"])
        guard frozen >= 0, !balance.subtractingReportingOverflow(frozen).overflow else { throw OpenModelError.malformed }
        return (AccountIdentity(subject: id, workspace: "openmodel", email: body["email"] as? String, plan: "OpenModel"), balance, frozen)
    }
    public static func metrics(_ data: Data) throws -> OpenModelMetrics {
        let body = try object(data)
        func current(_ key: String) throws -> Int64 {
            let number = try integer((body[key] as? [String: Any])?["current"])
            guard number >= 0 else { throw OpenModelError.malformed }; return number
        }
        var result = try OpenModelMetrics(cost: current("cost"), requests: current("requests"), tokens: current("tokens"))
        if let value = (body["avg_tpm"] as? [String: Any])?["current"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0 {
            result.averageTPM = value.doubleValue
        }
        return result
    }
    public static func periods(now: Date, timeZone: TimeZone = .current) -> (today: Date, month: Date) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return (calendar.startOfDay(for: now), calendar.dateInterval(of: .month, for: now)!.start)
    }
}

private final class OpenModelRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor OpenModelClient {
    private var credential: OpenModelCredential
    private let id: UUID?
    private let session: URLSession
    public init(credential: OpenModelCredential, persistentID: UUID? = nil) {
        self.credential = credential; id = persistentID
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: OpenModelRedirects(), delegateQueue: nil)
    }
    init(credential: OpenModelCredential, session: URLSession) {
        self.credential = credential; self.session = session; id = nil
    }
    deinit { session.invalidateAndCancel() }
    public func currentCredential() -> OpenModelCredential { credential }
    public func fetch(expected: AccountIdentity? = nil) async throws -> (AccountIdentity, OpenModelSnapshot) {
        let (identity, balance, frozen) = try OpenModelParser.identity(await request("self"))
        if let expected, !expected.matches(identity) { throw OpenModelError.identity }
        let now = Date.now, zone = TimeZone.current
        let periods = OpenModelParser.periods(now: now, timeZone: zone)
        func query(_ from: Date) -> [URLQueryItem] {
            let format = ISO8601DateFormatter()
            return [URLQueryItem(name: "createdAfter", value: format.string(from: from)),
                    URLQueryItem(name: "createdBefore", value: format.string(from: now)),
                    URLQueryItem(name: "granularity", value: "daily")]
        }
        let today = try OpenModelParser.metrics(await request("dashboard/metrics", query: query(periods.today)))
        let month = try OpenModelParser.metrics(await request("dashboard/metrics", query: query(periods.month)))
        var snapshot = OpenModelSnapshot(balance: balance, frozen: frozen, today: today, month: month, fetchedAt: now, timeZone: zone.identifier)
        var dashboards: [OpenModelDashboard] = []
        for period in OpenModelPeriod.allCases {
            let from = period.start(now: now, timeZone: zone)
            let items = query(from).filter { $0.name != "granularity" } + [URLQueryItem(name: "granularity", value: period.granularity)]
            let metrics: OpenModelMetrics?
            switch period {
            case .today: metrics = today
            case .month: metrics = month
            case .last24Hours: metrics = try? OpenModelParser.metrics(await request("dashboard/metrics", query: items))
            }
            if let metrics {
                let usage = try? OpenModelParser.modelUsage(await request("dashboard/model-usage", query: items))
                dashboards.append(OpenModelDashboard(period: period, from: from, to: now, metrics: metrics, usage: usage))
            }
            try Task.checkCancellation()
        }
        snapshot.dashboards = dashboards
        // Aggregate only a complete, bounded set of logs. Large histories retain
        // the authoritative metrics total and do not display partial token sums.
        if month.requests <= 2_000 {
            snapshot.tokenBreakdown = try? await tokens(query: query(periods.month))
        }
        return (identity, snapshot)
    }
    private func tokens(query: [URLQueryItem]) async throws -> OpenModelTokenBreakdown? {
        var input: Int64 = 0, output: Int64 = 0, count = 0
        var total: Int64?
        var seen = Set<Data>()
        for page in 1...20 {
            let data = try await request("logs", query: query.filter { $0.name != "granularity" } + [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "pageSize", value: "100")])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool == true,
                  let rows = root["data"] as? [[String: Any]], let meta = root["meta"] as? [String: Any], let pagination = meta["pagination"] as? [String: Any] else { return nil }
            let expected = try OpenModelParser.integer(pagination["total"])
            let pages = try OpenModelParser.integer(pagination["totalPages"])
            guard expected >= 0, expected <= 2_000, pages <= 20, total == nil || total == expected else { return nil }
            total = expected
            for row in rows {
                // The console log API has no stable public row ID. Reject repeated
                // rows conservatively rather than risk counting a shifted page twice.
                let key = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
                guard seen.insert(key).inserted, let values = row["tokens"] as? [String: Any] else { return nil }
                func token(_ field: String) throws -> Int64 {
                    // Optional token categories are omitted for protocols that do not use them.
                    let v = try OpenModelParser.integer(values[field] ?? 0)
                    guard v >= 0 else { throw OpenModelError.malformed }; return v
                }
                for (isInput, value) in [(true, try token("input")), (false, try token("output")), (false, try token("reasoning"))] {
                    let sum = (isInput ? input : output).addingReportingOverflow(value)
                    guard !sum.overflow else { return nil }
                    if isInput { input = sum.partialValue } else { output = sum.partialValue }
                }
            }
            count += rows.count
            if Int64(page) >= pages { return Int64(count) == expected ? OpenModelTokenBreakdown(input: input, output: output) : nil }
            guard !rows.isEmpty else { return nil }
        }
        return nil
    }
    public func refreshAuthentication() async throws {
        let data = try await request("auth/refresh", method: "POST", retry: false)
        let body = try OpenModelParser.object(data)
        guard let token = body["access_token"] as? String, !token.isEmpty else { throw OpenModelError.authentication }
        credential.accessToken = token
        if let id { try OpenModelKeychain.save(credential, id: id) }
    }
    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", retry: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.openmodel.ai/web/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://console.openmodel.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://console.openmodel.ai/", forHTTPHeaderField: "Referer")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let cookies = credential.cookies.filter { $0.applies(to: url) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count < 4_194_304 else { throw OpenModelError.malformed }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map(OpenModelCookie.init).filter(\.allowed) {
            credential.cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            credential.cookies.append(cookie)
        }
        if http.statusCode == 401 {
            guard retry else { throw OpenModelError.authentication }
            try await refreshAuthentication()
            return try await self.request(path, query: query, method: method, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else { throw OpenModelError.http(http.statusCode) }
        return data
    }
}
