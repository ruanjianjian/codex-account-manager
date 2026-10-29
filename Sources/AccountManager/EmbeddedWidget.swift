import SwiftUI
import AccountCore

/// Wide account cards that live on the desktop beside macOS's own widgets.
/// Same palette and cards as the menu-bar dashboard, laid out in one row.
struct EmbeddedWidgetView: View {
    static let size = NSSize(width: 549, height: 335)
    @ObservedObject var store: AppStore
    let present: (WidgetAction) -> Void
    private var accounts: [AccountSlot] { store.saved.accounts }
    private var columns: Int { min(4, max(1, accounts.count)) }
    private var status: String {
        guard store.gatewayEnabled else { return "\(store.connectedCount)/\(accounts.count) 已连接" }
        let preferred = store.gatewayPreferred.isEmpty ? "自动选路" : "优先 " + (store.slot(store.gatewayPreferred)?.displayName ?? "指定账号")
        let activity = store.routingActivity
        return !store.gatewayReady ? "等待网关" : (activity.active.isEmpty ? preferred : "\(activity.active.count) 个请求中")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("CODEX / ACCOUNTS").font(.system(size: 12, weight: .heavy)).tracking(0.6).allowsHitTesting(false)
                Spacer(minLength: 8)
                if let alert = store.resetAlert {
                    Link(destination: alert.url) {
                        Label(alert.text, systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }.foregroundStyle(Color(red: 0.85, green: 0.38, blue: 0.05)).help("打开 Tibo 原帖")
                } else {
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).allowsHitTesting(false)
                }
                if store.gatewayEnabled { RoutingHealthDots(store: store).foregroundStyle(.secondary) }
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isBusy || store.preview).help("刷新所有账号").accessibilityLabel("刷新组件额度")
                Button { present(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                    .help("设置").accessibilityLabel("打开设置")
            }.buttonStyle(.plain).font(.system(size: 12)).frame(height: 20)
            if accounts.isEmpty {
                Button("＋ 添加第一个账号") { present(.add) }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if store.gatewayEnabled { RoutingLane(store: store, columns: columns, spacing: 8).padding(.bottom, -10) }
                if accounts.count <= 4 {
                    HStack(spacing: 8) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, slot in card(slot, index: index) }
                    }.frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, slot in card(slot, index: index).frame(height: 150) }
                        }
                    }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("近 7 天").font(.system(size: 9, weight: .bold))
                        Text("Token").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(width: 44, alignment: .leading).padding(.bottom, 14)
                    TokenBars(days: store.tokenDays(count: 7), height: 30)
                }.frame(height: 50).contentShape(Rectangle()).onTapGesture { present(.activity) }
                    .help("查看 Token 活动")
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(white: 0.12))
        // Anything that is not a control moves the widget: header, lane, card faces and margins.
        .background { ZStack { RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.97)); DragSurface() } }
        .preferredColorScheme(.light)
    }

    private func card(_ slot: AccountSlot, index: Int) -> some View {
        let colors = CoverPalette.all[index % CoverPalette.all.count]
        let windows = slot.snapshot?.rates.windows ?? []
        let remaining = windows.compactMap(\.remaining).min()
        let reset = windows.compactMap(\.resetDate).min()
        let banked = slot.snapshot?.rates.rateLimitResetCredits?.availableCount
        let routing = store.routingActivity.count(for: slot.id) > 0
        return VStack(alignment: .leading, spacing: 0) {
            Button { store.openAccountDesktop(slot.id) } label: {
                Text(slot.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }.buttonStyle(.plain)
                .disabled(store.preview || store.loginSlotID != nil || !store.launchingDesktop.isEmpty || slot.expectedAccountID == nil)
                .help(store.desktopActionLabel(slot.id))
            Spacer(minLength: 4).allowsHitTesting(false)
            if let remaining {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(remaining))").font(.system(size: 34, weight: .black)).tracking(-1.2)
                    Text("%").font(.system(size: 14, weight: .bold))
                }.foregroundStyle(colors.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).allowsHitTesting(false)
                    .accessibilityLabel("\(slot.displayName) 最低窗口余量 \(Int(remaining))%")
            } else {
                Button { store.connectOrContinue(slot.id) } label: {
                    Text("＋ 连接").font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                }.buttonStyle(.plain).disabled(!store.canOpenConnection(slot.id))
            }
            Spacer(minLength: 4)
            Text(reset.map { Presentation.countdown($0, now: store.now).replacingOccurrences(of: "后", with: "后重置") } ?? (store.status[slot.id]?.message ?? "等待同步"))
                .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8).allowsHitTesting(false)
            HStack {
                Text("BANKED RESET").font(.system(size: 8, weight: .bold)).tracking(0.5)
                Spacer(minLength: 2)
                Text(banked.map(String.init) ?? "—").font(.system(size: 11, weight: .bold)).monospacedDigit()
            }.padding(.top, 5).allowsHitTesting(false)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white).background { colors.paper.allowsHitTesting(false) }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 12, topTrailingRadius: 12))
        .overlay(alignment: .topTrailing) {
            if routing { Circle().fill(colors.ink).frame(width: 6, height: 6).padding(8).help("请求处理中") }
        }
        .accessibilityElement(children: .contain)
    }
}
