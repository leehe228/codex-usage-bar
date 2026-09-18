import Foundation
import Testing
@testable import CodexUsageCore

struct CodexConnectionTests {
    let source = """
    # Existing settings
    model = "gpt-6-astra" # selected model
    model_provider = "openmodel"
    notify = [
      "helper", # model_provider = 'fake'
      "arg"
    ]
    model_instructions_file = "/tmp/instructions.md"
    [model_providers.openmodel]
    name = "OpenModel"
    base_url = "https://api.openmodel.ai/v1"
    wire_api = "responses"
    [model_providers.openmodel.auth]
    command = "/usr/bin/security"
    args = ["find-generic-password", "-a", "codex", "-s", "codex-openmodel-api-key", "-w"]
    [projects."/tmp/example"]
    trust_level = "trusted"
    [mcp_servers.example]
    command = "test-server"
    """
    private func fixture(_ text: String) throws -> (URL, CodexConnectionStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        try Data(text.utf8).write(to: config)
        return (root, CodexConnectionStore(config: config, root: root.appendingPathComponent("profiles")))
    }
    @Test func switchesPreserveCommonSettingsAndRestoreExactOriginal() throws {
        let (root, store) = try fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try store.snapshot()
        #expect(original.connection == .openmodel)
        let change = try store.plan(.codex, model: "gpt-5.6-sol", expected: original.data)
        try store.commit(change)
        #expect(try store.snapshot().connection == .codex)
        #expect(String(decoding: change.after, as: UTF8.self).contains("[mcp_servers.example]\ncommand = \"test-server\""))
        #expect(store.rememberedModel(.openmodel) == "gpt-6-astra")
        #expect(store.canUndo)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.config.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try store.undo()
        #expect(try Data(contentsOf: store.config) == original.data)
        #expect(!store.canUndo)
    }
    @Test func externalChangesArePreservedBeforeCommitAndUndo() throws {
        let (root, store) = try fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try store.snapshot().data
        let change = try store.plan(.codex, model: "gpt-5.6-sol", expected: before)
        let edited = before + Data("\n# external edit".utf8)
        try edited.write(to: store.config)
        #expect(throws: ConnectionError.self) { try store.commit(change) }
        #expect(throws: ConnectionError.self) { try store.plan(.codex, model: "gpt-5.6-sol", expected: before) }
        #expect(try Data(contentsOf: store.config) == edited)
        let next = try store.plan(.codex, model: "gpt-5.6-sol", expected: edited)
        try store.commit(next)
        let later = next.after + Data("\n# edited after switch".utf8)
        try later.write(to: store.config)
        #expect(!store.canUndo)
        #expect(throws: ConnectionError.self) { try store.undo() }
        #expect(try Data(contentsOf: store.config) == later)
    }
    @Test func multilineValuesAndQuotedKeysCannotSpoofRootSettings() throws {
        let input = #"""
        "model" = 'old-model'
        'model_provider' = "openai"
        instructions = """
        [model_providers.openmodel]
        model = "not-a-setting"
        """
        [projects.'with.dot']
        model = "keep-this"
        """#
        let document = try ConnectionDocument(Data(input.utf8))
        let output = try document.replacing(.openmodel, model: "gpt-6-astra")
        let parsed = try ConnectionDocument(output)
        #expect(try parsed.rootString("model_provider") == "openmodel")
        #expect(try parsed.rootString("model") == "gpt-6-astra")
        #expect(String(decoding: output, as: UTF8.self).contains("model = \"not-a-setting\""))
        #expect(String(decoding: output, as: UTF8.self).contains("model = \"keep-this\""))
    }
    @Test func providerNormalizationRemovesConflictingAuthOnlyForOpenModel() throws {
        let input = """
        model = "old"
        model_provider = "openai"
        [model_providers."openmodel"]
        env_key = "OLD_KEY"
        experimental_bearer_token = "fixture-secret"
        [model_providers.another]
        base_url = "https://example.test"
        """
        let output = String(decoding: try ConnectionDocument(Data(input.utf8)).replacing(.openmodel, model: "gpt-6-astra"), as: UTF8.self)
        #expect(!output.contains("fixture-secret"))
        #expect(!output.contains("OLD_KEY"))
        #expect(output.contains("[model_providers.another]"))
        #expect(output.components(separatedBy: "[model_providers.openmodel]").count == 2)
    }
    @Test func ambiguousSettingsAndInjectedModelsAreRejected() throws {
        for source in ["model='a'\nmodel='b'", "profile='work'", "model_providers = {}", "model = [1]", "model='unterminated"] {
            #expect(throws: (any Error).self) { try ConnectionDocument(Data(source.utf8)).replacing(.openmodel, model: "gpt-6-astra") }
        }
        #expect(throws: ConnectionError.self) { try ConnectionDocument(Data()).replacing(.codex, model: "bad\"\nprovider=\"other") }
    }
    @Test func symlinksAndUnsafeBackupRecordsCannotOverwriteOtherFiles() throws {
        let (root, store) = try fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("other.toml")
        try Data(source.utf8).write(to: target)
        try FileManager.default.removeItem(at: store.config)
        try FileManager.default.createSymbolicLink(at: store.config, withDestinationURL: target)
        #expect(throws: ConnectionError.self) { try store.snapshot() }
        #expect(try Data(contentsOf: target) == Data(source.utf8))
    }
    @Test(.enabled(if: CLILocator.resolve() != nil)) func nativeCLIValidatesBothProvidersWithoutModelRequests() async throws {
        let cli = try #require(CLILocator.resolve())
        let (root, store) = try fixture(source.replacingOccurrences(of: "model_instructions_file = \"/tmp/instructions.md\"\n", with: ""))
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try store.snapshot().data
        for target in CodexConnection.allCases {
            let change = try store.plan(target, model: target.defaultModel, expected: try store.snapshot().data)
            try await store.validate(change, executable: cli)
            try store.commit(change)
            #expect(try store.snapshot().connection == target)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("profiles/openmodel.toml")) != original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path))
        let active = try store.snapshot().data
        let invalid = ConnectionChange(before: active, after: Data("model = \"duplicate-model\"\n".utf8) + active, target: .openmodel, model: "gpt-6-astra")
        await #expect(throws: ConnectionError.self) { try await store.validate(invalid, executable: cli) }
        #expect(try store.snapshot().data == active)

    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_USAGE_TEST_CONNECTION_CONFIG"] != nil))
    func localConfigurationCopyValidatesWithoutChangingOriginal() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CODEX_USAGE_TEST_CONNECTION_CONFIG"])
        let originalURL = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: originalURL)
        let cli = try #require(CLILocator.resolve())
        let (root, store) = try fixture(String(decoding: original, as: UTF8.self))
        defer { try? FileManager.default.removeItem(at: root) }
        for target in CodexConnection.allCases {
            let change = try store.plan(target, model: target.defaultModel, expected: try store.snapshot().data)
            try await store.validate(change, executable: cli)
            try store.commit(change)
            #expect(try store.snapshot().connection == target)
            try store.undo()
            #expect(try Data(contentsOf: store.config) == original)
        }
        #expect(try Data(contentsOf: originalURL) == original)
    }

}
