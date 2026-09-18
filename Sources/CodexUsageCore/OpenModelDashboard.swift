import Foundation
import CoreFoundation

public enum OpenModelPeriod: String, Codable, CaseIterable, Sendable, Identifiable {
    case today, month, last24Hours
    public var id: String { rawValue }
    public var title: String {
        switch self { case .today: "오늘"; case .month: "이번 달"; case .last24Hours: "최근 24시간" }
    }
    public var granularity: String { self == .month ? "daily" : "hourly" }
    public func start(now: Date, timeZone: TimeZone) -> Date {
        let periods = OpenModelParser.periods(now: now, timeZone: timeZone)
        switch self {
        case .today: return periods.today
        case .month: return periods.month
        case .last24Hours: return now.addingTimeInterval(-86_400)
        }
    }
}

public enum OpenModelMeasure: String, CaseIterable, Identifiable, Sendable {
    case cost, requests, tokens
    public var id: String { rawValue }
    public var title: String {
        switch self { case .cost: "비용"; case .requests: "요청"; case .tokens: "토큰" }
    }
    public var unit: String {
        switch self { case .cost: "USD"; case .requests: "회"; case .tokens: "토큰" }
    }
    public func value(_ metrics: OpenModelMetrics) -> Double {
        switch self {
        case .cost: Double(metrics.cost) / 1_000_000
        case .requests: Double(metrics.requests)
        case .tokens: Double(metrics.tokens)
        }
    }
    public func formatted(_ metrics: OpenModelMetrics) -> String {
        switch self {
        case .cost: OpenModelSnapshot.dollars(metrics.cost)
        case .requests: "\(metrics.requests.formatted())회"
        case .tokens: metrics.tokens.formatted()
        }
    }
}

public struct OpenModelModelUsage: Codable, Sendable, Equatable, Identifiable {
    public var model: String
    public var metrics: OpenModelMetrics
    public var id: String { model }
}

public struct OpenModelBucket: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var models: [OpenModelModelUsage]
}

public struct OpenModelUsage: Codable, Sendable, Equatable {
    public var models: [OpenModelModelUsage]
    public var buckets: [OpenModelBucket]
}

public struct OpenModelDashboard: Codable, Sendable, Equatable {
    public var period: OpenModelPeriod
    public var from: Date
    public var to: Date
    public var metrics: OpenModelMetrics
    public var usage: OpenModelUsage?
}

extension OpenModelParser {
    public static func modelUsage(_ data: Data) throws -> OpenModelUsage {
        let body = try object(data)
        guard let models = body["models"] as? [[String: Any]], let buckets = body["buckets"] as? [[String: Any]],
              models.count <= 500, buckets.count <= 800 else { throw OpenModelError.malformed }
        func metrics(_ values: [String: Any], prefix: String = "") throws -> OpenModelMetrics {
            let cost = try integer(values[prefix + "cost"])
            let requests = try integer(values[prefix + "requests"])
            let tokens = try integer(values[prefix + "tokens"])
            guard cost >= 0, requests >= 0, tokens >= 0 else { throw OpenModelError.malformed }
            return OpenModelMetrics(cost: cost, requests: requests, tokens: tokens)
        }
        var names = Set<String>()
        let totals = try models.map { row in
            guard let model = row["model_id"] as? String, !model.isEmpty, names.insert(model).inserted else { throw OpenModelError.malformed }
            return try OpenModelModelUsage(model: model, metrics: metrics(row, prefix: "total_"))
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        let standard = ISO8601DateFormatter()
        var timestamps = Set<Date>()
        let series = try buckets.map { row in
            guard let text = row["timestamp"] as? String, let date = fractional.date(from: text) ?? standard.date(from: text),
                  timestamps.insert(date).inserted, let values = row["models"] as? [String: [String: Any]],
                  Set(values.keys).isSubset(of: names) else { throw OpenModelError.malformed }
            return try OpenModelBucket(timestamp: date, models: values.keys.sorted().map { model in
                try OpenModelModelUsage(model: model, metrics: metrics(values[model]!))
            })
        }
        return OpenModelUsage(models: totals, buckets: series.sorted { $0.timestamp < $1.timestamp })
    }
}
