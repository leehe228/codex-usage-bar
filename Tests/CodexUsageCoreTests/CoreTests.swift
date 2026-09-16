import Foundation
import Testing
@testable import CodexUsageCore

struct CoreTests {
    @Test func testMonthlyCreditsExactUsageZeroAndOverage() throws {
        let data = Data(#"{"current_month_usage":2107.612383723259,"effective_monthly_limit":{"limit":7000,"enforcement_mode":"HARD_CAP","limit_mode":"amount_credits"}}"#.utf8)
        let monthly = try MonthlyCreditSnapshot.parse(data, now: Date(timeIntervalSince1970: 1234))
        expectEqual(monthly.limit, 7000); expectEqual(monthly.used, 2107.612383723259)
        expectEqual(monthly.remainingPercent.rounded(), 70)
        expectEqual(monthly.fetchedAt.timeIntervalSince1970, 1234)
        expectEqual(try JSONDecoder().decode(MonthlyCreditSnapshot.self, from: JSONEncoder().encode(monthly)), monthly)
        let zero = try MonthlyCreditSnapshot.parse(Data(#"{"current_month_usage":"0","effective_monthly_limit":{"limit":"7000","enforcement_mode":"HARD_CAP","limit_mode":"amount_credits"}}"#.utf8))
        expectEqual(zero.used, 0); expectEqual(zero.remainingPercent, 100)
        let over = try MonthlyCreditSnapshot.parse(Data(#"{"current_month_usage":8000,"effective_monthly_limit":{"limit":7000,"enforcement_mode":"SOFT_CAP","limit_mode":"amount_credits"}}"#.utf8))
        expectEqual(over.used, 8000); expectEqual(over.remainingPercent, 0)
    }
    @Test func testInvalidMonthlyCreditsDoNotBecomeZero() throws {
        for used in [NSNull(), true, "NaN", -1] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["current_month_usage": used, "effective_monthly_limit": ["limit": 7000, "enforcement_mode": "HARD_CAP", "limit_mode": "amount_credits"]])
            expectThrows(try MonthlyCreditSnapshot.parse(data))
        }
        for limit in [0, true, "bad"] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["current_month_usage": 100, "effective_monthly_limit": ["limit": limit, "enforcement_mode": "HARD_CAP", "limit_mode": "amount_credits"]])
            expectThrows(try MonthlyCreditSnapshot.parse(data))
        }
        expectThrows(try MonthlyCreditSnapshot.parse(Data(#"{"current_month_usage":100,"effective_monthly_limit":{"limit":7000,"enforcement_mode":"NONE","limit_mode":"amount_credits"}}"#.utf8)))
        expectThrows(try MonthlyCreditSnapshot.parse(Data(#"{"current_month_usage":100,"effective_monthly_limit":{"limit":7000,"enforcement_mode":"HARD_CAP","limit_mode":"amount_usd"}}"#.utf8)))
    }
    @Test func testMonthlyRequestUsesOnlyMatchingEduAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AccountRepository(root: root), id = UUID()
        _ = try repository.createHome(id)
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": token(["sub": "synthetic-subject"]), "account_id": "synthetic-workspace", "access_token": "synthetic-only"]])
        try auth.write(to: repository.home(id).appendingPathComponent("auth.json"))
        let service = CodexService(repository: repository, executable: "/unused")
        let identity = AccountIdentity(subject: "synthetic-subject", workspace: "synthetic-workspace", email: nil, plan: "edu")
        let request = try service.monthlyCreditsRequest(id: id, identity: identity)
        expectEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/accounts/synthetic-workspace/spend-controls/current-user/monthly-usage")
        expectEqual(request.httpMethod, "GET")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-only")
        expectEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "synthetic-workspace")
        expectThrows(try service.monthlyCreditsRequest(id: id, identity: AccountIdentity(subject: "other-user", workspace: identity.workspace, email: nil, plan: "edu")))
        expectThrows(try service.monthlyCreditsRequest(id: id, identity: AccountIdentity(subject: identity.subject, workspace: identity.workspace, email: nil, plan: "pro")))
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","alias":"legacy","identity":{"subject":"s","workspace":"w","plan":"edu"}}"#.utf8)
        expectNil(try JSONDecoder().decode(SavedAccount.self, from: legacy).monthlyCredits)
    }
    @Test func testSparkVisibilityDefaultsMigrationAndPersistence() throws {
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        expectFalse(preferences.showCodexSpark)
        let standard = QuotaWindow(bucket: "codex", kind: "primary", used: 10, minutes: 300, reset: nil)
        let sparkByID = QuotaWindow(bucket: "codex_bengalfox", kind: "primary", used: 0, minutes: 300, reset: nil)
        let sparkByName = QuotaWindow(bucket: "another-spark-id", name: "GPT-5.3-Codex-Spark", kind: "secondary", used: 0, minutes: 10080, reset: nil)
        let other = QuotaWindow(bucket: "other", name: "Other model", kind: "primary", used: 20, minutes: 60, reset: nil)
        let reserve = QuotaWindow(bucket: "base_model_inference", name: "gpt-reserve", kind: "secondary", used: 0, minutes: 10080, reset: nil)
        let reserveByName = QuotaWindow(bucket: "another-reserve-id", name: "gpt-reserve", kind: "secondary", used: 0, minutes: 10080, reset: nil)
        let quota = QuotaSnapshot(windows: [standard, sparkByID, sparkByName, other, reserve, reserveByName])
        expectEqual(quota.visibleWindows(preferences: preferences), [standard, other])
        expectEqual(quota.windows.count, 6)
        preferences.showCodexSpark = true
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        expectTrue(restored.showCodexSpark)
        expectEqual(quota.visibleWindows(preferences: restored), [standard, sparkByID, sparkByName, other])
    }
    @Test func testMissingPreferenceDefaultsAndInvalidInterval() throws {
        let defaults = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        expectEqual(defaults.interval, 300); expectFalse(defaults.showMenuNumbers)
        let invalid = try JSONDecoder().decode(Preferences.self, from: Data(#"{"interval":-100}"#.utf8))
        expectEqual(invalid.interval, 300)
    }
    @Test func testBucketsNullAndRealDurations() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":null}},"new":{"primary":{"usedPercent":42,"windowDurationMins":15}},"broken":{"primary":{"usedPercent":"bad"}}},"rateLimitResetCredits":{"availableCount":0}}"#.utf8)
        let result = try UsageParser.quota(data)
        expectEqual(result.windows.count, 4)
        expectEqual(result.windows[0].used, 0)
        expectEqual(result.windows[0].title, "5시간")
        expectEqual(result.windows[1].title, "주간")
        expectNil(result.windows[1].reset)
        expectEqual(result.windows.first { $0.bucket == "new" }?.title, "new · 15분")
        expectNil(result.windows.first { $0.bucket == "broken" }?.used)
        expectTrue(result.reached)
        expectEqual(result.resetCreditCount, 0)
        expectEqual(result.windows[0].reset?.timeIntervalSince1970, 2000000000)
    }
    @Test func testLegacyAndInvalidPercent() throws {
        let result = try UsageParser.quota(Data(#"{"rateLimits":{"primary":{"usedPercent":-1},"secondary":{"usedPercent":101}}}"#.utf8))
        expectEqual(result.windows.count, 2)
        expectTrue(result.windows.allSatisfy { $0.used == nil })
        expectThrows(try UsageParser.quota(Data("{}".utf8)))
    }
    @Test func testBooleanIsNotAUsageNumber() throws {
        let quota = try UsageParser.quota(Data(#"{"rateLimits":{"primary":{"usedPercent":true,"resetsAt":true,"windowDurationMins":false}}}"#.utf8))
        expectNil(quota.windows[0].used); expectNil(quota.windows[0].reset); expectNil(quota.windows[0].minutes)
    }
    @Test func testActivityUnavailableIsNotZero() throws {
        let result = try UsageParser.activity(Data(#"{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":null}"#.utf8))
        expectNil(result.lifetimeTokens); expectNil(result.daily)
        let zero = try UsageParser.activity(Data(#"{"summary":{"lifetimeTokens":0},"dailyUsageBuckets":[]}"#.utf8))
        expectEqual(zero.lifetimeTokens, 0); expectEqual(zero.daily, [])
    }
    @Test func testResetDoesNotClearUsage() {
        let now = Date(timeIntervalSince1970: 2000)
        let w = QuotaWindow(bucket: "codex", kind: "primary", used: 100, minutes: 300, reset: Date(timeIntervalSince1970: 1999))
        expectEqual(w.resetDescription(now: now), "리셋 확인 중")
        expectEqual(w.used, 100)
    }
    @Test func testIdentityUsesSubjectAndWorkspace() throws {
        let jwt = token(["sub": "subject-1", "email": "a@example.com"])
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": jwt, "account_id": "workspace-1"]])
        let account = Data(#"{"account":{"type":"chatgpt","email":"a@example.com","planType":"pro"}}"#.utf8)
        let identity = try UsageParser.identity(authData: auth, accountData: account)
        expectEqual(identity.subject, "subject-1")
        expectFalse(identity.matches(AccountIdentity(subject: "subject-2", workspace: "workspace-1", email: "a@example.com", plan: "pro")))
        expectFalse(identity.matches(AccountIdentity(subject: "subject-1", workspace: "workspace-2", email: "a@example.com", plan: "pro")))
        expectThrows(try UsageParser.identity(authData: auth, accountData: Data(#"{"account":{"type":"chatgpt","email":"b@example.com"}}"#.utf8)))
    }
    private func token(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header." + payload + ".signature"
    }
    @Test func testRepositoryRoundTripAndIsolatedDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AccountRepository(root: root), a = UUID(), b = UUID()
        _ = try repo.createHome(a); _ = try repo.createHome(b)
        try Data("synthetic".utf8).write(to: repo.home(a).appendingPathComponent("auth.json"))
        expectEqual(try repo.readAuth(a), Data("synthetic".utf8))
        let perms = try FileManager.default.attributesOfItem(atPath: repo.home(a).appendingPathComponent("auth.json").path)[.posixPermissions] as? NSNumber
        expectEqual(perms?.intValue, 0o600)
        var state = DiskState()
        state.accounts = [SavedAccount(id: a, alias: "test", identity: AccountIdentity(subject: "s", workspace: "w", email: nil, plan: "unknown"))]
        try repo.save(state); expectEqual(try repo.load().accounts, state.accounts)
        try repo.removeHome(a)
        expectTrue(FileManager.default.fileExists(atPath: repo.home(b).path))
    }
    @Test func testRepositoryRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AccountRepository(root: root); try repo.prepare()
        let id = UUID(), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.home(id), withDestinationURL: outside)
        expectThrows(try repo.removeHome(id))
        expectTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

struct RPCClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_USAGE_CONTRACT_CLI"] != nil))
    func testRealCLIAccountReadContractWithoutCredentials() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CODEX_USAGE_CONTRACT_CLI"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = AccountRepository(root: root), id = UUID()
        _ = try repository.createHome(id)
        let service = CodexService(repository: repository, executable: executable)
        let client = try service.client(id: id)
        defer { client.close(); try? FileManager.default.removeItem(at: root) }
        try await client.initialize()
        do { _ = try await client.request("account/read"); fail("Expected missing params to be rejected") }
        catch { expectEqual(error as? UsageError, .rpc(-32600)) }
        // The production identity path must reach the credential check, not a protocol error.
        do { _ = try await service.identity(client, id: id); fail("Expected empty test home to be signed out") }
        catch { expectEqual(error as? UsageError, .signedOut) }
        expectFalse(FileManager.default.fileExists(atPath: repository.home(id).appendingPathComponent("auth.json").path))
    }
    func fixture() throws -> (URL, RPCClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,time,os
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            method=m['method']
            if method=='slow': time.sleep(3)
            if method=='exit': sys.exit(0)
            if method=='error':
                print(json.dumps({'id':m['id'],'error':{'code':-32601,'message':'not supported'}}),flush=True)
                continue
            if method=='flood':
                sys.stderr.write('x'*200000);sys.stderr.flush()
            result={'ok':True}
            if method=='environment': result={'home':os.environ['CODEX_HOME']}
            if method=='account/read':
                if m.get('params') != {'refreshToken':False}:
                    print(json.dumps({'id':m['id'],'error':{'code':-32600,'message':'Invalid request: missing or invalid params'}}),flush=True)
                    continue
                result={'account':{'type':'chatgpt','email':'synthetic@example.com','planType':'pro'}}
            if method=='account/login/start': result={'loginId':'fake-login','authUrl':'https://auth.openai.com/example'}
            print(json.dumps({'method':'irrelevant/notification','params':{}}),flush=True)
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
            if method=='account/login/start':
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'fake-login','success':True}}),flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = try RPCClient(executable: executable.path, home: root, working: root)
        return (root, client)
    }
    @Test func testPostLoginIdentityUsesRequiredAccountParameters() async throws {
        let (root, client) = try fixture()
        defer { client.close(); try? FileManager.default.removeItem(at: root) }
        let repository = AccountRepository(root: root), id = UUID()
        _ = try repository.createHome(id)
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "synthetic-subject", "email": "synthetic@example.com"])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "header.\(payload).signature", "account_id": "synthetic-workspace"]])
        try auth.write(to: repository.home(id).appendingPathComponent("auth.json"))
        try await client.initialize()
        _ = try await client.request("account/login/start", params: Data(#"{"type":"chatgpt"}"#.utf8))
        try await client.waitForLogin(id: "fake-login", timeout: 2)
        let service = CodexService(repository: repository, executable: root.appendingPathComponent("fake-codex").path)
        let identity = try await service.identity(client, id: id)
        expectEqual(identity.subject, "synthetic-subject")
        expectEqual(identity.workspace, "synthetic-workspace")
        expectEqual(identity.email, "synthetic@example.com")
        expectEqual(identity.plan, "pro")
    }
    @Test func testInitializeNotificationsAndStderrFlood() async throws {
        let (root, client) = try fixture()
        defer { client.close(); try? FileManager.default.removeItem(at: root) }
        try await client.initialize()
        let response = try await client.request("flood")
        expectTrue(String(decoding: response, as: UTF8.self).contains("true"))
        _ = try await client.request("account/login/start")
        try await client.waitForLogin(id: "fake-login", timeout: 2)
        do { _ = try await client.request("error"); fail("Expected unsupported") }
        catch { expectEqual(error as? UsageError, .rpc(-32601)) }
    }
    @Test func testTimeoutAndCancellationAreBounded() async throws {
        let (root, client) = try fixture()
        defer { client.close(); try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.request("slow", timeout: 0.15); fail("Expected timeout") }
        catch { expectEqual(error as? UsageError, .timedOut) }
        let task = Task { try await client.request("slow") }
        task.cancel()
        do { _ = try await task.value; fail("Expected cancellation") } catch { expectTrue(error is CancellationError) }
    }
    @Test func testTwoClientsKeepSeparateHomes() async throws {
        let (a, first) = try fixture(), (b, second) = try fixture()
        defer { first.close(); second.close(); try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let one = try await first.request("environment"), two = try await second.request("environment")
        let homeOne = (try JSONSerialization.jsonObject(with: one) as? [String: String])?["home"]
        let homeTwo = (try JSONSerialization.jsonObject(with: two) as? [String: String])?["home"]
        expectEqual(homeOne, a.path); expectEqual(homeTwo, b.path); expectFalse(homeOne == homeTwo)
    }
    @Test func testProcessExitIsReported() async throws {
        let (root, client) = try fixture()
        defer { client.close(); try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.request("exit"); fail("Expected exit") }
        catch { expectEqual(error as? UsageError, .exited) }
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
private func expectTrue(_ v: Bool) { #expect(v) }
private func expectFalse(_ v: Bool) { #expect(!v) }
private func expectNil<T>(_ v: T?) { #expect(v == nil) }
private func fail(_ message: String) { Issue.record(Comment(rawValue: message)) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); Issue.record("Expected an error") } catch {}
}
