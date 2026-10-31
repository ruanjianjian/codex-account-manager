import AppKit
import SwiftUI
import AccountCore

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var resizingFromHandle = false
    var didResizeFromHandle: (() -> Void)?
}
private struct ResizeSurface: NSViewRepresentable {
    final class Handle: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? DesktopPanel else { return }
            let initial = panel.frame
            let start = NSEvent.mouseLocation
            panel.resizingFromHandle = true
            defer { panel.resizingFromHandle = false; panel.didResizeFromHandle?() }
            while let next = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let pointer = NSEvent.mouseLocation
                let area = panel.screen?.visibleFrame ?? initial
                let maxWidth = min(panel.maxSize.width, area.maxX - initial.minX)
                let maxHeight = min(panel.maxSize.height, initial.maxY - area.minY)
                let width = min(maxWidth, max(panel.minSize.width, initial.width + pointer.x - start.x))
                let height = min(maxHeight, max(panel.minSize.height, initial.height + start.y - pointer.y))
                panel.setFrame(NSRect(x: initial.minX, y: initial.maxY - height, width: width, height: height), display: true)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = L("拖动调整大小", "Drag to resize"); nsView.setAccessibilityLabel(L("拖动调整组件大小", "Drag to resize the widget"))
    }
}
struct DragSurface: NSViewRepresentable {
    /// Moves the window itself rather than through performDrag, which a desktop-level panel ignores.
    final class Handle: NSView {
        private var start: (mouse: NSPoint, origin: NSPoint)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // Global event position (y grows downward), independent of where the window has moved to.
        private func global(_ event: NSEvent) -> NSPoint? { event.cgEvent?.location }
        override func mouseDown(with event: NSEvent) {
            guard let window, let mouse = global(event) else { return }
            start = (mouse, window.frame.origin)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let start, let mouse = global(event) else { return }
            window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y - (mouse.y - start.mouse.y)))
        }
        override func mouseUp(with event: NSEvent) { start = nil }
    }
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = L("拖动组件", "Drag the widget") }
}

struct CoverPalette {
    let paper: Color
    let ink: Color
    static let all: [CoverPalette] = [
        .init(paper: Color(red: 0.025, green: 0.17, blue: 0.32), ink: Color(red: 1, green: 0.18, blue: 0.74)),
        .init(paper: Color(red: 0, green: 0.46, blue: 0.53), ink: Color(red: 0.93, green: 1, blue: 0.05)),
        .init(paper: Color(red: 0.37, green: 0.27, blue: 0.20), ink: Color(red: 0.24, green: 1, blue: 0.05)),
        .init(paper: Color(red: 0.36, green: 0.43, blue: 0.01), ink: Color(red: 1, green: 0.67, blue: 0.46)),
        .init(paper: Color(red: 0.30, green: 0.20, blue: 0.43), ink: Color(red: 1, green: 0.73, blue: 0)),
        .init(paper: Color(red: 0.23, green: 0.26, blue: 0.27), ink: Color(red: 1, green: 0.27, blue: 0.43))
    ]
}

struct DesktopWidgetView: View {
    static func size(for count: Int) -> NSSize {
        let rows = min(3, max(1, (count + 1) / 2))
        return NSSize(width: 400, height: 200 + rows * 144 + (rows - 1) * 10)
    }
    @ObservedObject var store: AppStore
    let present: (WidgetAction) -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    DragSurface()
                    MascotHeader(store: store)
                }.frame(maxWidth: .infinity).frame(height: 28)
                Button { present(.add) } label: { Image(systemName: "plus").frame(width: 22, height: 24).contentShape(Rectangle()) }
                    .help(L("添加账号", "Add account")).accessibilityLabel(L("添加新的Codex账号", "Add a new Codex account"))
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isBusy || store.preview).help(L("刷新所有账号", "Refresh all accounts")).accessibilityLabel(L("刷新组件额度", "Refresh widget quotas"))
                Button { store.setDesktopPinned(!store.desktopPinned) } label: { Image(systemName: store.desktopPinned ? "pin.fill" : "pin") }
                    .help(L("组件置顶", "Keep widget on top")).accessibilityLabel(store.desktopPinned ? L("取消组件置顶", "Stop keeping the widget on top") : L("置顶组件", "Keep the widget on top"))
                Button { present(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L("设置", "Settings")).accessibilityLabel(L("打开设置", "Open Settings"))
            }.buttonStyle(.plain).font(.system(size: 13))
            if store.gatewayEnabled { RoutingActivityView(store: store) } else if !store.preview { RoutingSetupView(store: store) }
            if let banner = store.banner {
                HStack(alignment: .top) {
                    Text(banner).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("关闭提示", "Dismiss"))
                }.foregroundStyle(.orange)
            }
            ScrollView {
            LazyVGrid(columns: [.init(.flexible(), spacing: 10), .init(.flexible())], spacing: 10) {
                ForEach(Array(store.saved.accounts.enumerated()), id: \.element.id) { index, slot in
                    cover(slot, index: index)
                }

            }
            }.scrollIndicators(.hidden)
                .overlay {
                    if store.saved.accounts.isEmpty {
                        DangoWelcome { present(.add) }
                    }
                }
            TokenActivityMini(store: store) { present(.activity) }
            HStack(spacing: 6) {
                Text(store.preview ? L("模拟数据", "Sample data") : L("\(store.connectedCount)/\(store.saved.accounts.count) 已连接", "\(store.connectedCount)/\(store.saved.accounts.count) connected"))
                Spacer()
                Text(store.isBusy ? L("同步中", "Syncing") : L("每分钟同步", "Syncs every minute"))
                Button { store.setDesktopVisible(false) } label: { Text(store.shortcutChoice == "none" ? L("隐藏", "Hide") : store.shortcutLabel + L(" 隐藏", " Hide")) }
                    .buttonStyle(.plain).help(store.shortcutChoice == "none" ? L("隐藏后可从菜单栏呼出", "Bring it back from the menu bar") : L("隐藏后可用快捷键呼出", "Bring it back with the shortcut"))
            }.font(.system(size: 10, weight: .medium)).frame(height: 16)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(white: 0.12))
        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10)).rotationEffect(.degrees(-45))
                    .foregroundStyle(.secondary.opacity(0.6)).allowsHitTesting(false)
                ResizeSurface()
            }.frame(width: 20, height: 20).help(L("拖动调整大小", "Drag to resize"))
        }
        .preferredColorScheme(.light)
    }
    private func cover(_ slot: AccountSlot, index: Int) -> some View {
        let colors = CoverPalette.all[index % CoverPalette.all.count]
        let state = store.status[slot.id] ?? .disconnected
        let fresh = state == .connected && slot.snapshot?.isFresh(at: store.now) == true
        let windows = slot.snapshot?.rates.windows ?? []
        let remaining = windows.compactMap(\.remaining).min()
        let count = slot.snapshot?.rates.rateLimitResetCredits?.availableCount
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 3) {
                    if let profile = store.profileCaption(slot) { Text(profile).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                    Button { store.chooseAccount(slot.id) } label: {
                        Text(slot.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }.buttonStyle(.plain)
                        .disabled(store.preview || slot.expectedAccountID == nil)
                        .help(store.accountActionLabel(slot.id))
                        .accessibilityLabel("\(slot.displayName) · \(store.accountActionLabel(slot.id))")
                }
                Spacer(minLength: 0)
                Menu { accountActions(slot) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().environment(\.colorScheme, .dark)
                    .accessibilityLabel(L("\(slot.displayName) 账号选项", "\(slot.displayName) account options"))
            }
            Spacer(minLength: 2)
            if let remaining {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(remaining))").font(.system(size: 38, weight: .black, design: .default)).tracking(-1.5)
                    Text("%").font(.system(size: 17, weight: .bold))
                    Spacer(minLength: 4)
                    if !fresh {
                        Text(L("旧快照\n", "Old snapshot\n") + state.label).font(.system(size: 8)).tracking(0)
                            .foregroundStyle(.white).multilineTextAlignment(.trailing).lineLimit(3)
                            .help(L("旧快照 · ", "Old snapshot · ") + state.label)
                    }
                }.foregroundStyle(colors.ink).monospacedDigit()
                    .accessibilityLabel(L("\(slot.displayName) 最低窗口余量 \(Int(remaining))%", "\(slot.displayName), lowest window \(Int(remaining))% left"))
            } else {
                Button { store.connectOrContinue(slot.id) } label: {
                    Text("＋").font(.system(size: state.message == nil ? 32 : 24, weight: .light)).foregroundStyle(colors.ink)
                }.buttonStyle(.plain).disabled(!store.canOpenConnection(slot.id))
                    .accessibilityLabel("\(slot.displayName) · \(store.connectionLabel(slot.id))")
            }
            Spacer(minLength: 2)
            if windows.isEmpty {
                if let message = state.message { Text(message).font(.system(size: 10)).lineLimit(3).help(message).padding(.bottom, 4) }
                Button(store.connectionLabel(slot.id)) { store.connectOrContinue(slot.id) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                    .disabled(!store.canOpenConnection(slot.id))
                if store.loginSlotID == slot.id {
                    Button(L("取消授权", "Cancel sign-in")) { Task { await store.cancelLogin() } }.buttonStyle(.plain).font(.system(size: 10)).padding(.top, 4)
                } else {
                    Text(state.message == nil ? L("登录后自动保存", "Saved once you sign in") : L("请选择另一个账号", "Choose another account")).font(.system(size: 10)).padding(.top, 4)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("\(window.label) · \(window.remaining.map { "\(Int($0))%" } ?? "未知")", "\(window.label) · \(window.remaining.map { "\(Int($0))%" } ?? "unknown")"))
                                Text(Presentation.resetCountdown(window.resetDate, now: store.now))
                                    .help(window.resetDate?.formatted(date: .abbreviated, time: .shortened) ?? L("重置时间未知", "Reset time unknown"))
                            }
                        }
                    }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden).frame(height: windows.count > 1 ? 52 : 28)
            }
            HStack {
                Text("BANKED RESET").font(.system(size: 8, weight: .bold)).tracking(0.5)
                Spacer()
                Text(count.map(String.init) ?? "—").font(.system(size: 12, weight: .bold)).monospacedDigit()
            }.padding(.top, 5)
        }
        .padding(10).frame(maxWidth: .infinity).frame(height: windows.isEmpty ? 168 : (windows.count > 1 ? 168 : 144))
        .foregroundStyle(.white).background(colors.paper)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 12, topTrailingRadius: 12))
        .contextMenu { accountActions(slot) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func accountActions(_ slot: AccountSlot) -> some View {
        Button(store.accountActionLabel(slot.id)) { store.chooseAccount(slot.id) }
            .disabled(store.preview || slot.expectedAccountID == nil)
        Divider()
        Button(L("额度与 reset 明细…", "Quota and reset details…")) { present(.details(slot.id)) }.disabled(slot.snapshot == nil)
        Button(L("名称与浏览器…", "Name and browser…")) { present(.edit(slot)) }
        Button(L("刷新", "Refresh")) { store.refresh(slot.id) }.disabled(store.status[slot.id] == .checking || store.preview)
        Button(L("在浏览器查看用量", "View usage in the browser")) { store.openAccountPage(slot.id) }
        Divider()
        if store.loginSlotID == slot.id {
            Button(L("继续授权", "Continue sign-in")) { store.reopenLogin() }
            Button(L("取消授权", "Cancel sign-in")) { Task { await store.cancelLogin() } }
        } else {
            Button(L("重新连接", "Reconnect")) { store.connect(slot.id) }
                .disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
        }
        Button(L("移除账号…", "Remove account…"), role: .destructive) { present(.remove(slot)) }
            .disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
    }
}

/// The panel's top line: the mascot, and what it has to say about routing right now. Tibo's reset reminder is
/// said here too, and opens the post.
private struct MascotHeader: View {
    @ObservedObject var store: AppStore
    @State private var switched: Mascot.Switch?
    var body: some View {
        let line = store.mascotLine(switched: switched)
        HStack(spacing: 8) {
            LiveDango(mood: line.mood, busy: !store.routingActivity.active.isEmpty).frame(width: 24, height: 24)
                .allowsHitTesting(false)
            bubble(line)
        }
        // A switch is news for a few seconds, then the usual line comes back.
        .onChange(of: store.currentAccountID) { old, new in
            guard store.gatewayEnabled, let old, let new, old != new else { return }
            let move = Mascot.Switch(from: old, to: new)
            switched = move
            Task { try? await Task.sleep(for: .seconds(6)); if switched == move { switched = nil } }
        }
    }
    @ViewBuilder private func bubble(_ line: Mascot.Line) -> some View {
        let alert = line.mood == .star ? store.resetAlert : nil
        let fill = alert == nil ? Color(white: 0.9) : Color(red: 1, green: 0.92, blue: 0.83)
        let text = Text(line.text).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { BubbleTail().fill(fill).frame(width: 5, height: 8).offset(x: -4) }
        if let alert {
            Link(destination: alert.url) { text.foregroundStyle(Color(red: 0.75, green: 0.32, blue: 0.02)) }.help(L("打开 Tibo 原帖", "Open Tibo's post"))
        } else {
            text.allowsHitTesting(false)
        }
    }
}
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
    }
}
