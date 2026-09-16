import Foundation

public struct AccountRepository: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexUsageBar", isDirectory: true)
    }
    public func prepare() throws {
        try directory(root)
        try directory(root.appendingPathComponent("accounts", isDirectory: true))
        try directory(root.appendingPathComponent("working", isDirectory: true))
    }
    public func home(_ id: UUID) -> URL { root.appendingPathComponent("accounts").appendingPathComponent(id.uuidString, isDirectory: true) }
    public var working: URL { root.appendingPathComponent("working", isDirectory: true) }
    public func createHome(_ id: UUID) throws -> URL {
        try prepare(); let url = home(id)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw UsageError.unsafeHome }
        try directory(url)
        let config = """
        cli_auth_credentials_store = "file"
        [analytics]
        enabled = false
        [feedback]
        enabled = false
        """
        try Data(config.utf8).write(to: url.appendingPathComponent("config.toml"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.appendingPathComponent("config.toml").path)
        return url
    }
    public func validate(_ id: UUID) throws {
        let url = home(id), parent = root.appendingPathComponent("accounts").resolvingSymlinksInPath().standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL == parent.appendingPathComponent(id.uuidString).standardizedFileURL else { throw UsageError.unsafeHome }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw UsageError.unsafeHome }
    }
    public func readAuth(_ id: UUID) throws -> Data {
        try validate(id); let auth = home(id).appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else { throw UsageError.signedOut }
        guard try auth.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw UsageError.unsafeHome }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let size = try auth.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 1_048_576 else { throw UsageError.oversized }
        return try Data(contentsOf: auth)
    }
    public func removeHome(_ id: UUID) throws {
        guard FileManager.default.fileExists(atPath: home(id).path) else { return }
        try validate(id); try FileManager.default.removeItem(at: home(id))
    }
    public func load() throws -> DiskState {
        try prepare(); let url = root.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return DiskState() }
        let state = try JSONDecoder().decode(DiskState.self, from: Data(contentsOf: url))
        guard state.version == 1, Set(state.accounts.map(\.id)).count == state.accounts.count else { throw UsageError.malformed }
        return state
    }
    public func save(_ state: DiskState) throws {
        try prepare(); let data = try JSONEncoder().encode(state)
        let url = root.appendingPathComponent("accounts.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw UsageError.unsafeHome }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public enum CLILocator {
    public static func resolve(custom: String = "") -> String? {
        let fm = FileManager.default
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? custom : nil }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
            + ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
