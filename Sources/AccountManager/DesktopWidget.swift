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
    func makeNSView(context: Context) -> NSView {
        let view = Handle(); view.toolTip = "拖动调整大小"; view.setAccessibilityLabel("拖动调整组件大小"); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
private struct DragSurface: NSViewRepresentable {
    final class Handle: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Handle(); view.toolTip = "拖动组件"; return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
                    Text("CODEX / ACCOUNTS").font(.system(size: 12, weight: .heavy)).tracking(0.6).allowsHitTesting(false)
                }.frame(maxWidth: .infinity).frame(height: 24)
                Button { present(.add) } label: { Image(systemName: "plus").frame(width: 22, height: 24).contentShape(Rectangle()) }
                    .help("添加账号").accessibilityLabel("添加新的Codex账号")
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isBusy || store.preview).help("刷新所有账号").accessibilityLabel("刷新组件额度")
                Button { store.setDesktopPinned(!store.desktopPinned) } label: { Image(systemName: store.desktopPinned ? "pin.fill" : "pin") }
                    .help("组件置顶").accessibilityLabel(store.desktopPinned ? "取消组件置顶" : "置顶组件")
                Button { present(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                    .help("设置").accessibilityLabel("打开设置")
            }.buttonStyle(.plain).font(.system(size: 13))
            if store.gatewayEnabled {
                HStack {
                    Image(systemName: store.gatewayReady ? "arrow.triangle.branch" : "exclamationmark.circle")
                    Text(store.gatewayCaption).lineLimit(2)
                    Spacer(minLength: 0)
                    if !store.gatewayPreferred.isEmpty { Button("自动") { store.selectGatewayAccount("") }.buttonStyle(.plain) }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(store.gatewayReady ? Color.secondary : Color.orange)
            }
            if let banner = store.banner {
                HStack(alignment: .top) {
                    Text(banner).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
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
                        Button("＋ 添加第一个账号") { present(.add) }.buttonStyle(.plain)
                    }
                }
            TokenActivityMini(store: store) { present(.activity) }
            HStack(spacing: 6) {
                Text(store.preview ? "模拟数据" : "\(store.connectedCount)/\(store.saved.accounts.count) 已连接")
                Spacer()
                Text(store.isBusy ? "同步中" : "每分钟同步")
                Button { store.setDesktopVisible(false) } label: { Text(store.shortcutChoice == "none" ? "隐藏" : store.shortcutLabel + " 隐藏") }
                    .buttonStyle(.plain).help(store.shortcutChoice == "none" ? "隐藏后可从菜单栏呼出" : "隐藏后可用快捷键呼出")
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
            }.frame(width: 20, height: 20).help("拖动调整大小")
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
                    Button { store.openAccountDesktop(slot.id) } label: {
                        Text(slot.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }.buttonStyle(.plain)
                        .disabled(store.preview || store.loginSlotID != nil || !store.launchingDesktop.isEmpty || slot.expectedAccountID == nil)
                        .help(store.desktopActionLabel(slot.id))
                        .accessibilityLabel("\(slot.displayName) · \(store.desktopActionLabel(slot.id))")
                }
                Spacer(minLength: 0)
                Menu { accountActions(slot) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().environment(\.colorScheme, .dark)
                    .accessibilityLabel("\(slot.displayName) 账号选项")
            }
            Spacer(minLength: 2)
            if let remaining {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(remaining))").font(.system(size: 38, weight: .black, design: .default)).tracking(-1.5)
                    Text("%").font(.system(size: 17, weight: .bold))
                    Spacer(minLength: 4)
                    if !fresh {
                        Text("旧快照\n" + state.label).font(.system(size: 8)).tracking(0)
                            .foregroundStyle(.white).multilineTextAlignment(.trailing).lineLimit(3)
                            .help("旧快照 · " + state.label)
                    }
                }.foregroundStyle(colors.ink).monospacedDigit()
                    .accessibilityLabel("\(slot.displayName) 最低窗口余量 \(Int(remaining))%")
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
                    Button("取消授权") { Task { await store.cancelLogin() } }.buttonStyle(.plain).font(.system(size: 10)).padding(.top, 4)
                } else {
                    Text(state.message == nil ? "登录后自动保存" : "请选择另一个账号").font(.system(size: 10)).padding(.top, 4)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(window.label) · \(window.remaining.map { "\(Int($0))%" } ?? "未知")")
                                Text(Presentation.countdown(window.resetDate, now: store.now).replacingOccurrences(of: "后", with: "后重置"))
                                    .help(window.resetDate?.formatted(date: .abbreviated, time: .shortened) ?? "重置时间未知")
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
        Button(store.desktopActionLabel(slot.id)) { store.openAccountDesktop(slot.id) }
            .disabled(store.preview || store.loginSlotID != nil || !store.launchingDesktop.isEmpty || slot.expectedAccountID == nil)
        Divider()
        Button("额度与 reset 明细…") { present(.details(slot.id)) }.disabled(slot.snapshot == nil)
        Button("名称与浏览器…") { present(.edit(slot)) }
        Button("刷新") { store.refresh(slot.id) }.disabled(store.status[slot.id] == .checking || store.preview)
        Button("在浏览器查看用量") { store.openAccountPage(slot.id) }
        Divider()
        if store.loginSlotID == slot.id {
            Button("继续授权") { store.reopenLogin() }
            Button("取消授权") { Task { await store.cancelLogin() } }
        } else {
            Button("重新连接") { store.connect(slot.id) }
                .disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
        }
        Button("移除账号…", role: .destructive) { present(.remove(slot)) }
            .disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
    }
}
