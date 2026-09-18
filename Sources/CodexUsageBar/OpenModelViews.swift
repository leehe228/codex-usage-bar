import SwiftUI
import Charts
import CodexUsageCore
import AppKit

struct OpenModelSummary: View {
    var model: AppModel
    var account: SavedAccount
    var body: some View {
        if let snapshot = account.openModel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("사용 가능 잔액").font(.caption2).foregroundStyle(.secondary)
                    Text(balance(snapshot.available)).font(.system(size: 25, weight: .semibold)).monospacedDigit()
                        .help(OpenModelSnapshot.dollars(snapshot.available))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(.quaternary).frame(width: 1, height: 48)
                VStack(spacing: 8) {
                    cost("오늘", snapshot.today.cost)
                    cost("이번 달", snapshot.month.cost)
                }.frame(maxWidth: .infinity)
            }.padding(.vertical, 3)
            Divider()
            Text("이번 달 \(snapshot.month.requests.formatted())회 요청 · \(compactTokens(snapshot.month.tokens)) 토큰")
                .font(.caption2).foregroundStyle(.secondary)
                .help("서버 집계 \(snapshot.month.tokens.formatted()) 토큰")
            if model.errors[account.id] != nil {
                Text("이전 값 · \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)) 조회").font(.caption2).foregroundStyle(.orange)
            }
        } else {
            Text(model.errors[account.id] ?? "잔액과 사용량을 확인하고 있습니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func cost(_ title: String, _ amount: Int64) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(OpenModelSnapshot.dollars(amount)).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }
}

struct OpenModelDetail: View {
    @Bindable var model: AppModel
    var account: SavedAccount
    var reauthenticate: () -> Void
    @State private var measure: OpenModelMeasure = .cost
    private var period: OpenModelPeriod { model.openModelPeriod }
    private var snapshot: OpenModelSnapshot? { account.openModel }
    private var dashboard: OpenModelDashboard? { snapshot?.dashboards?.first { $0.period == period } }
    private var metrics: OpenModelMetrics? {
        if let dashboard { return dashboard.metrics }
        switch period { case .today: return snapshot?.today; case .month: return snapshot?.month; case .last24Hours: return nil }
    }
    private var zone: TimeZone { snapshot.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current }
    private let colors: [Color] = [.orange, .indigo, .teal, .pink, .blue, .purple]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(account.alias).font(.title3.bold())
                    if model.hasReachedLimit(account) { LimitReachedLabel(text: "잔액 부족") }
                    Spacer()
                    Text("OpenModel").font(.caption).foregroundStyle(.secondary)
                    StateLabel(model: model, account: account)
                }
                Text(model.disk.preferences.hideEmail ? "이메일 숨김" : account.identity.email ?? "이메일 미제공")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errors[account.id] {
                VStack(alignment: .leading, spacing: 5) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    if model.authRequired.contains(account.id) { Button("계정 관리에서 재인증", action: reauthenticate) }
                    else { Button("다시 조회") { model.refresh(account.id) } }
                }
            }
            if let snapshot {
                balancePanel(snapshot)
                HStack {
                    Text("사용량").font(.subheadline.bold())
                    Spacer()
                    Picker("조회 기간", selection: $model.openModelPeriod) {
                        ForEach(OpenModelPeriod.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize().accessibilityLabel("사용량 조회 기간")
                }
                HStack(spacing: 8) {
                    metric("사용 비용", value: metrics.map { OpenModelSnapshot.dollars($0.cost) } ?? "—", subtitle: "USD")
                    metric("요청 수", value: metrics.map { "\($0.requests.formatted())회" } ?? "—", subtitle: "선택한 기간")
                    metric("총 토큰", value: metrics.map { compactTokens($0.tokens) } ?? "—", subtitle: "서버 집계")
                        .help(metrics.map { "\($0.tokens.formatted()) 토큰" } ?? "집계 미제공")
                }
                HStack {
                    Text("사용 추이").font(.subheadline.bold())
                    Spacer()
                    Picker("추이 지표", selection: $measure) {
                        ForEach(OpenModelMeasure.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 164).labelsHidden()
                }
                if let usage = dashboard?.usage {
                    if usage.models.isEmpty { emptyChart("선택한 기간에 사용 내역이 없습니다.") }
                    else { usageChart(usage); modelList(usage) }
                } else {
                    emptyChart(model.refreshing.contains(account.id) ? "사용 추이를 확인하고 있습니다." : "이 기간의 사용 추이를 조회하지 못했습니다.")
                }
                if let average = metrics?.averageTPM {
                    row("평균 TPM", average.formatted(.number.precision(.fractionLength(0...1))))
                        .help("선택 기간에 대한 OpenModel 서버의 분당 평균 토큰 집계입니다.")
                }
                Divider()
                DisclosureGroup("토큰 상세 · 집계 기준", isExpanded: $model.openModelTokensExpanded) {
                    VStack(alignment: .leading, spacing: 7) {
                        row("총 토큰 · 서버 집계", metrics.map { $0.tokens.formatted() } ?? "미제공")
                        if period == .month, let tokens = snapshot.tokenBreakdown {
                            row("입력 · 요청 로그", tokens.input.formatted())
                            row("출력 · 추론 포함", tokens.output.formatted())
                            Text("입력·출력은 월간 요청 로그 합계입니다. 집계 출처가 달라 서버 총 토큰과 다를 수 있습니다.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(period == .month ? "완전한 요청 로그를 확보하지 못해 입력·출력 구분을 표시하지 않습니다." : "입력·출력 구분은 이번 달 보기에서 확인할 수 있습니다.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 7)
                }.font(.caption)
                VStack(alignment: .leading, spacing: 3) {
                    Text("계정 전체 · USD · \(snapshot.timeZone)")
                    Text("\(dateLabel(period.start(now: snapshot.fetchedAt, timeZone: zone), time: true)) – \(dateLabel(snapshot.fetchedAt, time: true))")
                    Text("마지막 성공 조회: \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("잔액과 사용량을 확인하고 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
            Button { NSWorkspace.shared.open(URL(string: "https://console.openmodel.ai/")!) } label: {
                Label("OpenModel 콘솔 열기", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }.controlSize(.regular)
        }.padding(.bottom, 16)
    }
    private func balancePanel(_ value: OpenModelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("사용 가능 잔액 · 현재"); Spacer(); Text("USD") }.font(.caption).foregroundStyle(.secondary)
            Text(balance(value.available)).font(.system(size: 29, weight: .semibold)).monospacedDigit()
                .help(OpenModelSnapshot.dollars(value.available))
            HStack {
                Text("전체 \(OpenModelSnapshot.dollars(value.balance))")
                Spacer()
                Text("동결 \(OpenModelSnapshot.dollars(value.frozen))")
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
    }
    private func metric(_ label: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
    private func emptyChart(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
    private func usageChart(_ usage: OpenModelUsage) -> some View {
        let names = usage.models.map(\.model).sorted()
        let from = min(dashboard?.from ?? .now, usage.buckets.first?.timestamp ?? .now)
        let to = max(dashboard?.to ?? .now, from.addingTimeInterval(1))
        return Chart {
            ForEach(Array(usage.buckets.enumerated()), id: \.offset) { _, bucket in
                ForEach(bucket.models) { item in
                    BarMark(x: .value("시각", bucket.timestamp), y: .value(measure.unit, measure.value(item.metrics)))
                        .foregroundStyle(by: .value("모델", item.model))
                        .accessibilityLabel("\(dateLabel(bucket.timestamp, time: period != .month)), \(item.model)")
                        .accessibilityValue(measure.formatted(item.metrics))
                }
            }
        }
        .chartXScale(domain: from...to)
        .chartForegroundStyleScale(domain: names, range: names.indices.map { colors[$0 % colors.count] })
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel { if let date = value.as(Date.self) { Text(dateLabel(date, time: period != .month)) } }
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartYAxisLabel(measure.unit)
        .frame(height: 140).padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
    private func modelList(_ usage: OpenModelUsage) -> some View {
        let names = usage.models.map(\.model).sorted()
        let sorted = usage.models.sorted {
            let left = measure.value($0.metrics), right = measure.value($1.metrics)
            return left == right ? $0.model < $1.model : left > right
        }
        let total = sorted.reduce(0) { $0 + measure.value($1.metrics) }
        return VStack(alignment: .leading, spacing: 9) {
            HStack { Text("모델별 사용량").font(.subheadline.bold()); Spacer(); Text(measure == .tokens ? "토큰" : "\(measure.title) · \(measure.unit)").font(.caption2).foregroundStyle(.secondary) }
            ForEach(sorted.prefix(5)) { item in
                let color = colors[(names.firstIndex(of: item.model) ?? 0) % colors.count]
                let share = total > 0 ? measure.value(item.metrics) / total : 0
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(item.model).lineLimit(1).truncationMode(.middle).help(item.model)
                        Spacer(minLength: 5)
                        Text(measure.formatted(item.metrics)).monospacedDigit()
                        Text(share > 0 && share < 0.001 ? "<0.1%" : share.formatted(.percent.precision(.fractionLength(1)))).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption2)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(color).frame(width: geometry.size.width * share)
                        }
                    }.frame(height: 4)
                }
            }
            if sorted.count > 5 { Text("상위 5개 모델 · 전체 \(sorted.count)개는 콘솔에서 확인").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func dateLabel(_ date: Date, time: Bool) -> String {
        let formatter = DateFormatter(); formatter.timeZone = zone; formatter.dateFormat = time ? "M/d HH:mm" : "M/d"
        return formatter.string(from: date)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
}

private func balance(_ amount: Int64) -> String {
    (Decimal(amount) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2)))
}
private func compactTokens(_ amount: Int64) -> String {
    if amount >= 1_000_000 { return (Double(amount) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + "M" }
    if amount >= 1_000 { return (Double(amount) / 1_000).formatted(.number.precision(.fractionLength(1))) + "K" }
    return amount.formatted()
}
