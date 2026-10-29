import SwiftUI
import AccountCore

/// Original native rendering; flow-map design inspired by Magpie, drawn as pixel art:
/// each request is a pixel rocket with a flickering exhaust that explodes on arrival.
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
        case "refused", "network_error", "interrupted", "rejected": return "最近请求遇到错误"
        case "ended": return "请求已结束"
        default: return "等待请求"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("LIVE ROUTING").font(.system(size: 9, weight: .bold)).tracking(1)
                    RoutingHealthDots(store: store, dark: true)
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
                        // Full rate only while rockets fly or a burst plays; a slow idle twinkle otherwise.
                        let lively = !activity.active.isEmpty || Date().timeIntervalSince(activity.changedAt) < 0.6
                        TimelineView(.animation(minimumInterval: lively ? 1.0 / 30 : 1.0 / 8, paused: !visible || reduceMotion)) { tick in
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
            if let panel = notification.object as? DesktopPanel, panel.frameAutosaveName != "CodexEmbeddedWidget" {
                visible = panel.isVisible && panel.occlusionState.contains(.visible)
            }
        }
    }

    private func flow(time: TimeInterval) -> some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let center = CGPoint(x: w * 0.36, y: h / 2)
            let destinationX = w * 0.60
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawPixels(&context, width: w, height: h, center: center, destinationX: destinationX, time: time)
                }.accessibilityHidden(true)
                Text("CODEX").font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    .position(x: 28, y: h / 2 + 16)
                Color.clear.frame(width: 24, height: 24).position(center)
                    .accessibilityElement().accessibilityLabel("本机网关")
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let count = activity.count(for: slot.id)
                    let color = CoverPalette.all[index % CoverPalette.all.count].ink
                    HStack(spacing: 5) {
                        Text(slot.displayName).font(.system(size: 10, weight: count > 0 ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if count > 0 { Text("\(count)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(color) }
                        else if activity.lastAccount == slot.id && activity.lastKind == "completed" {
                            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(mint)
                        } else if activity.lastAccount == slot.id && ["refused", "network_error", "interrupted", "rejected"].contains(activity.lastKind) {
                            Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        }
                    }.padding(.horizontal, 6).frame(width: max(40, w - destinationX - 8), height: 21)
                        .background(count > 0 ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 2))
                        .foregroundStyle(.white.opacity(count > 0 ? 1 : 0.65))
                        .position(x: (destinationX + w - 8) / 2, y: CGFloat(index) * 23 + 11.5)
                        .help(slot.displayName + (count > 0 ? " · \(count) 个请求处理中" : ""))
                        .accessibilityLabel(slot.displayName + (count > 0 ? "，\(count) 个请求处理中" : "，当前无请求"))
                }
            }
        }.padding(.horizontal, 6)
    }

    private static let terminal = ["#######", "#.....#", "#.#...#", "#..#..#", "#.#.###", "#.....#", "#######"]
    private static let chip = [".#.#.#.", "#######", "#.....#", "##.#.##", "#.....#", "#######", ".#.#.#."]
    private static let server = ["#####", "#...#", "#####", "#...#", "#####"]

    private func drawPixels(_ context: inout GraphicsContext, width w: CGFloat, height h: CGFloat, center: CGPoint, destinationX: CGFloat, time: TimeInterval) {
        let brush = PixelBrush(context: context), p = PixelBrush.pixel
        let grid = PixelBrush.grid
        func ink(_ index: Int) -> Color { CoverPalette.all[index % CoverPalette.all.count].ink }
        let busy = !activity.active.isEmpty
        for y in stride(from: 0, to: Int(h / p), by: 2) {
            context.fill(Path(CGRect(x: 0, y: CGFloat(y) * p, width: w, height: 1)), with: .color(.white.opacity(0.025)))
        }
        let mid = grid(h / 2), bend = grid(w * 0.48), end = grid(destinationX - 22)
        let rows = slots.indices.map { grid(CGFloat($0) * 23 + 11.5) }
        let routes = rows.map { y in
            PixelRoute.path([.init(grid(44), mid), .init(bend, mid), .init(bend, y), .init(end, y)])
        }
        for (index, route) in routes.enumerated() {
            let lit = activity.count(for: slots[index].id) > 0
            brush.dotted(route, lit ? ink(index) : .white, lit ? 0.4 : 0.12)
        }
        brush.sprite(Self.terminal, at: .init(grid(28), mid), Color(white: 0.85))
        brush.sprite(Self.chip, at: .init(grid(center.x), mid), mint, busy ? 1 : 0.45)
        if busy && Int(time * 4) % 2 == 0 {
            brush.cell(.init(grid(center.x) - 2, mid - 3), .white); brush.cell(.init(grid(center.x) + 2, mid + 3), .white)
        }
        for (index, y) in rows.enumerated() {
            brush.sprite(Self.server, at: .init(end + 3, y), ink(index), activity.count(for: slots[index].id) > 0 ? 1 : 0.45)
        }
        guard !reduceMotion else { return }
        brush.traffic(activity, slots: slots, routes: routes, time: time, body: ink, nose: { _ in .white }, spark: { _ in .white })
        if !busy { brush.twinkle(routes, time: time, color: mint, alpha: 0.35) }
    }
}

/// Shared pixel art for the dashboard flow map and the desktop lane: a 3 pt grid, rockets
/// with a flickering exhaust, and a ring burst where a request lands.
struct PixelBrush {
    static let pixel: CGFloat = 3
    static let flame = [Color(red: 1, green: 0.82, blue: 0.4), Color(red: 1, green: 0.42, blue: 0.21)]
    static let failures: Set<String> = ["refused", "network_error", "interrupted", "rejected"]
    static func grid(_ value: CGFloat) -> Int { Int((value / pixel).rounded()) }
    let context: GraphicsContext
    func cell(_ c: PixelRoute.Cell, _ color: Color, _ alpha: Double = 1) {
        context.fill(Path(CGRect(x: CGFloat(c.x) * Self.pixel, y: CGFloat(c.y) * Self.pixel, width: Self.pixel, height: Self.pixel)), with: .color(color.opacity(alpha)))
    }
    func sprite(_ rows: [String], at c: PixelRoute.Cell, _ color: Color, _ alpha: Double = 1) {
        for (j, row) in rows.enumerated() {
            for (i, ch) in row.enumerated() where ch == "#" {
                cell(.init(c.x - row.count / 2 + i, c.y - rows.count / 2 + j), color, alpha)
            }
        }
    }
    func dotted(_ route: [PixelRoute.Cell], _ color: Color, _ alpha: Double) {
        for (k, c) in route.enumerated() where k % 2 == 0 { cell(c, color, alpha) }
    }
    /// One rocket per request in flight, then a burst on the route of the latest outcome.
    func traffic(_ activity: RoutingActivity, slots: [AccountSlot], routes: [[PixelRoute.Cell]], time: TimeInterval,
                 body: (Int) -> Color, nose: (Int) -> Color, spark: (Int) -> Color) {
        for (request, account) in activity.active.sorted(by: { $0.key < $1.key }) {
            guard let index = slots.firstIndex(where: { $0.id == account }), index < routes.count, routes[index].count > 2 else { continue }
            let route = routes[index]
            let k = PixelRoute.head(time: time, offset: PixelRoute.offset(for: request), count: route.count)
            let head = route[k], next = route[min(route.count - 1, k + 1)]
            let dx = next.x - head.x, dy = next.y - head.y
            for step in 1...4 where (Int(time * 30) + step * 7 + k) % 3 != 0 {
                cell(route[max(0, k - step)], Self.flame[step < 2 ? 0 : 1], 0.9 - Double(step) * 0.18)
            }
            cell(head, body(index))
            cell(.init(head.x + dx, head.y + dy), nose(index))
            cell(.init(head.x - dy, head.y - dx), body(index))
            cell(.init(head.x + dy, head.y + dx), body(index))
        }
        guard let last = activity.lastAccount, let index = slots.firstIndex(where: { $0.id == last }), index < routes.count,
              let target = routes[index].last, let burst = PixelRoute.burst(age: Date().timeIntervalSince(activity.changedAt)) else { return }
        let failed = Self.failures.contains(activity.lastKind)
        guard failed || activity.lastKind == "completed" else { return }
        let n = failed ? 8 : 12
        for j in 0..<n {
            let angle = Double(j) / Double(n) * 2 * .pi
            let c = PixelRoute.Cell(target.x + Int((cos(angle) * burst.radius).rounded()), target.y + Int((sin(angle) * burst.radius).rounded()))
            cell(c, failed ? .red : (j % 2 == 0 ? spark(index) : body(index)), burst.alpha)
        }
    }
    func twinkle(_ routes: [[PixelRoute.Cell]], time: TimeInterval, color: Color, alpha: Double) {
        let tick = Int(time * 6)
        for (index, route) in routes.enumerated() where !route.isEmpty && (tick / 5 + index) % 3 == 0 {
            cell(route[(tick + index * 7) % route.count], color, alpha)
        }
    }
}

/// Desktop widget lane: requests leave the local gateway and drop into the card of the account serving them.
struct RoutingLane: View {
    static let height: CGFloat = 30
    @ObservedObject var store: AppStore
    let columns: Int
    let spacing: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    private static let terminal = ["#####", "#...#", "#.#.#", "#...#", "#####"]
    private static let chip = [".#.#.", "#####", "#...#", "#####", ".#.#."]
    private let green = Color(red: 0.15, green: 0.66, blue: 0.4)
    var body: some View {
        let activity = store.routingActivity
        let lively = !activity.active.isEmpty || Date().timeIntervalSince(activity.changedAt) < 0.6
        TimelineView(.animation(minimumInterval: lively ? 1.0 / 30 : 1.0 / 8, paused: !visible || reduceMotion)) { tick in
            Canvas { context, size in draw(PixelBrush(context: context), size: size, time: tick.date.timeIntervalSinceReferenceDate) }
        }
        .frame(height: Self.height).allowsHitTesting(false)
        .accessibilityElement().accessibilityLabel(activity.active.isEmpty ? "实时路由，空闲" : "实时路由，\(activity.active.count) 个请求处理中")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            if let panel = notification.object as? DesktopPanel, panel.frameAutosaveName == "CodexEmbeddedWidget" {
                visible = panel.isVisible && panel.occlusionState.contains(.visible)
            }
        }
    }
    private func draw(_ brush: PixelBrush, size: CGSize, time: TimeInterval) {
        let slots = store.saved.accounts, activity = store.routingActivity
        guard !slots.isEmpty, columns > 0 else { return }
        func paper(_ index: Int) -> Color { CoverPalette.all[index % CoverPalette.all.count].paper }
        func ink(_ index: Int) -> Color { CoverPalette.all[index % CoverPalette.all.count].ink }
        let width = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let centers = (0..<columns).map { PixelBrush.grid(CGFloat($0) * (width + spacing) + width / 2) }
        let bus = 3, bottom = Int(size.height / PixelBrush.pixel) - 1, chip = 11
        let routes = slots.indices.map { i in
            PixelRoute.path([.init(chip + 3, bus), .init(centers[i % columns], bus), .init(centers[i % columns], bottom)])
        }
        let busy = !activity.active.isEmpty
        for (index, route) in routes.enumerated() {
            let lit = activity.count(for: slots[index].id) > 0
            brush.dotted(route, lit ? paper(index) : .black, lit ? 0.55 : 0.12)
            if let end = route.last, index < columns {
                for dx in -2...2 { brush.cell(.init(end.x + dx, end.y), paper(index), lit ? 0.9 : 0.35) }
            }
        }
        brush.sprite(Self.terminal, at: .init(3, bus), Color(white: 0.3))
        brush.dotted(PixelRoute.path([.init(6, bus), .init(chip - 3, bus)]), .black, 0.25)
        brush.sprite(Self.chip, at: .init(chip, bus), busy ? green : Color(white: 0.45), busy ? 1 : 0.6)
        guard !reduceMotion else { return }
        brush.traffic(activity, slots: slots, routes: routes, time: time, body: paper, nose: ink, spark: ink)
        if !busy { brush.twinkle(routes, time: time, color: green, alpha: 0.55) }
    }
}

/// Small green dots: the latest request was routed, and its reply was served from the prompt cache.
struct RoutingHealthDots: View {
    @ObservedObject var store: AppStore
    var dark = false
    var body: some View {
        let activity = store.routingActivity, ready = store.gatewayReady
        HStack(spacing: 8) {
            dot("路由", state: ready ? activity.lastRouted : nil, help: routedHelp(activity, ready: ready))
            dot("缓存", state: ready ? activity.lastCache.map { $0.hit ? true : nil } ?? nil : nil, help: cacheHelp(activity, ready: ready))
        }.font(.system(size: 9, weight: .semibold))
    }
    private func dot(_ label: String, state: Bool?, help: String) -> some View {
        let green = dark ? Color(red: 0.35, green: 0.9, blue: 0.5) : Color(red: 0.16, green: 0.66, blue: 0.3)
        return HStack(spacing: 3) {
            Circle().fill(state == true ? green : (state == false ? .orange : .clear))
                .overlay(Circle().stroke(state == nil ? Color.secondary.opacity(0.6) : .clear, lineWidth: 1))
                .frame(width: 6, height: 6)
            Text(label)
        }.help(help).accessibilityElement(children: .ignore).accessibilityLabel(label + "，" + help)
    }
    private func routedHelp(_ activity: RoutingActivity, ready: Bool) -> String {
        guard ready else { return "网关未就绪" }
        let name = activity.lastAccount.flatMap { store.slot($0)?.displayName } ?? "账号"
        switch activity.lastRouted {
        case true?: return "最近一次请求已由 \(name) 完成"
        case false?: return "最近一次请求失败或被拒"
        case nil: return "还没有经过网关的请求"
        }
    }
    private func cacheHelp(_ activity: RoutingActivity, ready: Bool) -> String {
        guard ready, let cache = activity.lastCache else { return "还没有可统计的回复" }
        guard cache.hit else { return "最近一次回复未命中 prompt cache" }
        return "最近一次回复命中 prompt cache：\(cache.cached.formatted()) / \(cache.input.formatted()) token（\(cache.percent)%）"
    }
}
