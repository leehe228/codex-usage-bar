import AppKit
import CodexUsageCore
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    var disk = DiskState()
    var selected: UUID? { didSet { if oldValue != selected { onStatusChanged?() } } }
    var refreshing: Set<UUID> = []
    var errors: [UUID: String] = [:]
    var authRequired: Set<UUID> = []
    var activityErrors: [UUID: String] = [:]
    var monthlyErrors: [UUID: String] = [:]
    var message: String?
    var storageUnavailable = false
    var loginInProgress = false
    var loginStatus = ""
    var pendingIdentity: AccountIdentity?
    var pendingAlias = ""
    var loginURL: URL?
    var now = Date.now
    let demo: Bool
    @ObservationIgnored let repository: AccountRepository
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [UUID: UUID] = [:]
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var reauthTarget: UUID?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored var onStatusChanged: (() -> Void)?
    @ObservationIgnored var onLoginRequested: (() -> Void)?

    init(demo: Bool) {
        self.demo = demo
        repository = AccountRepository(root: demo ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CodexUsageBar-Demo-\(UUID().uuidString)") : nil)
        if demo { disk.accounts = Self.demoAccounts(); disk.preferences.representative = disk.accounts.first?.id }
        else {
            do { disk = try repository.load() } catch { storageUnavailable = true; message = "저장된 계정 정보를 읽지 못했습니다. 기존 파일을 보존했습니다. 앱 저장소를 확인하세요." }
        }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }; self.now = .now
                if !self.demo && !self.sleeping && self.disk.preferences.interval > 0 {
                    self.refreshAll(force: false, age: TimeInterval(self.disk.preferences.interval))
                }
                self.onStatusChanged?()
            }
        }
    }
    var cli: String? { CLILocator.resolve(custom: disk.preferences.cliPath) }
    var accounts: [SavedAccount] { disk.accounts }
    var statusTitle: String {
        guard let a = accounts.first(where: { $0.id == disk.preferences.representative }), let quota = a.quota else { return "" }
        let primary = quota.windows.first { $0.bucket == "codex" && $0.kind == "primary" }
        let secondary = quota.windows.first { $0.bucket == "codex" && $0.kind == "secondary" }
        let lanes = [primary, secondary].compactMap { lane -> String? in
            guard let lane, let used = lane.used else { return nil }
            let prefix = lane.minutes == 300 ? "5h" : lane.minutes == 10080 ? "W" : lane.kind == "primary" ? "S" : "L"
            return "\(prefix) \(Int(used))%"
        }
        let stale = errors[a.id] != nil || now.timeIntervalSince(quota.fetchedAt) > Double(max(600, disk.preferences.interval * 2)) || quota.windows.contains { ($0.reset ?? .distantFuture) <= now }
        return lanes.joined(separator: " · ") + (stale ? " !" : "")
    }
    func status(_ account: SavedAccount) -> String {
        if refreshing.contains(account.id) { return "조회 중" }
        if authRequired.contains(account.id) { return "재인증 필요" }
        if errors[account.id] != nil { return "조회 실패 · 이전 값" }
        guard let quota = account.quota else { return "확인 필요" }
        if quota.windows.contains(where: { ($0.reset ?? .distantFuture) <= now }) { return "리셋 확인 중" }
        if quota.reached { return "한도 도달" }
        if now.timeIntervalSince(quota.fetchedAt) > Double(max(600, disk.preferences.interval * 2)) { return "오래된 값" }
        return "정상 조회"
    }
    func persist() {
        guard !demo, !storageUnavailable else { onStatusChanged?(); return }
        do { try repository.save(disk) } catch { message = "설정을 저장하지 못했습니다. 저장소 접근 권한을 확인하세요." }
        onStatusChanged?()
    }
    func opened() { now = .now; refreshAll(force: false, age: 60) }
    func sleep() {
        sleeping = true; queue.removeAll()
        for task in tasks.values { task.cancel() }; tasks.removeAll(); revisions.removeAll(); refreshing.removeAll()
        cancelLogin()
    }
    func wake() { sleeping = false; refreshAll(force: false, age: 60) }
    func shutdown() { schedule?.cancel(); sleep() }
    func refreshAll(force: Bool = true, age: TimeInterval = 0) {
        guard !demo, !sleeping, !storageUnavailable else { return }
        for a in accounts {
            guard a.id != reauthTarget, !authRequired.contains(a.id) || force else { continue }
            let failureAge = lastAttempt[a.id].map { now.timeIntervalSince($0) } ?? .infinity
            let retry = retryDelay[a.id] ?? 0
            if !force && failureAge < retry { continue }
            if force || a.quota == nil || now.timeIntervalSince(a.quota!.fetchedAt) >= age {
                if tasks[a.id] == nil && !queue.contains(a.id) { queue.append(a.id) }
            }
        }
        pump()
    }
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var retryDelay: [UUID: TimeInterval] = [:]
    func refresh(_ id: UUID) {
        guard !demo, id != reauthTarget else { return }
        if tasks[id] == nil && !queue.contains(id) { queue.append(id) }; pump()
    }
    private func pump() {
        guard !sleeping, !storageUnavailable else { return }
        while tasks.count < 2 && !queue.isEmpty {
            let id = queue.removeFirst()
            guard let a = accounts.first(where: { $0.id == id }) else { continue }
            let revision = UUID(); revisions[id] = revision; refreshing.insert(id); lastAttempt[id] = .now
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.fetch(a, revision: revision)
                if self.revisions[id] == revision {
                    self.tasks[id] = nil; self.revisions[id] = nil; self.refreshing.remove(id)
                    self.onStatusChanged?(); self.pump()
                }
            }
        }
        onStatusChanged?()
    }
    private func fetch(_ account: SavedAccount, revision: UUID) async {
        let id = account.id
        do {
            guard let cli else { throw UsageError.missingCLI }
            let service = CodexService(repository: repository, executable: cli)
            let client = try service.client(id: id); defer { client.close() }
            try await withTaskCancellationHandler {
                try await client.initialize()
                let identity = try await service.identity(client, id: id)
                guard account.identity.matches(identity) else { throw UsageError.wrongAccount }
                let quota = try UsageParser.quota(await client.request("account/rateLimits/read"))
                try Task.checkCancellation()
                guard revisions[id] == revision, let index = disk.accounts.firstIndex(where: { $0.id == id }) else { return }
                disk.accounts[index].identity = identity; disk.accounts[index].quota = quota
                errors[id] = nil; authRequired.remove(id); retryDelay[id] = nil; persist()
                if identity.isEdu {
                    do {
                        let monthly = try await service.monthlyCredits(id: id, identity: identity)
                        try Task.checkCancellation()
                        guard revisions[id] == revision, let index = disk.accounts.firstIndex(where: { $0.id == id }) else { return }
                        disk.accounts[index].monthlyCredits = monthly; monthlyErrors[id] = nil; persist()
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        if revisions[id] == revision { monthlyErrors[id] = "월간 크레딧을 확인하지 못했습니다. 마지막 확인 값이 있으면 유지합니다." }
                    }
                }
                do {
                    let activity = try UsageParser.activity(await client.request("account/usage/read", timeout: 8))
                    try Task.checkCancellation()
                    guard revisions[id] == revision, let index = disk.accounts.firstIndex(where: { $0.id == id }) else { return }
                    disk.accounts[index].activity = activity; activityErrors[id] = nil; persist()
                } catch is CancellationError { throw CancellationError() }
                catch { if revisions[id] == revision { activityErrors[id] = "토큰 활동을 확인하지 못했습니다. 이전 집계가 있으면 유지합니다." } }
            } onCancel: { client.close() }
        } catch is CancellationError { return }
        catch {
            guard revisions[id] == revision else { return }
            errors[id] = (error as? UsageError)?.localizedDescription ?? "계정 조회에 실패했습니다."
            if error as? UsageError == .signedOut || error as? UsageError == .wrongAccount { authRequired.insert(id) }
            retryDelay[id] = min(900, max(60, (retryDelay[id] ?? 30) * 2))
        }
    }
    func startLogin(alias: String, replacing: UUID? = nil) {
        guard !demo, !storageUnavailable, !loginInProgress, pendingID == nil else { return }
        guard let cli else { message = UsageError.missingCLI.localizedDescription; return }
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { message = "계정 별칭을 입력하세요."; return }
        loginInProgress = true; pendingAlias = alias; reauthTarget = replacing; loginStatus = "로그인을 준비하고 있습니다…"
        if let replacing { tasks[replacing]?.cancel(); queue.removeAll { $0 == replacing } }
        let stage = UUID(); pendingID = stage
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try repository.createHome(stage)
                let service = CodexService(repository: repository, executable: cli)
                let client = try service.client(id: stage); defer { client.close() }
                try await withTaskCancellationHandler {
                    try await client.initialize()
                    let data = try await client.request("account/login/start", params: Data(#"{"type":"chatgpt"}"#.utf8))
                    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let loginID = result["loginId"] as? String, let raw = result["authUrl"] as? String,
                          let url = URL(string: raw), url.scheme == "https", ["auth.openai.com", "auth.chatgpt.com"].contains(url.host ?? "") else { throw UsageError.malformed }
                    try Task.checkCancellation()
                    guard pendingID == stage else { throw CancellationError() }
                    loginURL = url; loginStatus = "브라우저에서 원하는 ChatGPT 계정으로 로그인하세요."
                    NSWorkspace.shared.open(url)
                    try await client.waitForLogin(id: loginID)
                    let identity = try await service.identity(client, id: stage)
                    try Task.checkCancellation()
                    guard pendingID == stage else { throw CancellationError() }
                    if let replacing, let old = accounts.first(where: { $0.id == replacing }), !old.identity.matches(identity) { throw UsageError.wrongAccount }
                    if accounts.contains(where: { $0.id != replacing && $0.identity.matches(identity) }) { message = "이미 등록된 계정입니다."; throw UsageError.wrongAccount }
                    pendingIdentity = identity; loginInProgress = false; loginStatus = "로그인된 계정 정보를 확인한 뒤 등록하세요."; loginURL = nil
                } onCancel: { client.close() }
            } catch {
                if pendingID == stage {
                    if !(error is CancellationError) { message = message ?? (error as? UsageError)?.localizedDescription ?? "로그인에 실패했습니다." }
                    clearPending(stage)
                } else { try? repository.removeHome(stage) }
            }
        }
        onLoginRequested?()
    }
    func confirmLogin() {
        guard let id = pendingID, let identity = pendingIdentity else { return }
        var newDisk = disk
        let saved = SavedAccount(id: id, alias: pendingAlias, identity: identity)
        let old = reauthTarget
        if let old, let index = newDisk.accounts.firstIndex(where: { $0.id == old }) { newDisk.accounts[index] = saved }
        else { newDisk.accounts.append(saved) }
        if newDisk.preferences.representative == old || newDisk.preferences.representative == nil { newDisk.preferences.representative = id }
        do { try repository.save(newDisk) } catch { message = "계정 등록을 저장하지 못했습니다."; return }
        disk = newDisk; pendingID = nil; pendingIdentity = nil; loginTask = nil; reauthTarget = nil; loginURL = nil
        if let old { invalidate(old); try? repository.removeHome(old) }
        selected = id; refresh(id); onStatusChanged?()
    }
    private func clearPending(_ id: UUID) {
        try? repository.removeHome(id)
        pendingID = nil; pendingIdentity = nil; loginInProgress = false; loginURL = nil; reauthTarget = nil; loginTask = nil
    }
    func cancelLogin() {
        loginTask?.cancel()
        // The running task owns cleanup after its child closes; confirmed stages can be removed now.
        if let id = pendingID, !loginInProgress { clearPending(id) }
    }
    func rename(_ id: UUID, to alias: String) {
        guard let index = disk.accounts.firstIndex(where: { $0.id == id }), !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        disk.accounts[index].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines); persist()
    }
    func move(_ id: UUID, offset: Int) {
        guard let i = disk.accounts.firstIndex(where: { $0.id == id }), disk.accounts.indices.contains(i + offset) else { return }
        disk.accounts.swapAt(i, i + offset); persist()
    }
    private func invalidate(_ id: UUID) {
        tasks[id]?.cancel(); tasks[id] = nil; revisions[id] = nil; refreshing.remove(id); queue.removeAll { $0 == id }
        errors[id] = nil; authRequired.remove(id); activityErrors[id] = nil; monthlyErrors[id] = nil
    }
    func remove(_ id: UUID) {
        guard id != reauthTarget else { message = "재인증을 취소한 뒤 제거하세요."; return }
        if demo { disk.accounts.removeAll { $0.id == id }; return }
        invalidate(id)
        do {
            try repository.removeHome(id)
            disk.accounts.removeAll { $0.id == id }
            if selected == id { selected = nil }
            if disk.preferences.representative == id { disk.preferences.representative = disk.accounts.first?.id }
            persist(); pump()
        } catch { message = "계정 저장소를 제거하지 못했습니다." }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !demo else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { message = "로그인 시 실행 설정을 변경하지 못했습니다. 시스템 설정의 로그인 항목을 확인하세요." }
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    private static func demoAccounts() -> [SavedAccount] {
        zip(["개인", "연구", "업무", "보조"], [(32.0,61.0),(12,28),(100,84),(8,19)]).enumerated().map { index, pair in
            SavedAccount(id: UUID(), alias: pair.0, identity: AccountIdentity(subject: "demo-\(index)", workspace: "Personal", email: "sample\(index + 1)@example.com", plan: index % 2 == 0 ? "pro" : "plus"),
                         quota: QuotaSnapshot(windows: [QuotaWindow(bucket: "codex", kind: "primary", used: pair.1.0, minutes: 300, reset: .now.addingTimeInterval(8280)), QuotaWindow(bucket: "codex", kind: "secondary", used: pair.1.1, minutes: 10080, reset: .now.addingTimeInterval(273600))], reached: pair.1.0 == 100))
        }
    }
}
