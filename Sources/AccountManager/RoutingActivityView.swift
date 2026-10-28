import SwiftUI
import AccountCore

/// Original native rendering; flow-map design inspired by Magpie.
struct RoutingActivityView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("routing.expanded") private var expanded = true
    @State private var visible = false
    private let paper = Color(red: 0.065, green: 0.085, blue: 0.105)
    private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)
    private var activity: RoutingActivity { store.routingActivity }
    private var slots: [AccountSlot] { store.saved.accounts }
    private var flowHeight: CGFloat { CGFloat(max(3, min(6, slots.count))) * 23 }
    private var summary: String {
        if !store.gatewayReady { return "等待网关" }
        if !activity.active.isEmpty { return "\(activity.active.count) 个请求处理中" }
        switch activity.lastKind {
        case "completed": return "最近一次已完成"
        case "refused", "network_error", "interrupted": return "最近请求遇到错误"
        case "ended": return "请求已结束"
        default: return "等待请求"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(store.gatewayReady ? mint : .orange).frame(width: 5, height: 5)
                    Text("LIVE ROUTING").font(.system(size: 9, weight: .bold)).tracking(1)
                    Spacer(minLength: 3)
                    Text(summary).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }.padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("实时路由，\(summary)，\(expanded ? "收起" : "展开")")
            if expanded {
                if slots.isEmpty {
                    Text("连接账号后显示请求流向").font(.caption).foregroundStyle(.white.opacity(0.7)).padding(12)
                } else {
                    ScrollView(.vertical) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || reduceMotion || activity.active.isEmpty)) { tick in
                            flow(time: tick.date.timeIntervalSinceReferenceDate)
                        }.frame(height: CGFloat(max(3, slots.count)) * 23)
                    }.frame(height: flowHeight).scrollIndicators(.hidden)
                }
                HStack(spacing: 6) {
                    Text(store.gatewayPreferred.isEmpty ? "自动选路" : "优先指定账号")
                    Spacer(minLength: 0)
                    Text("\(activity.completed) 完成 · \(activity.reroutes) 换路")
                        .monospacedDigit().help("本次启动后的请求统计；换路只在真正尝试下一个账号时计数")
                }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 9)
            }
        }
        .foregroundStyle(.white).background(paper, in: RoundedRectangle(cornerRadius: 9))
        .onAppear { visible = true }.onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            if let panel = notification.object as? DesktopPanel { visible = panel.isVisible && panel.occlusionState.contains(.visible) }
        }
    }

    private func flow(time: TimeInterval) -> some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let center = CGPoint(x: w * 0.36, y: h / 2)
            let destinationX = w * 0.60
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let start = CGPoint(x: 42, y: h / 2)
                    var input = Path(); input.move(to: start); input.addLine(to: center)
                    context.stroke(input, with: .color(.white.opacity(0.15)), lineWidth: 1)
                    if !activity.active.isEmpty {
                        moving(input, color: mint, time: time, context: &context)
                    }
                    for (index, slot) in slots.enumerated() {
                        let y = CGFloat(index) * 23 + 11.5
                        let end = CGPoint(x: destinationX, y: y)
                        var line = Path(); line.move(to: center)
                        line.addCurve(to: end, control1: CGPoint(x: w * 0.49, y: center.y), control2: CGPoint(x: w * 0.47, y: y))
                        context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 1)
                        let active = activity.count(for: slot.id) > 0
                        let recent = activity.lastAccount == slot.id && activity.lastKind == "completed"
                        let color = CoverPalette.all[index % CoverPalette.all.count].ink
                        if active { moving(line, color: color, time: time + Double(index) * 0.19, context: &context) }
                        else if recent { context.stroke(line, with: .color(color.opacity(0.4)), lineWidth: 1.4) }
                    }
                }.accessibilityHidden(true)
                VStack(spacing: 4) {
                    Image(systemName: "terminal").font(.system(size: 16, weight: .medium))
                    Text("Codex").font(.system(size: 9, weight: .medium))
                }.frame(width: 44, height: 42).background(paper).position(x: 28, y: h / 2)
                ZStack {
                    Circle().fill(paper).frame(width: 35, height: 35)
                    Circle().stroke(mint.opacity(activity.active.isEmpty ? 0.25 : 0.8), lineWidth: 1).frame(width: 35, height: 35)
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 15)).foregroundStyle(mint)
                }.position(center).accessibilityLabel("本机网关")
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let count = activity.count(for: slot.id)
                    let color = CoverPalette.all[index % CoverPalette.all.count].ink
                    HStack(spacing: 5) {
                        Circle().fill(count > 0 ? color : .white.opacity(0.25)).frame(width: 5, height: 5)
                        Text(slot.displayName).font(.system(size: 10, weight: count > 0 ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if count > 0 { Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(color) }
                        else if activity.lastAccount == slot.id && activity.lastKind == "completed" {
                            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(mint)
                        } else if activity.lastAccount == slot.id && ["refused", "network_error", "interrupted"].contains(activity.lastKind) {
                            Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        }
                    }.padding(.horizontal, 6).frame(width: max(40, w - destinationX - 8), height: 21)
                        .background(count > 0 ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white.opacity(count > 0 ? 1 : 0.65))
                        .position(x: (destinationX + w - 8) / 2, y: CGFloat(index) * 23 + 11.5)
                        .help(slot.displayName + (count > 0 ? " · \(count) 个请求处理中" : ""))
                        .accessibilityLabel(slot.displayName + (count > 0 ? "，\(count) 个请求处理中" : "，当前无请求"))
                }
            }
        }.padding(.horizontal, 6)
    }

    private func moving(_ path: Path, color: Color, time: TimeInterval, context: inout GraphicsContext) {
        context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 1.4)
        guard !reduceMotion else { return }
        // A travelling highlight with a gentle trail, one passage every 1.8 seconds.
        let phase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
        for segment in 0..<8 {
            let end = phase - Double(segment) * 0.012
            guard end > 0 else { continue }
            context.stroke(path.trimmedPath(from: max(0, end - 0.014), to: end),
                           with: .color(color.opacity(1 - Double(segment) / 9)),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
    }
}
