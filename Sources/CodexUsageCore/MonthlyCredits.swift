import Foundation
import CoreFoundation

public struct MonthlyCreditSnapshot: Codable, Sendable, Equatable {
    public var used: Double
    public var limit: Double
    public var fetchedAt: Date
    public var usedPercent: Double { min(100, max(0, used / limit * 100)) }
    public var remainingPercent: Double { 100 - usedPercent }
    public init(used: Double, limit: Double, fetchedAt: Date = .now) {
        self.used = used; self.limit = limit; self.fetchedAt = fetchedAt
    }
    public static func parse(_ data: Data, now: Date = .now) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let effective = root["effective_monthly_limit"] as? [String: Any],
              effective["limit_mode"] as? String == "amount_credits",
              let mode = effective["enforcement_mode"] as? String,
              ["HARD_CAP", "SOFT_CAP"].contains(mode.uppercased()),
              let limit = amount(effective["limit"]), limit > 0,
              let used = amount(root["current_month_usage"]), used >= 0 else { throw UsageError.malformed }
        return Self(used: used, limit: limit, fetchedAt: now)
    }
    private static func amount(_ value: Any?) -> Double? {
        let parsed: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { parsed = n.doubleValue }
        else if let s = value as? String { parsed = Double(s) }
        else { parsed = nil }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }
}

// Redirects must not forward account credentials to a different endpoint.
private final class MonthlyCreditsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension CodexService {
    func monthlyCreditsRequest(id: UUID, identity: AccountIdentity) throws -> URLRequest {
        guard identity.isEdu else { throw UsageError.malformed }
        let auth = try repository.readAuth(id)
        let localIdentity = try UsageParser.identity(authData: auth, accountData: Data(#"{"account":{"type":"chatgpt"}}"#.utf8))
        guard identity.matches(localIdentity) else { throw UsageError.wrongAccount }
        guard let root = try JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else { throw UsageError.signedOut }
        var allowed = CharacterSet.urlPathAllowed
        allowed.subtract(CharacterSet(charactersIn: "/?#%"))
        guard let workspace = identity.workspace.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://chatgpt.com/backend-api/accounts/\(workspace)/spend-controls/current-user/monthly-usage") else { throw UsageError.malformed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(identity.workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageBar/0.1.6", forHTTPHeaderField: "User-Agent")
        return request
    }
    public func monthlyCredits(id: UUID, identity: AccountIdentity) async throws -> MonthlyCreditSnapshot {
        try Task.checkCancellation()
        let request = try monthlyCreditsRequest(id: id, identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: MonthlyCreditsRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw UsageError.malformed }
        guard response.statusCode == 200 else { throw response.statusCode == 401 ? UsageError.signedOut : UsageError.rpc(response.statusCode) }
        guard data.count < 1_048_576 else { throw UsageError.oversized }
        return try MonthlyCreditSnapshot.parse(data)
    }
}
