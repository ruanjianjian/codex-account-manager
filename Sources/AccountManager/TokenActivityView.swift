import SwiftUI
import AccountCore

struct TokenBars: View {
    let days: [TokenDay]
    var height: CGFloat = 42
    var showValues = false
    private var maximum: Double { max(1, Double(days.compactMap(\.tokens).max() ?? 0)) }
    var body: some View {
        HStack(alignment: .bottom, spacing: days.count > 10 ? 3 : 8) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    if showValues && days.count <= 7 {
                        Text(day.tokens.map(TokenActivity.compact) ?? "—").font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.04))
                        if let tokens = day.tokens {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(red: 0, green: 0.46, blue: 0.53).opacity(day.isComplete ? 1 : 0.4))
                                .frame(height: tokens == 0 ? 2 : max(3, height * Double(tokens) / maximum))
                        } else { Text("—").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(height: height)
                    if days.count <= 7 { Text(String(day.id.suffix(5))).font(.system(size: 9)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
                    .help("\(day.id) · \(day.tokens.map { $0.formatted() + " tokens" } ?? "暂无数据") · \(day.reportedAccounts)/\(day.expectedAccounts) 个账号")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.id) \(day.tokens.map { $0.formatted() + " tokens" } ?? "暂无数据")，\(day.reportedAccounts)/\(day.expectedAccounts) 个账号")
            }
        }
    }
}
struct TokenActivityMini: View {
    @ObservedObject var store: AppStore
    let openDetails: () -> Void
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("TOKEN 活动 · 近 7 天").font(.system(size: 10, weight: .bold))
                Spacer()
                Button("查看更多", action: openDetails).font(.system(size: 10)).buttonStyle(.plain)
            }
            TokenBars(days: store.tokenDays(count: 7), showValues: true)
            HStack {
                Text(store.usageCaption())
                Spacer()
                Text("浅色为部分账号 · — 为缺失")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(height: 112)
    }
}
struct TokenActivityDetails: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var days = 30
    @State private var account = "all"
    var body: some View {
        let rows = store.tokenDays(count: days, accountID: account == "all" ? nil : account)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Token 活动").font(.title2.bold())
                Spacer()
                Button("刷新统计") { store.refreshUsage(force: true) }.disabled(!store.usageLoading.isEmpty)
            }
            HStack {
                Picker("时间", selection: $days) {
                    Text("近 7 天").tag(7); Text("近 30 天").tag(30); Text("近 90 天").tag(90); Text("全部返回日期").tag(0)
                }
                Picker("账号", selection: $account) {
                    Text("全部账号").tag("all")
                    ForEach(store.saved.accounts) { Text($0.displayName).tag($0.id) }
                }
            }
            Text(store.usageCaption(accountID: account == "all" ? nil : account)).font(.caption).foregroundStyle(.secondary)
            if !rows.isEmpty {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        TokenBars(days: rows, height: 100, showValues: true).frame(width: max(geometry.size.width, CGFloat(rows.count) * 8))
                    }
                }
                .frame(height: rows.count <= 7 ? 140 : 108)
            }
            Text("按官方返回日期汇总；近 N 天以 UTC 日历列出，不改写服务端日期。当天可能尚未结算。浅色为部分账号，缺失不会当作零；包含这些账号在其他电脑上的服务端用量。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(rows.reversed()) { day in
                        HStack {
                            Text(day.id).monospacedDigit()
                            Spacer()
                            Text(day.tokens.map { TokenActivity.compact($0) + " tokens" } ?? "暂无数据").monospacedDigit().help(day.tokens.map { $0.formatted() + " tokens" } ?? "暂无数据")
                            Text("\(day.reportedAccounts)/\(day.expectedAccounts) 账号").foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                        }.font(.callout)
                    }
                }
            }.frame(minHeight: 120, maxHeight: .infinity)
            if !store.usageErrors.isEmpty { Text("有账号暂时无法更新，当前保留上次成功统计；可稍后重试。").font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("完成", action: onClose).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 520, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
    }
}
