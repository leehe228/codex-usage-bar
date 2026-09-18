import AppKit
import CodexUsageCore
import Observation
import SwiftUI

@MainActor @Observable
final class ConnectionModel {
    var snapshot: ConnectionSnapshot?
    var codexModel = CodexConnection.codex.defaultModel
    var openModel = CodexConnection.openmodel.defaultModel
    var hasKey = false
    var busy = false
    var canUndo = false
    var message: String?
    var failed = false
    let demo: Bool
    @ObservationIgnored let store = CodexConnectionStore()
    @ObservationIgnored var onChanged: (() -> Void)?
    init(demo: Bool) {
        self.demo = demo
        if !demo {
            codexModel = store.rememberedModel(.codex)
            openModel = store.rememberedModel(.openmodel)
            refresh()
            if let snapshot, let current = snapshot.connection, let model = snapshot.model {
                if current == .codex { codexModel = model } else { openModel = model }
            }
        }
    }
    var currentTitle: String { demo ? "Codex" : snapshot?.connection?.title ?? "확인 필요" }
    func refresh() {
        guard !demo else { return }
        do { snapshot = try store.snapshot(); canUndo = store.canUndo }
        catch { snapshot = nil; canUndo = false; report(error) }
        hasKey = CodexOpenModelKey.exists
    }
    func select(_ target: CodexConnection, cli: String?) {
        guard !demo, !busy else { return }
        busy = true; message = nil
        let name = (target == .codex ? codexModel : openModel).trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false; refresh(); onChanged?() }
            do {
                guard let snapshot else { throw ConnectionError.format }
                guard target != .openmodel || CodexOpenModelKey.exists else { throw ConnectionError.missingKey }
                guard let cli else { throw ConnectionError.validation }
                let change = try store.plan(target, model: name, expected: snapshot.data)
                try await store.validate(change, executable: cli)
                try store.commit(change)
                failed = false
                message = "\(target.title) 설정으로 전환했습니다. Codex 앱을 재시작하고 새 작업에서 사용하세요."
            } catch { report(error) }
        }
    }
    func undo() {
        guard !demo, !busy else { return }
        do {
            try store.undo(); failed = false
            message = "전환 직전 설정을 복원했습니다. Codex 앱을 재시작하세요."
        } catch { report(error) }
        refresh(); onChanged?()
    }
    func saveKey(_ key: String) {
        guard !demo, !busy else { return }
        do { try CodexOpenModelKey.save(key); failed = false; message = "API 키를 키체인에 저장했습니다." }
        catch { report(error) }
        refresh()
    }
    private func report(_ error: Error) {
        failed = true
        message = (error as? ConnectionError)?.localizedDescription ?? "Codex 설정을 읽거나 저장하지 못했습니다. 경로와 접근 권한을 확인하세요."
    }
}

struct ConnectionButtons: View {
    @Bindable var connection: ConnectionModel
    var cli: String?
    var body: some View {
        HStack(spacing: 7) {
            ForEach(CodexConnection.allCases, id: \.self) { target in
                let active = connection.snapshot?.connection == target || (connection.demo && target == .codex)
                Button { connection.select(target, cli: cli) } label: {
                    HStack(spacing: 4) {
                        if active { Image(systemName: "checkmark.circle.fill") }
                        Text(target.title)
                    }.frame(maxWidth: .infinity)
                }
                .tint(active ? .purple : .gray)
                .buttonStyle(.bordered)
                .help("Codex의 기본 연결을 \(target.title)(으)로 전환")
            }
            if connection.busy { ProgressView().controlSize(.small) }
        }.disabled(connection.demo || connection.busy || connection.snapshot == nil)
    }
}

struct ConnectionSettings: View {
    @Bindable var connection: ConnectionModel
    var cli: String?
    @State private var apiKey = ""
    @State private var editingKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex 연결 전환").font(.headline)
                Spacer()
                Text("현재 설정: \(connection.currentTitle)").foregroundStyle(.secondary)
                Button { connection.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("설정 다시 읽기")
            }
            ConnectionButtons(connection: connection, cli: cli)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 모델 · 기존 ChatGPT 로그인").font(.caption).foregroundStyle(.secondary)
                    TextField("Codex 모델", text: $connection.codexModel)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenModel 모델 · API 요금 사용").font(.caption).foregroundStyle(.secondary)
                    TextField("OpenModel 모델", text: $connection.openModel)
                }
            }.textFieldStyle(.roundedBorder)
            Text("위 버튼을 누르면 해당 모델과 연결을 적용합니다. 실행 중인 Codex 앱은 재시작하고 새 작업을 여세요. CLI의 다음 실행부터는 변경된 기본 설정을 읽습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(connection.hasKey ? "OpenModel API 키 저장됨" : "OpenModel API 키 필요", systemImage: connection.hasKey ? "key.fill" : "key")
                    .font(.caption)
                Spacer()
                Button(connection.hasKey ? "키 변경" : "키 등록") { editingKey.toggle() }.controlSize(.small)
            }
            if editingKey {
                HStack {
                    SecureField("OpenModel API 키 붙여넣기", text: $apiKey)
                    Button("키체인에 저장") {
                        connection.saveKey(apiKey)
                        if !connection.failed { apiKey = ""; editingKey = false }
                    }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("사용량 조회용 계정 로그인과 별개입니다. API 키는 설정 파일에 쓰지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("직전 전환 되돌리기") { connection.undo() }.disabled(!connection.canUndo)
                Button("백업 폴더 열기") { NSWorkspace.shared.open(connection.store.root) }
                    .disabled(!FileManager.default.fileExists(atPath: connection.store.root.path))
            }.controlSize(.small)
            Text(connection.store.config.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            if let message = connection.message {
                Text(message).font(.caption).foregroundStyle(connection.failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .disabled(connection.demo || connection.busy)
            .onDisappear { apiKey = "" }
    }
}
