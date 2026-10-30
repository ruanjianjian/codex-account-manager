import SwiftUI
import AccountCore

/// The desktop widget: accounts as stepping stones, the mascot standing on the one Codex uses now.
/// When that account runs out, routing moves on and the mascot hops to the next stone.
struct EmbeddedWidgetView: View {
    static let perRow = 6
    static func size(for count: Int) -> NSSize {
        let columns = min(perRow, max(1, count)), rows = max(1, (count + perRow - 1) / perRow)
        return NSSize(width: max(360, 32 + CGFloat(columns) * 96 + CGFloat(columns - 1) * 10), height: 186 + CGFloat(rows - 1) * 100)
    }
    @ObservedObject var store: AppStore
    let present: (WidgetAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hopping = false
    private var accounts: [AccountSlot] { store.saved.accounts }
    private let green = Color(red: 0.16, green: 0.70, blue: 0.33)
    private let orange = Color(red: 0.85, green: 0.38, blue: 0.05)

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 10)
            if accounts.isEmpty {
                DangoWelcome { present(.add) }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: min(Self.perRow, accounts.count)), spacing: 18) {
                    ForEach(accounts, id: \.id) { stone($0) }
                }
                .overlayPreferenceValue(TileSpot.self) { spot in
                    GeometryReader { proxy in
                        if let spot {
                            let rect = proxy[spot]
                            LiveDango(mood: tileMood, busy: store.routingActivity.count(for: activeID ?? "") > 0).frame(width: 30, height: 30)
                                .keyframeAnimator(initialValue: 0.0, trigger: tileID) { tile, lift in tile.offset(y: lift) } keyframes: { _ in
                                    KeyframeTrack {
                                        CubicKeyframe(reduceMotion ? 0 : -20, duration: 0.2)
                                        CubicKeyframe(0, duration: 0.24)
                                    }
                                }
                                .position(x: rect.midX, y: rect.maxY - 15)
                                .animation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.8), value: tileID)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            Spacer(minLength: 10)
            footer
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(white: 0.12))
        // The mascot squints (> <) for the length of a hop.
        .onChange(of: tileID) { _, _ in
            guard !reduceMotion else { return }
            hopping = true
            Task { try? await Task.sleep(for: .milliseconds(460)); hopping = false }
        }
        // Anything that is not a control moves the widget.
        .background { ZStack { RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.97)); DragSurface() } }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tibot").font(.system(size: 13, weight: .semibold)).allowsHitTesting(false)
            if store.gatewayEnabled { RoutingHealthDots(store: store).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).allowsHitTesting(false)
            Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.isBusy || store.preview).help("刷新所有账号").accessibilityLabel("刷新组件额度")
            Button { present(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                .help("设置").accessibilityLabel("打开设置")
        }.buttonStyle(.plain).font(.system(size: 12)).frame(height: 20)
    }
    private var status: String {
        guard store.gatewayEnabled else { return "\(store.connectedCount)/\(accounts.count) 已连接" }
        guard store.gatewayReady else { return "等待网关" }
        let busy = store.routingActivity.active.count
        if busy > 0 { return "\(busy) 个请求中" }
        return store.gatewayPreferred.isEmpty ? "最早重置优先" : "优先 " + (store.slot(store.gatewayPreferred)?.displayName ?? "指定账号")
    }
    @ViewBuilder private var footer: some View {
        if let next = spentUntil {
            Text("额度都用完了 · \(next.name) \(Mascot.comesBack(next.backAt, now: store.now))")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).allowsHitTesting(false)
        } else if let alert = store.resetAlert {
            Link(destination: alert.url) {
                Label(alert.text, systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }.foregroundStyle(orange).help("打开 Tibo 原帖")
        } else if !store.gatewayEnabled && store.routingSetup != .ready && !store.preview {
            Button { present(.settings) } label: {
                Text("自动路由还差 \(store.routingSetup.remaining) 步 ›").font(.system(size: 10, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(Color(red: 0, green: 0.46, blue: 0.53)).help("打开设置完成自动路由")
        } else {
            Text(store.gatewayEnabled ? "用完自动跳到下一块" : "自动路由已关闭").font(.system(size: 10)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }

    private func remaining(_ slot: AccountSlot) -> Double? { slot.snapshot?.rates.windows.compactMap(\.remaining).min() }
    private func usable(_ slot: AccountSlot) -> Bool { (remaining(slot) ?? 0) > 0 }
    private var activeID: String? { store.currentAccountID }
    /// Every account is out: the mascot sleeps on the one that comes back first.
    private var spentUntil: Mascot.Account? {
        let accounts = store.mascotAccounts
        return Mascot.allSpent(accounts) ? Mascot.nextBack(accounts) : nil
    }
    private var tileID: String? { activeID ?? spentUntil?.id }
    private var tileMood: MascotMood {
        if hopping { return .hop }
        if spentUntil != nil { return .sleep }
        return store.resetAlert == nil ? .open : .star
    }

    private func stone(_ slot: AccountSlot) -> some View {
        let left = remaining(slot)
        let reset = slot.snapshot?.rates.windows.comesBackAt
        let active = slot.id == activeID
        let spent = left.map { $0 <= 0 } ?? false
        let spoken = spokenLabel(slot, left: left, reset: reset, active: active, spent: spent)
        return VStack(spacing: 6) {
            spot(slot.id == tileID)
            bar(left: left, active: active, spent: spent)
            name(slot, active: active, spent: spent)
            value(slot, left: left, reset: reset, active: active, spent: spent)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(spoken)
    }
    private func spot(_ active: Bool) -> some View {
        Color.clear.frame(height: 30).anchorPreference(key: TileSpot.self, value: .bounds) { active ? $0 : nil }
    }
    private func bar(left: Double?, active: Bool, spent: Bool) -> some View {
        let fill: Color = left == nil ? .clear : active ? green : Color(white: spent ? 0.9 : 0.8)
        let dashed: Color = left == nil ? Color(white: 0.75) : .clear
        return Capsule().fill(fill).frame(height: 8)
            .overlay(Capsule().strokeBorder(dashed, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
    private func name(_ slot: AccountSlot, active: Bool, spent: Bool) -> some View {
        let ink: Color = active ? Color(white: 0.12) : spent ? Color(white: 0.6) : Color(white: 0.35)
        let weight: Font.Weight = active ? .semibold : .regular
        return Button { store.chooseAccount(slot.id) } label: {
            Text(slot.displayName).font(.system(size: 12, weight: weight)).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(ink)
        }.buttonStyle(.plain).disabled(store.preview || slot.expectedAccountID == nil).help(store.accountActionLabel(slot.id))
    }
    @ViewBuilder private func value(_ slot: AccountSlot, left: Double?, reset: Date?, active: Bool, spent: Bool) -> some View {
        if let left {
            let text: String = spent ? Mascot.untilReset(reset, now: store.now) : "\(Int(left))%"
            let ink: Color = active ? green : spent ? Color(white: 0.6) : left < 15 ? orange : Color(white: 0.45)
            let weight: Font.Weight = active ? .semibold : .regular
            Text(text).font(.system(size: 11, weight: weight)).monospacedDigit().lineLimit(1).foregroundStyle(ink).allowsHitTesting(false)
        } else {
            Button("＋ 连接") { store.connectOrContinue(slot.id) }.buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium)).disabled(!store.canOpenConnection(slot.id))
        }
    }
    private func spokenLabel(_ slot: AccountSlot, left: Double?, reset: Date?, active: Bool, spent: Bool) -> String {
        var parts = [slot.displayName]
        if active { parts.append("正在用") }
        if let left { parts.append(spent ? "额度用完，" + Mascot.comesBack(reset, now: store.now) : "余量 \(Int(left))%") } else { parts.append("未连接") }
        return parts.joined(separator: "，")
    }
}

/// Where the tile stands: the top slot of the active account's stone.
private struct TileSpot: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
