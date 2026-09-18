import AppKit
import Charts
import CodexUsageCore
import SwiftUI

private let usagePurple = Color(red: 0.43, green: 0.35, blue: 0.83)

struct UsagePopover: View {
    @Bindable var model: AppModel
    var add: () -> Void
    var settings: () -> Void
    var height: CGFloat? = nil
    var scrollContent = false
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(usagePurple)
                    Text("Codex").font(.title3.bold())
                    Spacer()
                    if !model.refreshing.isEmpty { ProgressView().controlSize(.small) }
                    Button { model.refreshAll() } label: { Label("새로고침", systemImage: "arrow.clockwise") }.controlSize(.small).disabled(model.demo)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        tab("전체", id: nil)
                        ForEach(model.accounts) { tab($0.alias, id: $0.id) }
                    }.padding(4)
                }.frame(height: 36).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }.padding(compact ? 14 : 18)
            if model.demo { Text("미리보기 · 모든 계정과 사용량은 샘플입니다").font(.caption).foregroundStyle(.orange).padding(.bottom, 8) }
            if model.storageUnavailable { Text(model.message ?? "저장소를 읽지 못했습니다.").font(.caption).foregroundStyle(.red).padding() }
            if scrollContent { ScrollView { usageContent } }
            else { usageContent.fixedSize(horizontal: false, vertical: true) }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: add) { Label("계정 추가", systemImage: "plus") }
                        .buttonStyle(FooterButtonStyle(prominent: true))
                        .disabled(model.demo || model.storageUnavailable)
                    Button(action: settings) { Label("계정 관리", systemImage: "person.2") }
                        .buttonStyle(FooterButtonStyle())
                }
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(URL(string: "https://status.openai.com/")!) } label: {
                        Label("서비스 상태", systemImage: "arrow.up.right.square")
                    }.help("OpenAI 상태 페이지 열기")
                    Button(action: settings) { Label("설정", systemImage: "gearshape") }
                    Button { NSApp.terminate(nil) } label: { Label("종료", systemImage: "power") }
                }.buttonStyle(FooterButtonStyle())
            }.padding(.horizontal, 18).padding(.vertical, compact ? 10 : 12)
        }.frame(width: 420, height: height).background(.regularMaterial)
    }
    @ViewBuilder private var usageContent: some View {
        if model.accounts.isEmpty {
            ContentUnavailableView("등록된 계정이 없습니다", systemImage: "person.crop.circle.badge.plus", description: Text("ChatGPT 계정을 추가해 Codex 사용량을 확인하세요.")).frame(height: 200)
        } else if let selected = model.selected, let account = model.accounts.first(where: { $0.id == selected }) {
            AccountDetail(model: model, account: account, reauthenticate: { settings() }).padding(.horizontal, 18)
        } else {
            VStack(spacing: compact ? 6 : 9) {
                HStack { Text("\(model.accounts.count)개 계정"); Spacer(); Text("사용한 비율을 계정별로 확인") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 3)
                ForEach(model.accounts) { a in
                    Button { model.selected = a.id } label: { AccountCard(model: model, account: a, compact: compact) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 15).padding(.bottom, 12)
        }
    }
    private func tab(_ name: String, id: UUID?) -> some View {
        Button { model.selected = id } label: {
            Text(name).font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 13).padding(.vertical, 8)
                .foregroundStyle(model.selected == id ? .white : .primary)
                .background(model.selected == id ? usagePurple : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(model.selected == id ? .isSelected : [])
    }
}
private struct FooterButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonSurface(label: configuration.label, prominent: prominent, pressed: configuration.isPressed)
    }
}
private struct FooterButtonSurface<Label: View>: View {
    var label: Label
    var prominent: Bool
    var pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        label.font(.system(size: 13, weight: .medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(enabled ? (prominent ? Color.white : Color.primary) : Color.secondary)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent && enabled ? usagePurple.opacity(0.8) : Color.primary.opacity(hovered && enabled ? 0.25 : 0.13)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
    private var background: Color {
        if prominent && enabled { return usagePurple.opacity(pressed ? 0.75 : hovered ? 0.9 : 1) }
        if !enabled { return Color.primary.opacity(0.04) }
        return pressed ? Color.primary.opacity(0.14) : hovered ? Color.primary.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.8)
    }
}
struct AccountCard: View {
    var model: AppModel
    var account: SavedAccount
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack {
                Text(account.alias).font(.subheadline.bold())
                Spacer(); Text(account.identity.plan.capitalized).font(.caption).foregroundStyle(.secondary)
                StateLabel(model: model, account: account)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            if let quota = account.quota {
                let windows = quota.visibleWindows(preferences: model.disk.preferences)
                ForEach(Array(windows.prefix(2))) { w in
                    VStack(spacing: compact ? 2 : 4) {
                        HStack(spacing: 9) {
                            Text(w.title).font(.caption).frame(width: 65, alignment: .leading).lineLimit(1)
                            UsageTrack(window: w, remaining: model.disk.preferences.remaining)
                            Text(percent(w.used, remaining: model.disk.preferences.remaining)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                        }
                        HStack { Spacer(); Text(w.resetDescription(now: model.now)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if windows.isEmpty { Text("표시할 기간별 한도가 없습니다.").font(.caption).foregroundStyle(.secondary) }
                if model.errors[account.id] != nil { Text("이전 값 · \(quota.fetchedAt.formatted(date: .omitted, time: .shortened)) 조회").font(.caption2).foregroundStyle(.orange) }
            } else {
                Text(model.errors[account.id] ?? "첫 사용량을 확인하고 있습니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if account.identity.isEdu {
                if let monthly = account.monthlyCredits {
                    VStack(spacing: compact ? 2 : 4) {
                        HStack(spacing: 9) {
                            Text("월간 크레딧").font(.caption).frame(width: 65, alignment: .leading)
                            UsageTrack(window: monthlyWindow(monthly), remaining: model.disk.preferences.remaining, tint: .blue)
                                .accessibilityLabel("월간 크레딧 \(percent(monthly.usedPercent, remaining: model.disk.preferences.remaining))")
                            Text(percent(monthly.usedPercent, remaining: model.disk.preferences.remaining)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                        }
                        Text(creditSummary(monthly)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    Text(model.refreshing.contains(account.id) ? "월간 크레딧 확인 중" : "월간 크레딧 미확인").font(.caption).foregroundStyle(.secondary)
                }
                if model.monthlyErrors[account.id] != nil { Text("월간 조회 실패 · 마지막 확인 값").font(.caption2).foregroundStyle(.orange) }
            }
        }.padding(compact ? 10 : 12).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
            .accessibilityElement(children: .combine)
    }
}
struct StateLabel: View {
    var model: AppModel
    var account: SavedAccount
    var body: some View {
        let status = model.status(account)
        Label(status, systemImage: status == "정상 조회" ? "checkmark.circle.fill" : status == "조회 중" ? "arrow.clockwise" : "exclamationmark.circle.fill")
            .font(.system(size: 10)).foregroundStyle(status == "정상 조회" ? .green : model.authRequired.contains(account.id) ? .red : .orange)
    }
}
struct UsageTrack: View {
    var window: QuotaWindow
    var remaining: Bool
    var tint: Color = usagePurple
    var body: some View {
        GeometryReader { geo in
            let raw = window.used ?? 0
            let value = remaining ? 100 - raw : raw
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if window.used != nil { Capsule().fill(raw >= 100 ? .red : raw >= 80 ? .orange : tint).frame(width: geo.size.width * value / 100) }
            }
        }.frame(height: 6).accessibilityLabel("\(window.title) \(percent(window.used, remaining: remaining))")
    }
}
private func percent(_ used: Double?, remaining: Bool = false) -> String {
    guard let used else { return "미제공" }
    return "\(Int((remaining ? 100 - used : used).rounded()))% \(remaining ? "남음" : "사용")"
}
private func monthlyWindow(_ monthly: MonthlyCreditSnapshot) -> QuotaWindow {
    QuotaWindow(bucket: "codex", kind: "monthly", used: monthly.usedPercent, minutes: nil, reset: nil)
}
private func creditSummary(_ monthly: MonthlyCreditSnapshot) -> String {
    "\(monthly.limit.formatted(.number.precision(.fractionLength(0)))) 크레딧 중 \(monthly.used.formatted(.number.precision(.fractionLength(0)))) 크레딧 사용"
}
struct AccountDetail: View {
    var model: AppModel
    var account: SavedAccount
    var reauthenticate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(account.alias).font(.title3.bold()); Spacer(); Text(account.identity.plan.capitalized).font(.caption).foregroundStyle(.secondary) }
            Text(model.disk.preferences.hideEmail ? "이메일 숨김" : account.identity.email ?? "이메일 미제공").font(.caption).foregroundStyle(.secondary)
            StateLabel(model: model, account: account)
            if let error = model.errors[account.id] {
                Text(error).font(.caption).foregroundStyle(.orange)
                if model.authRequired.contains(account.id) { Button("계정 관리에서 재인증", action: reauthenticate).controlSize(.small) }
                else { Button("다시 조회") { model.refresh(account.id) }.controlSize(.small) }
            }
            if let quota = account.quota {
                let windows = quota.visibleWindows(preferences: model.disk.preferences)
                Text("마지막 성공 조회: \(quota.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                ForEach(windows) { w in
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        HStack { Text(w.title).font(.subheadline.bold()); Spacer(); Text(percent(w.used, remaining: model.disk.preferences.remaining)).font(.title3.bold().monospacedDigit()) }
                        UsageTrack(window: w, remaining: model.disk.preferences.remaining)
                        HStack { Text(percent(w.used, remaining: !model.disk.preferences.remaining)); Spacer(); Text(w.resetDescription(now: model.now)) }.font(.caption).foregroundStyle(.secondary)
                        if let reset = w.reset { Text(reset.formatted(.dateTime.year().month().day().hour().minute().timeZone())).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing) }
                    }
                }
                if windows.isEmpty { Text("표시할 기간별 한도가 없습니다.").font(.caption).foregroundStyle(.secondary) }
            }
            if account.identity.isEdu {
                Divider()
                HStack {
                    Text("월간 사용 한도").font(.subheadline.bold())
                    Spacer()
                    if let monthly = account.monthlyCredits { Text(percent(monthly.usedPercent, remaining: model.disk.preferences.remaining)).font(.title3.bold().monospacedDigit()) }
                }
                if let monthly = account.monthlyCredits {
                    UsageTrack(window: monthlyWindow(monthly), remaining: model.disk.preferences.remaining, tint: .blue)
                        .accessibilityLabel("월간 크레딧 \(percent(monthly.usedPercent, remaining: model.disk.preferences.remaining))")
                    Text(creditSummary(monthly)).font(.caption).foregroundStyle(.secondary)
                    Text("월간 집계 · 마지막 확인: \(monthly.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                } else { Text(model.refreshing.contains(account.id) ? "월간 크레딧을 확인하고 있습니다." : "아직 월간 크레딧을 확인하지 못했습니다.").font(.caption).foregroundStyle(.secondary) }
                if let error = model.monthlyErrors[account.id] { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Divider(); Text("누적 토큰").font(.subheadline.bold())
            if let activity = account.activity {
                Text(activity.lifetimeTokens.map { $0.formatted() } ?? "제공되지 않음").font(.title2.bold().monospacedDigit())
                Text("서버 제공 활동 집계 · \(activity.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                if let daily = activity.daily, !daily.isEmpty {
                    Chart(Array(daily.suffix(7))) { day in BarMark(x: .value("날짜", String(day.startDate.suffix(5))), y: .value("토큰", day.tokens)).foregroundStyle(usagePurple.opacity(0.7)) }.frame(height: 100)
                }
            } else { Text("제공되지 않음").font(.caption).foregroundStyle(.secondary) }
            if let error = model.activityErrors[account.id] { Text(error).font(.caption2).foregroundStyle(.secondary) }
        }.padding(.bottom, 18)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var add: () -> Void
    var usage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Codex Usage Bar 설정").font(.title2.bold()); Spacer(); Button("계정 추가", action: add).disabled(model.demo || model.storageUnavailable) }
            if model.demo { Text("미리보기 모드에서는 실제 계정과 설정을 변경하지 않습니다.").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.accounts) { a in AccountSettingsRow(model: model, account: a) }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("메뉴 막대 표시 계정").font(.headline)
                        Text("선택한 계정의 주간 남은 비율을 계정 순서대로 세로 막대에 표시합니다. 주간 한도가 없으면 5시간 한도를 사용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 7) {
                            ForEach(model.accounts) { account in
                                Toggle(account.alias, isOn: Binding(
                                    get: { model.disk.preferences.showsInMenuBar(account.id) },
                                    set: { model.setMenuBarAccount(account.id, visible: $0) }
                                ))
                                .toggleStyle(.checkbox)
                                .disabled(model.disk.preferences.showsInMenuBar(account.id) && !model.canHideMenuBarAccount(account.id))
                            }
                        }
                    }
                    Divider()
                    Picker("메뉴 막대 대표 계정", selection: $model.disk.preferences.representative) {
                        Text("선택 안 함").tag(UUID?.none)
                        ForEach(model.accounts) { Text($0.alias).tag(Optional($0.id)) }
                    }
                    Picker("자동 갱신", selection: $model.disk.preferences.interval) {
                        Text("수동").tag(0); Text("1분").tag(60); Text("2분").tag(120); Text("5분").tag(300); Text("15분").tag(900)
                    }
                    Toggle("메뉴 막대에 대표 계정 사용률 표시", isOn: $model.disk.preferences.showMenuNumbers)
                    Toggle("남은 비율로 미터 표시", isOn: $model.disk.preferences.remaining)
                    Toggle("GPT-5.3-Codex-Spark 사용량 표시", isOn: $model.disk.preferences.showCodexSpark)
                    Toggle("이메일 가리기", isOn: $model.disk.preferences.hideEmail)
                    Toggle("로그인 시 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).disabled(model.demo)
                    Divider()
                    Text("Codex CLI").font(.headline)
                    HStack {
                        TextField("자동 검색 또는 실행 파일 절대 경로", text: $model.disk.preferences.cliPath)
                        Button("찾기…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { model.disk.preferences.cliPath = url.path; model.persist() }
                        }
                    }
                    Text(model.cli ?? "설치된 Codex CLI를 찾지 못했습니다.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("계정 인증은 앱 전용 저장소의 파일에 보관되며 Codex CLI가 관리합니다. 기본 Codex 로그인은 교체하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("앱 저장소 열기") { NSWorkspace.shared.open(model.repository.root) }
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
                }.padding(.trailing, 5)
            }
            HStack { Button("사용량 보기", action: usage); Text("v0.1.7 · macOS 14+").font(.caption).foregroundStyle(.secondary); Spacer(); Button("저장") { model.persist() } }
        }.padding(24).frame(width: 620, height: 620)
        .onChange(of: model.disk.preferences.representative) { model.persist() }
        .onChange(of: model.disk.preferences.interval) { model.persist() }
        .onChange(of: model.disk.preferences.showMenuNumbers) { model.persist() }
        .onChange(of: model.disk.preferences.remaining) { model.persist() }
        .onChange(of: model.disk.preferences.showCodexSpark) { model.persist() }
        .onChange(of: model.disk.preferences.hideEmail) { model.persist() }
    }
}
struct AccountSettingsRow: View {
    var model: AppModel
    var account: SavedAccount
    @State private var alias = ""
    @State private var confirmingRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("계정 별칭", text: $alias).onSubmit { model.rename(account.id, to: alias) }.frame(maxWidth: 160)
                Button("이름 저장") { model.rename(account.id, to: alias) }.controlSize(.small)
                Spacer(); StateLabel(model: model, account: account)
            }
            Text(model.disk.preferences.hideEmail ? "이메일 숨김" : account.identity.email ?? "이메일 미제공").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(account.identity.plan.capitalized) · 연결된 워크스페이스 \(account.identity.workspace.prefix(8))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("↑") { model.move(account.id, offset: -1) }.accessibilityLabel("계정 순서 위로")
                Button("↓") { model.move(account.id, offset: 1) }.accessibilityLabel("계정 순서 아래로")
                Button("재인증") { model.startLogin(alias: account.alias, replacing: account.id) }.disabled(model.demo || model.loginInProgress || model.pendingIdentity != nil)
                Button("제거", role: .destructive) { confirmingRemoval = true }
            }.controlSize(.small)
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { alias = account.alias }
            .alert("\(account.alias) 계정을 제거할까요?", isPresented: $confirmingRemoval) {
                Button("취소", role: .cancel) {}
                Button("제거", role: .destructive) { model.remove(account.id) }
            } message: { Text("이 앱의 해당 계정 인증 파일과 저장된 사용량을 삭제합니다. 기본 Codex 로그인은 유지됩니다.") }
    }
}
struct LoginView: View {
    @Bindable var model: AppModel
    @State private var alias = ""
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex 계정 연결").font(.title2.bold())
            Text("앱 전용 계정으로 연결합니다. 브라우저에 로그인된 계정이 다르면 원하는 계정으로 바꿔 로그인하세요.").font(.subheadline).foregroundStyle(.secondary)
            if let identity = model.pendingIdentity {
                Text(model.pendingAlias).font(.headline)
                Text(identity.email ?? "이메일 미제공").textSelection(.enabled)
                Text(identity.plan.capitalized).foregroundStyle(.secondary)
                Text("이 계정이 맞는지 확인하세요.").font(.caption)
                HStack { Button("취소") { model.cancelLogin(); close() }; Spacer(); Button("확인 후 등록") { model.confirmLogin(); if model.pendingIdentity == nil { close() } }.buttonStyle(.borderedProminent) }
            } else if model.loginInProgress {
                ProgressView().controlSize(.small)
                Text(model.loginStatus)
                if let url = model.loginURL { Button("로그인 페이지 다시 열기") { NSWorkspace.shared.open(url) } }
                Button("로그인 취소") { model.cancelLogin() }
            } else {
                TextField("계정 별칭 (예: 개인, 연구, 업무)", text: $alias).textFieldStyle(.roundedBorder)
                Text("인증 정보는 접근 권한이 제한된 앱 전용 파일에 저장됩니다.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("닫기", action: close); Spacer(); Button("ChatGPT로 로그인") { model.message = nil; model.startLogin(alias: alias) }.buttonStyle(.borderedProminent).disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.storageUnavailable) }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding(26).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}
