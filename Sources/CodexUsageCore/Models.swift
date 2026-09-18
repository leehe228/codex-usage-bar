import Foundation
import CoreFoundation

public enum UsageError: Error, LocalizedError, Sendable, Equatable {
    case missingCLI, signedOut, wrongAccount, malformed, timedOut, exited, oversized
    case rpc(Int)
    case unsafeHome
    public var errorDescription: String? {
        switch self {
        case .missingCLI: "Codex CLI를 찾을 수 없습니다. 설정에서 실행 파일을 지정하세요."
        case .signedOut: "ChatGPT 로그인이 필요합니다. 계정을 재인증하세요."
        case .wrongAccount: "연결된 계정이 일치하지 않습니다. 올바른 계정으로 재인증하세요."
        case .malformed: "Codex가 유효한 데이터를 반환하지 않았습니다."
        case .timedOut: "조회 시간이 초과되었습니다."
        case .exited: "Codex 조회 프로세스가 종료되었습니다."
        case .oversized: "조회 응답이 허용 크기를 초과했습니다."
        case .rpc(let code): code == -32601 ? "이 기능을 지원하는 Codex CLI로 업데이트하세요." : "Codex 요청에 실패했습니다 (\(code))."
        case .unsafeHome: "앱이 소유한 안전한 계정 저장소가 아닙니다."
        }
    }
}

public struct AccountIdentity: Codable, Sendable, Equatable {
    public var subject: String
    public var workspace: String
    public var email: String?
    public var plan: String
    public var key: String { subject + ":" + workspace }
    public var isEdu: Bool { ["edu", "education"].contains(plan.lowercased()) }
    public init(subject: String, workspace: String, email: String?, plan: String) {
        self.subject = subject; self.workspace = workspace; self.email = email; self.plan = plan
    }
    public func matches(_ other: Self) -> Bool { subject == other.subject && workspace == other.workspace }
}

public struct QuotaWindow: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var bucket: String
    public var name: String?
    public var kind: String
    public var isReserveQuota: Bool {
        bucket.lowercased() == "base_model_inference" || (name ?? "").lowercased().filter { $0.isLetter || $0.isNumber } == "gptreserve"
    }
    public var isCodexSpark: Bool {
        if bucket.lowercased() == "codex_bengalfox" { return true }
        let normalizedName = (name ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return normalizedName == "gpt53codexspark" || normalizedName == "codexspark"
    }
    public var used: Double?
    public var minutes: Int?
    public var reset: Date?
    public var title: String {
        let duration: String
        switch minutes {
        case 300: duration = "5시간"
        case 10080: duration = "주간"
        case let m? where m > 0 && m % 60 == 0: duration = "\(m / 60)시간"
        case let m? where m > 0: duration = "\(m)분"
        default: duration = kind == "primary" ? "단기 한도" : "장기 한도"
        }
        return bucket == "codex" ? duration : "\(name ?? bucket) · \(duration)"
    }
    public init(bucket: String, name: String? = nil, kind: String, used: Double?, minutes: Int?, reset: Date?) {
        self.id = bucket + ":" + kind; self.bucket = bucket; self.name = name
        self.kind = kind; self.used = used; self.minutes = minutes; self.reset = reset
    }
    public func resetDescription(now: Date) -> String {
        guard let reset else { return "리셋 시각 미제공" }
        let seconds = Int(reset.timeIntervalSince(now))
        guard seconds > 0 else { return "리셋 확인 중" }
        let mins = max(1, Int(ceil(Double(seconds) / 60)))
        if mins >= 1440 { return "\(mins / 1440)일 \((mins % 1440) / 60)시간 후" }
        if mins >= 60 { return "\(mins / 60)시간 \(mins % 60)분 후" }
        return "\(mins)분 후"
    }
}

public struct QuotaSnapshot: Codable, Sendable, Equatable {
    public var windows: [QuotaWindow]
    public var reached: Bool
    public var credits: String?
    public var resetCreditCount: Int?
    public var fetchedAt: Date
    public func visibleWindows(preferences: Preferences) -> [QuotaWindow] {
        windows.filter { !$0.isReserveQuota && (preferences.showCodexSpark || !$0.isCodexSpark) }
    }
    public var menuBarRemainingPercent: Double? {
        let weekly = windows.first { $0.bucket == "codex" && ($0.minutes == 10080 || $0.kind == "secondary") }
        let short = windows.first { $0.bucket == "codex" && ($0.minutes == 300 || $0.kind == "primary") }
        guard let used = weekly?.used ?? short?.used else { return nil }
        return min(100, max(0, 100 - used))
    }
    public init(windows: [QuotaWindow], reached: Bool = false, credits: String? = nil, resetCreditCount: Int? = nil, fetchedAt: Date = .now) {
        self.windows = windows; self.reached = reached; self.credits = credits
        self.resetCreditCount = resetCreditCount; self.fetchedAt = fetchedAt
    }
}
public struct DailyUsage: Codable, Sendable, Identifiable, Equatable {
    public var startDate: String
    public var tokens: Int64
    public var id: String { startDate }
}
public struct ActivitySnapshot: Codable, Sendable, Equatable {
    public var lifetimeTokens: Int64?
    public var daily: [DailyUsage]?
    public var fetchedAt: Date
}
public struct SavedAccount: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var alias: String
    public var identity: AccountIdentity
    public var quota: QuotaSnapshot?
    public var activity: ActivitySnapshot?
    public var monthlyCredits: MonthlyCreditSnapshot?
    public init(id: UUID, alias: String, identity: AccountIdentity, quota: QuotaSnapshot? = nil, activity: ActivitySnapshot? = nil, monthlyCredits: MonthlyCreditSnapshot? = nil) {
        self.id = id; self.alias = alias; self.identity = identity; self.quota = quota; self.activity = activity; self.monthlyCredits = monthlyCredits
    }
}
public struct Preferences: Codable, Sendable {
    public var interval: Int = 300
    public var showMenuNumbers = false
    public var showCodexSpark = false
    public var remaining = false
    public var hideEmail = false
    public var representative: UUID?
    public var menuBarAccountIDs: [UUID]?
    public var cliPath = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case interval, remaining, hideEmail, representative, menuBarAccountIDs, cliPath, showMenuNumbers, showCodexSpark }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 300
        remaining = try c.decodeIfPresent(Bool.self, forKey: .remaining) ?? false
        hideEmail = try c.decodeIfPresent(Bool.self, forKey: .hideEmail) ?? false
        representative = try c.decodeIfPresent(UUID.self, forKey: .representative)
        menuBarAccountIDs = try c.decodeIfPresent([UUID].self, forKey: .menuBarAccountIDs)
        cliPath = try c.decodeIfPresent(String.self, forKey: .cliPath) ?? ""
        showMenuNumbers = try c.decodeIfPresent(Bool.self, forKey: .showMenuNumbers) ?? false
        showCodexSpark = try c.decodeIfPresent(Bool.self, forKey: .showCodexSpark) ?? false
        if ![0, 60, 120, 300, 900].contains(interval) { interval = 300 }
    }
    public func showsInMenuBar(_ id: UUID) -> Bool {
        menuBarAccountIDs?.contains(id) ?? true
    }
    public mutating func setMenuBarAccount(_ id: UUID, visible: Bool, allAccountIDs: [UUID]) {
        var selected = Set(menuBarAccountIDs ?? allAccountIDs)
        if visible { selected.insert(id) }
        else if selected.count > 1 { selected.remove(id) }
        let ordered = allAccountIDs.filter { selected.contains($0) }
        menuBarAccountIDs = ordered.count == allAccountIDs.count ? nil : ordered
    }
}
public struct DiskState: Codable, Sendable {
    public var version = 1
    public var accounts: [SavedAccount] = []
    public var preferences = Preferences()
    public init() {}
}

public enum UsageParser {
    public static func quota(_ data: Data, now: Date = .now) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.malformed }
        var buckets: [String: [String: Any]] = [:]
        if let map = root["rateLimitsByLimitId"] as? [String: Any], !map.isEmpty {
            for (key, value) in map { if let object = value as? [String: Any] { buckets[key] = object } }
        } else if let legacy = root["rateLimits"] as? [String: Any] {
            buckets[legacy["limitId"] as? String ?? "codex"] = legacy
        } else { throw UsageError.malformed }
        var windows: [QuotaWindow] = []
        var reached = false
        var creditBalance: String?
        for key in buckets.keys.sorted(by: { a, b in a == "codex" && b != "codex" || a != "codex" && b != "codex" && a < b }) {
            guard let bucket = buckets[key] else { continue }
            if bucket["rateLimitReachedType"] is String || bucket["spendControlReached"] as? Bool == true { reached = true }
            if key == "codex", let credit = bucket["credits"] as? [String: Any] { creditBalance = credit["balance"] as? String }
            for kind in ["primary", "secondary"] {
                guard let lane = bucket[kind] as? [String: Any] else { continue }
                let usageNumber = number(lane["usedPercent"])
                let raw = usageNumber?.doubleValue
                let valid = raw.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100 ? $0 : nil }
                let mins = number(lane["windowDurationMins"])?.intValue
                let seconds = number(lane["resetsAt"])?.doubleValue
                let reset = seconds.flatMap { $0.isFinite && $0 > 0 && $0 < 32_503_680_000 ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(QuotaWindow(bucket: key, name: bucket["limitName"] as? String, kind: kind,
                                           used: valid, minutes: mins.flatMap { $0 > 0 ? $0 : nil }, reset: reset))
            }
        }
        let count = (root["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        return QuotaSnapshot(windows: windows, reached: reached || windows.contains { $0.used == 100 }, credits: creditBalance, resetCreditCount: count, fetchedAt: now)
    }
    public static func activity(_ data: Data, now: Date = .now) throws -> ActivitySnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let summary = root["summary"] as? [String: Any] else { throw UsageError.malformed }
        let total = number(summary["lifetimeTokens"])?.int64Value
        let daily = (root["dailyUsageBuckets"] as? [[String: Any]])?.compactMap { item -> DailyUsage? in
            guard let date = item["startDate"] as? String, let tokens = number(item["tokens"])?.int64Value, tokens >= 0 else { return nil }
            return DailyUsage(startDate: date, tokens: tokens)
        }.sorted { $0.startDate < $1.startDate }
        return ActivitySnapshot(lifetimeTokens: total.flatMap { $0 >= 0 ? $0 : nil }, daily: daily, fetchedAt: now)
    }
    // Reads only identity claims from a CLI-owned private home; no credential material is returned.
    public static func identity(authData: Data, accountData: Data) throws -> AccountIdentity {
        guard let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let root = try JSONSerialization.jsonObject(with: accountData) as? [String: Any],
              let account = root["account"] as? [String: Any], account["type"] as? String == "chatgpt"
        else { throw UsageError.signedOut }
        let payload = jwt(tokens["id_token"] as? String) ?? jwt(tokens["access_token"] as? String) ?? [:]
        let claims = payload["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let subject = nonempty(payload["sub"] as? String) ?? nonempty(claims["chatgpt_user_id"] as? String),
              let workspace = nonempty(tokens["account_id"] as? String) ?? nonempty(claims["chatgpt_account_id"] as? String)
        else { throw UsageError.malformed }
        let email = account["email"] as? String
        if let localEmail = payload["email"] as? String, let email, localEmail.lowercased() != email.lowercased() { throw UsageError.wrongAccount }
        return AccountIdentity(subject: subject, workspace: workspace, email: email, plan: account["planType"] as? String ?? "unknown")
    }
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
    private static func nonempty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
    private static func jwt(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }; let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
