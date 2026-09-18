import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

public enum CodexConnection: String, CaseIterable, Sendable {
    case codex, openmodel
    public var title: String { self == .codex ? "Codex" : "OpenModel" }
    public var provider: String { self == .codex ? "openai" : "openmodel" }
    public var defaultModel: String { self == .codex ? "gpt-5.6-sol" : "gpt-6-astra" }
}

public enum ConnectionError: Error, LocalizedError {
    case format, changed, unsafePath, io, missingKey, validation, noBackup
    public var errorDescription: String? {
        switch self {
        case .format: "자동 전환할 수 없는 설정 형식입니다. config.toml의 model, model_provider 및 공급자 설정을 확인하세요."
        case .changed: "다른 곳에서 Codex 설정을 변경했습니다. 현재 설정을 다시 읽은 뒤 시도하세요."
        case .unsafePath: "설정 또는 백업 경로가 일반 파일·폴더가 아닙니다. 원본은 변경하지 않았습니다."
        case .io: "설정 파일을 저장하지 못했습니다. 파일 접근 권한과 저장 공간을 확인하세요."
        case .missingKey: "OpenModel API 키가 없습니다. 설정에서 API 키를 저장하세요."
        case .validation: "Codex CLI가 새 설정을 확인하지 못했습니다. CLI 경로와 설정 형식을 확인하세요. 원본은 유지됩니다."
        case .noBackup: "복원할 전환 기록이 없습니다."
        }
    }
}

public struct ConnectionSnapshot: Sendable {
    public let data: Data
    public let connection: CodexConnection?
    public let model: String?
}
public struct ConnectionChange: Sendable {
    public let before: Data
    public let after: Data
    public let target: CodexConnection
    public let model: String
}

/// Edits a deliberately small TOML surface. Codex itself validates the complete candidate before commit.
struct ConnectionDocument {
    struct Statement {
        var raw: String
        var table: [String]?
        var key: [String]?
        var value: String?
    }
    var statements: [Statement]
    init(_ data: Data) throws {
        guard data.count < 1_048_576, let text = String(data: data, encoding: .utf8) else { throw ConnectionError.format }
        // Group logical statements so strings, comments and multiline arrays cannot masquerade as keys/tables.
        let bytes = Array(text.utf8)
        var start = 0, i = 0, quote: UInt8?, triple = false, escaped = false, comment = false, depth = 0
        var chunks: [String] = []
        while i < bytes.count {
            let c = bytes[i]
            if comment {
                if c == 10 { comment = false }
            } else if let q = quote {
                if escaped { escaped = false }
                else if q == 34 && c == 92 { escaped = true }
                else if c == q {
                    if triple {
                        if i + 2 < bytes.count && bytes[i + 1] == q && bytes[i + 2] == q {
                            // TOML permits four/five quotes at the end of a multiline string.
                            i += 2
                            while i + 1 < bytes.count && bytes[i + 1] == q { i += 1 }
                            quote = nil; triple = false
                        }
                    } else { quote = nil }
                }
            } else if c == 35 { comment = true }
            else if c == 34 || c == 39 {
                quote = c
                triple = i + 2 < bytes.count && bytes[i + 1] == c && bytes[i + 2] == c
                if triple { i += 2 }
            } else if c == 91 || c == 123 { depth += 1 }
            else if c == 93 || c == 125 { depth -= 1; guard depth >= 0 else { throw ConnectionError.format } }
            if c == 10 && quote == nil && depth == 0 {
                chunks.append(String(decoding: bytes[start...i], as: UTF8.self)); start = i + 1
            }
            i += 1
        }
        guard quote == nil, depth == 0 else { throw ConnectionError.format }
        if start < bytes.count { chunks.append(String(decoding: bytes[start...], as: UTF8.self)) }
        statements = try chunks.map { raw in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean.hasPrefix("#") { return Statement(raw: raw) }
            if clean.hasPrefix("[") {
                let arrayTable = clean.hasPrefix("[[")
                // Find closing brackets outside quoted path components.
                var q: Character?, escape = false, end: String.Index?
                for index in clean.indices.dropFirst(arrayTable ? 2 : 1) {
                    let c = clean[index]
                    if escape { escape = false; continue }
                    if q == "\"" && c == "\\" { escape = true; continue }
                    if let current = q { if c == current { q = nil } }
                    else if c == "\"" || c == "'" { q = c }
                    else if c == "]" { end = index; break }
                }
                guard let end else { throw ConnectionError.format }
                let path = try Self.path(String(clean[clean.index(clean.startIndex, offsetBy: arrayTable ? 2 : 1)..<end]))
                return Statement(raw: raw, table: path)
            }
            var q: Character?, escape = false, equal: String.Index?
            for index in clean.indices {
                let c = clean[index]
                if escape { escape = false; continue }
                if q == "\"" && c == "\\" { escape = true; continue }
                if let current = q { if c == current { q = nil } }
                else if c == "\"" || c == "'" { q = c }
                else if c == "=" { equal = index; break }
            }
            guard let equal else { throw ConnectionError.format }
            return Statement(raw: raw, key: try Self.path(String(clean[..<equal])), value: String(clean[clean.index(after: equal)...]))
        }
    }
    static func path(_ text: String) throws -> [String] {
        let pattern = #"\s*(?:([A-Za-z0-9_-]+)|"((?:[^"\\]|\\.)*)"|'([^']*)')\s*(\.|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var offset = 0, result: [String] = []
        while offset < ns.length {
            guard let m = regex.firstMatch(in: text, range: NSRange(location: offset, length: ns.length - offset)), m.range.location == offset else { throw ConnectionError.format }
            let r = (1...3).map { m.range(at: $0) }.first { $0.location != NSNotFound }!
            let key = ns.substring(with: r)
            // Escaped keys are uncommon and are left for manual editing, never guessed.
            guard !key.contains("\\") else { throw ConnectionError.format }
            result.append(key); offset = NSMaxRange(m.range)
        }
        guard !result.isEmpty else { throw ConnectionError.format }
        return result
    }
    func rootString(_ name: String) throws -> String? {
        let roots = statements.prefix { $0.table == nil }.filter { $0.key == [name] }
        guard roots.count <= 1 else { throw ConnectionError.format }
        guard let value = roots.first?.value else { return nil }
        let pattern = #"^\s*["']([A-Za-z0-9_./:-]+)["']\s*(?:#[^\r\n]*)?[\r\n]*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { throw ConnectionError.format }
        return (value as NSString).substring(with: m.range(at: 1))
    }
    func replacing(_ target: CodexConnection, model: String) throws -> Data {
        guard !model.isEmpty, model.count <= 160, model.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil else { throw ConnectionError.format }
        _ = try rootString("model"); _ = try rootString("model_provider")
        var table: [String] = [], parts: [String] = []
        for statement in statements {
            if let header = statement.table { table = header }
            if table.isEmpty, let key = statement.key {
                if key == ["profile"] { throw ConnectionError.format }
                if key == ["model"] || key == ["model_provider"] { continue }
                if key.first == "model_providers" { throw ConnectionError.format }
            }
            // Normalize only OpenModel's provider definition. Keep all unrelated tables verbatim.
            if target == .openmodel {
                if table.starts(with: ["model_providers", "openmodel"]) { continue }
                if table == ["model_providers"], statement.key?.first == "openmodel" { throw ConnectionError.format }
            }
            parts.append(statement.raw)
        }
        var result = "model = \"\(model)\"\nmodel_provider = \"\(target.provider)\"\n" + parts.joined()
        if target == .openmodel { result += "\n" + Self.openModelProvider + "\n" }
        return Data(result.utf8)
    }
    static let openModelProvider = """
    [model_providers.openmodel]
    name = "OpenModel"
    base_url = "https://api.openmodel.ai/v1"
    wire_api = "responses"

    [model_providers.openmodel.auth]
    command = "/usr/bin/security"
    args = ["find-generic-password", "-a", "codex", "-s", "codex-openmodel-api-key", "-w"]
    """
}

public struct CodexConnectionStore: Sendable {
    public let config: URL
    public let root: URL
    public init(config: URL? = nil, root: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.config = config ?? home.appendingPathComponent("config.toml")
        let suffix = Self.hash(Data(self.config.path.utf8)).prefix(12)
        self.root = root ?? AccountRepository().root.appendingPathComponent("CodexConnections/\(suffix)")
    }
    public func snapshot() throws -> ConnectionSnapshot {
        let data = try read(config)
        let document = try ConnectionDocument(data)
        let provider = try document.rootString("model_provider") ?? "openai"
        return ConnectionSnapshot(data: data, connection: CodexConnection.allCases.first { $0.provider == provider }, model: try document.rootString("model"))
    }
    public func rememberedModel(_ connection: CodexConnection) -> String {
        guard let data = try? read(root.appendingPathComponent(connection.rawValue + ".toml")),
              let document = try? ConnectionDocument(data), let model = try? document.rootString("model") else { return connection.defaultModel }
        return model
    }
    public func plan(_ target: CodexConnection, model: String, expected: Data) throws -> ConnectionChange {
        let current = try snapshot()
        guard current.data == expected else { throw ConnectionError.changed }
        return ConnectionChange(before: current.data, after: try ConnectionDocument(current.data).replacing(target, model: model), target: target, model: model)
    }
    // Isolated CLI parsing only: never starts a model turn, copies auth.json, or invokes the API key command.
    public func validate(_ change: ConnectionChange, executable: String) async throws {
        try prepare()
        let candidate = root.appendingPathComponent("validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: candidate) }
        try write(change.after, to: candidate.appendingPathComponent("config.toml"))
        do {
            let client = try RPCClient(executable: executable, home: candidate, working: candidate)
            defer { client.close() }
            try await client.initialize()
            let data = try await client.request("config/read", params: Data(#"{"includeLayers":false}"#.utf8))
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let config = response?["config"] as? [String: Any],
                  config["model"] as? String == change.model,
                  config["model_provider"] as? String == change.target.provider else { throw ConnectionError.validation }
        } catch { throw ConnectionError.validation }
    }
    public func commit(_ change: ConnectionChange) throws {
        try locked {
            guard try read(config) == change.before else { throw ConnectionError.changed }
            let backup = "before-\(UUID().uuidString).toml"
            try write(change.before, to: root.appendingPathComponent(backup))
            if let old = try snapshot().connection { try write(change.before, to: root.appendingPathComponent(old.rawValue + ".toml")) }
            try write(change.after, to: root.appendingPathComponent(change.target.rawValue + ".toml"))
            let undo = Undo(backup: backup, appliedHash: Self.hash(change.after))
            try write(try JSONEncoder().encode(undo), to: root.appendingPathComponent("last-switch.json"))
            // Recheck after staging backups in case another editor wrote during that work.
            guard try read(config) == change.before else { throw ConnectionError.changed }
            try write(change.after, to: config)
        }
    }
    public var canUndo: Bool {
        guard let undo = try? undoRecord(), let current = try? read(config) else { return false }
        return Self.hash(current) == undo.appliedHash
    }
    public func undo() throws {
        try locked {
            let undo = try undoRecord(), current = try read(config)
            guard Self.hash(current) == undo.appliedHash else { throw ConnectionError.changed }
            let previous = try read(root.appendingPathComponent(undo.backup))
            try write(current, to: root.appendingPathComponent("before-undo-\(UUID().uuidString).toml"))
            guard try read(config) == current else { throw ConnectionError.changed }
            try write(previous, to: config)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("last-switch.json"))
        }
    }
    private struct Undo: Codable { var backup: String; var appliedHash: String }
    private func undoRecord() throws -> Undo {
        guard let data = try? read(root.appendingPathComponent("last-switch.json")), let undo = try? JSONDecoder().decode(Undo.self, from: data),
              undo.backup.hasPrefix("before-"), undo.backup.hasSuffix(".toml"), !undo.backup.contains("/"), !undo.backup.contains("..") else { throw ConnectionError.noBackup }
        return undo
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func check(_ url: URL, directory: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), info.st_uid == getuid() else { throw ConnectionError.unsafePath }
        } else if errno != ENOENT { throw ConnectionError.io }
    }
    private func read(_ url: URL) throws -> Data {
        try check(url.deletingLastPathComponent(), directory: true); try check(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 1_048_576 else { throw ConnectionError.format }
        return try Data(contentsOf: url)
    }
    private func prepare() throws {
        try check(config.deletingLastPathComponent(), directory: true); try check(config)
        try check(root.deletingLastPathComponent(), directory: true); try check(root, directory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func locked(_ body: () throws -> Void) throws {
        try prepare()
        let fd = open(root.appendingPathComponent("switch.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConnectionError.io }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConnectionError.changed }
        try body()
    }
    private func write(_ data: Data, to destination: URL) throws {
        try check(destination.deletingLastPathComponent(), directory: true); try check(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".connection-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConnectionError.io }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ConnectionError.io }; offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else { throw ConnectionError.io }
    }
}

/// Same keychain item used by the user's existing Codex external-auth command; never console login cookies.
public enum CodexOpenModelKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "codex-openmodel-api-key", kSecAttrAccount as String: "codex"]
    }
    public static var exists: Bool {
        var q = query; q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    public static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }), key.count < 8192 else { throw ConnectionError.missingKey }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.io }
        } else if status != errSecSuccess { throw ConnectionError.io }
    }
}
