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
                    .help(L("\(day.id) · \(day.tokens.map { $0.formatted() + " tokens" } ?? "暂无数据") · \(day.reportedAccounts)/\(day.expectedAccounts) 个账号", "\(day.id) · \(day.tokens.map { $0.formatted() + " tokens" } ?? "no data") · \(day.reportedAccounts)/\(day.expectedAccounts) accounts"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("\(day.id) \(day.tokens.map { $0.formatted() + " tokens" } ?? "暂无数据")，\(day.reportedAccounts)/\(day.expectedAccounts) 个账号", "\(day.id) \(day.tokens.map { $0.formatted() + " tokens" } ?? "no data"), \(day.reportedAccounts)/\(day.expectedAccounts) accounts"))
            }
        }
    }
}
/// The panel's last weeks of tokens, a week per page: swipe or use the arrows to go back, the dots show where you are.
struct TokenActivityMini: View {
    @ObservedObject var store: AppStore
    let openDetails: () -> Void
    /// The week shown, counted back from this one. It starts empty and is set once the strip is on screen, so the
    /// strip opens on this week rather than its first (oldest) page.
    @State private var weeksAgo: Int?
    var body: some View {
        let weeks = store.tokenWeeks()
        let shown = min(weeksAgo ?? 0, weeks.count - 1)
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(L("TOKEN 活动 · ", "TOKEN ACTIVITY · ") + TokenActivity.weekTitle(weeks[weeks.count - 1 - shown], weeksAgo: shown)).font(.system(size: 10, weight: .bold))
                Spacer()
                Group {
                    Button { show(shown + 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(shown >= weeks.count - 1).help(L("上一周", "Previous week")).accessibilityLabel(L("上一周", "Previous week"))
                    Button { show(shown - 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(shown == 0).help(L("下一周", "Next week")).accessibilityLabel(L("下一周", "Next week"))
                }.font(.system(size: 10, weight: .semibold))
                Button(L("查看更多", "More"), action: openDetails).font(.system(size: 10))
            }.buttonStyle(.plain)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach((0 ..< weeks.count).reversed(), id: \.self) { ago in
                        TokenBars(days: weeks[weeks.count - 1 - ago], showValues: true).containerRelativeFrame(.horizontal)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging).scrollPosition(id: $weeksAgo).scrollIndicators(.never)
            .onAppear { if weeksAgo == nil { weeksAgo = 0 } }
            HStack {
                Text(store.usageCaption())
                Spacer()
                Text(L("浅色为部分账号 · — 为缺失", "Light = some accounts · — = missing"))
            }.font(.system(size: 9)).foregroundStyle(.secondary)
                .overlay { PageDots(count: weeks.count, current: weeks.count - 1 - shown) }
        }.frame(height: 112)
    }
    private func show(_ week: Int) { withAnimation(.easeInOut(duration: 0.3)) { weeksAgo = week } }
}
/// Up to seven dots for the pages, sliding along with the current one.
private struct PageDots: View {
    let count: Int, current: Int
    var body: some View {
        let first = min(max(0, current - 3), max(0, count - 7))
        HStack(spacing: 4) {
            ForEach(first ..< min(count, first + 7), id: \.self) { page in
                Circle().fill(page == current ? Color.primary : Color.primary.opacity(0.2)).frame(width: 5, height: 5)
            }
        }.accessibilityHidden(true)
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
                Text(L("Token 活动", "Token activity")).font(.title2.bold())
                Spacer()
                Button(L("刷新统计", "Refresh stats")) { store.refreshUsage(force: true) }.disabled(!store.usageLoading.isEmpty)
            }
            HStack {
                Picker(L("时间", "Period"), selection: $days) {
                    Text(L("近 7 天", "Last 7 days")).tag(7); Text(L("近 30 天", "Last 30 days")).tag(30); Text(L("近 90 天", "Last 90 days")).tag(90); Text(L("全部返回日期", "All returned days")).tag(0)
                }
                Picker(L("账号", "Account"), selection: $account) {
                    Text(L("全部账号", "All accounts")).tag("all")
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
            Text(L("按官方返回日期汇总；近 N 天以 UTC 日历列出，不改写服务端日期。当天可能尚未结算。浅色为部分账号，缺失不会当作零；包含这些账号在其他电脑上的服务端用量。", "Summed by the dates the service returns; the last N days follow the UTC calendar and server dates are not rewritten. Today may not be settled yet. Light bars mean only some accounts reported; missing days are not counted as zero. Includes these accounts' usage on other computers."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(rows.reversed()) { day in
                        HStack {
                            Text(day.id).monospacedDigit()
                            Spacer()
                            Text(day.tokens.map { TokenActivity.compact($0) + " tokens" } ?? L("暂无数据", "No data")).monospacedDigit().help(day.tokens.map { $0.formatted() + " tokens" } ?? L("暂无数据", "No data"))
                            Text(L("\(day.reportedAccounts)/\(day.expectedAccounts) 账号", "\(day.reportedAccounts)/\(day.expectedAccounts) accounts")).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                        }.font(.callout)
                    }
                }
            }.frame(minHeight: 120, maxHeight: .infinity)
            if !store.usageErrors.isEmpty { Text(L("有账号暂时无法更新，当前保留上次成功统计；可稍后重试。", "Some accounts could not update; showing the last successful stats. Try again later.")).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button(L("完成", "Done"), action: onClose).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 520, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
    }
}
