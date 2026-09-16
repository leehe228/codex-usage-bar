import Foundation
import Darwin

// All stream state is protected by lock; only Data crosses into async callers.
public final class RPCClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: Data] = [:]
    private var notices: [Data] = []
    private var nextID = 0
    private var failure: UsageError?
    private var closed = false
    public init(executable: String, home: URL, working: URL, extraEnvironment: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "never", "-c", "cli_auth_credentials_store=\"file\"", "app-server", "--stdio"]
        var env: [String: String] = [:]
        for key in ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"] {
            env[key] = ProcessInfo.processInfo.environment[key]
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CODEX_HOME"] = home.path
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env; process.currentDirectoryURL = working
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.ingest(data)
        }
        // Drain stderr without retaining raw logs or token material.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do { try process.run() } catch { close(); throw UsageError.exited }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }
    deinit { close() }
    private func ingest(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        buffer.append(chunk)
        if buffer.count > 4_194_304 { failure = .oversized; buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = root["id"] as? Int, root["result"] != nil || root["error"] != nil {
                if responses.count > 100 { failure = .oversized; return }; responses[id] = line
            } else if root["method"] as? String == "account/login/completed" {
                if notices.count < 10 { notices.append(line) }
            } else if let id = root["id"] as? Int {
                // We do not offer experimental host token or attestation capabilities.
                if let data = try? JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32601, "message": "Unsupported host request"]]) {
                    try? input.fileHandleForWriting.write(contentsOf: data + Data([10]))
                }
            }
        }
    }
    private func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw UsageError.exited }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) } catch { throw UsageError.exited }
    }
    private func allocateID() -> Int { lock.withLock { nextID += 1; return nextID } }
    private func take(_ id: Int) throws -> Data? {
        try lock.withLock { if let failure { throw failure }; return responses.removeValue(forKey: id) }
    }
    public func request(_ method: String, params: Data? = nil, timeout: TimeInterval = 10) async throws -> Data {
        try Task.checkCancellation()
        let id = allocateID(); var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = try JSONSerialization.jsonObject(with: params) }
        try send(message)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let data = try take(id) {
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.malformed }
                if let error = root["error"] as? [String: Any] {
                    let text = (error["message"] as? String ?? "").lowercased()
                    if text.contains("401") || text.contains("unauthorized") || text.contains("not authenticated") || text.contains("not logged") { throw UsageError.signedOut }
                    throw UsageError.rpc(error["code"] as? Int ?? -1)
                }
                guard let result = root["result"] else { throw UsageError.malformed }
                return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            }
            guard process.isRunning else { throw UsageError.exited }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw UsageError.timedOut
    }
    public func initialize() async throws {
        _ = try await request("initialize", params: Data(#"{"clientInfo":{"name":"codex_usage_bar","title":"Codex Usage Bar","version":"0.1.6"}}"#.utf8))
        try send(["method": "initialized"])
    }
    public func waitForLogin(id: String, timeout: TimeInterval = 180) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let data: Data? = lock.withLock { notices.isEmpty ? nil : notices.removeFirst() }
            if let data, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let params = root["params"] as? [String: Any], params["loginId"] as? String == id {
                guard params["success"] as? Bool == true else { throw UsageError.signedOut }; return
            }
            guard process.isRunning else { throw UsageError.exited }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UsageError.timedOut
    }
    public func close() {
        let shouldClose = lock.withLock { if closed { return false }; closed = true; return true }
        guard shouldClose else { return }
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}

public struct CodexService: Sendable {
    public let repository: AccountRepository
    public let executable: String
    public init(repository: AccountRepository, executable: String) { self.repository = repository; self.executable = executable }
    public func client(id: UUID) throws -> RPCClient {
        try repository.validate(id)
        return try RPCClient(executable: executable, home: repository.home(id), working: repository.working)
    }
    public func identity(_ client: RPCClient, id: UUID) async throws -> AccountIdentity {
        // Unlike rateLimits/read, account/read requires an object-valued params field.
        let account = try await client.request("account/read", params: Data(#"{"refreshToken":false}"#.utf8))
        return try UsageParser.identity(authData: repository.readAuth(id), accountData: account)
    }
}
