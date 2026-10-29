import AppKit
import Combine
import SwiftUI
import UserNotifications
import AccountCore

@main struct Main {
    @MainActor static func main() {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var store: AppStore!
    private var window: NSWindow?
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private var desktopPanel: DesktopPanel!
    private var embeddedPanel: DesktopPanel!
    private let hotKey = GlobalHotKey()
    private let interaction = PanelInteraction()
    private var shortcutPresented = false
    private var routingWatch: AnyCancellable?
    private var hopTimer: Timer?
    private var hopFrame = 0
    private var preferredWidgetSize: NSSize? {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "desktop.width")
        let height = defaults.double(forKey: "desktop.height")
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore(preview: CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier?.hasSuffix("-preview") == true)
        installMainMenu()
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "悬停查看账号；移开收起；右键打开菜单"
        store.onChange = { [weak self] in self?.updateMenu() }
        routingWatch = store.$routingActivity.sink { [weak self] activity in
            DispatchQueue.main.async { self?.animateStatusIcon(busy: !activity.active.isEmpty) }
        }
        makeDesktopPanel()
        makeEmbeddedPanel()
        if let button = statusItem.button {
            interaction.pinned = { [weak self] in self?.store.desktopPinned ?? false }
            interaction.canShow = { [weak self] in self?.window?.isVisible != true }
            interaction.show = { [weak self] in self?.presentWidget(toggle: false) }
            interaction.hide = { [weak self] in self?.dismissTransientPanel() }
            interaction.start(panel: desktopPanel, trigger: button)
        }
        store.onDesktopChange = { [weak self] in self?.updateDesktopPanel(); self?.updateMenu() }
        hotKey.action = { [weak self] in self?.toggleFromShortcut() }
        store.onShortcutChange = { [weak self] in self?.registerShortcut() }
        registerShortcut()
        updateMenu(); updateDesktopPanel()
        // Launch restores only the widget visibility; there is no separate dashboard.
    }
    private func widgetSize(on screen: NSScreen?) -> NSSize {
        let preferred = preferredWidgetSize ?? DesktopWidgetView.size(for: store.saved.accounts.count)
        return WidgetPlacement.fittedSize(preferred, visibleFrame: screen?.visibleFrame)
    }
    private func updateResizeLimits(on screen: NSScreen?) {
        let available = screen?.visibleFrame.size ?? NSSize(width: 4096, height: 4096)
        desktopPanel.maxSize = NSSize(width: max(1, available.width - 16), height: max(1, available.height - 16))
        desktopPanel.minSize = NSSize(width: min(400, desktopPanel.maxSize.width), height: min(480, desktopPanel.maxSize.height))
    }
    private func dismissTransientPanel() {
        guard !store.desktopPinned, store.desktopVisible else { return }
        shortcutPresented = false; store.setDesktopVisible(false)
    }
    private func makeDesktopPanel() {
        desktopPanel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: DesktopWidgetView.size(for: store.saved.accounts.count).width, height: DesktopWidgetView.size(for: store.saved.accounts.count).height), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        desktopPanel.title = "Codex Accounts Beta · 账号"
        desktopPanel.isOpaque = false; desktopPanel.backgroundColor = .clear
        desktopPanel.hasShadow = true; desktopPanel.hidesOnDeactivate = false
        desktopPanel.isReleasedWhenClosed = false; desktopPanel.delegate = self
        desktopPanel.didResizeFromHandle = { [weak self] in self?.saveWidgetSize() }
        desktopPanel.isMovableByWindowBackground = true
        desktopPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        desktopPanel.contentView = NSHostingView(rootView: DesktopWidgetView(store: store, present: { [weak self] action in self?.present(action) }))
        if !desktopPanel.setFrameUsingName("CodexDesktopPanel") { resetDesktopPosition() }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: desktopPanel.frame.midX, y: desktopPanel.frame.midY)) }) { resetDesktopPosition() }
        updateResizeLimits(on: desktopPanel.screen ?? NSScreen.main)
        let top = desktopPanel.frame.maxY
        desktopPanel.setContentSize(widgetSize(on: desktopPanel.screen ?? NSScreen.main))
        if let screen = desktopPanel.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            desktopPanel.setFrameOrigin(NSPoint(x: max(area.minX, min(desktopPanel.frame.minX, area.maxX - desktopPanel.frame.width)), y: max(area.minY, min(top - desktopPanel.frame.height, area.maxY - desktopPanel.frame.height))))
        }
        desktopPanel.setFrameAutosaveName("CodexDesktopPanel")
    }
    /// Desktop level, like macOS's own widgets: every app window covers it, it stays on all Spaces.
    private func makeEmbeddedPanel() {
        embeddedPanel = DesktopPanel(contentRect: NSRect(origin: .zero, size: EmbeddedWidgetView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        embeddedPanel.title = "Codex Accounts Beta · 桌面组件"
        embeddedPanel.isOpaque = false; embeddedPanel.backgroundColor = .clear
        embeddedPanel.hasShadow = true; embeddedPanel.hidesOnDeactivate = false
        embeddedPanel.isReleasedWhenClosed = false; embeddedPanel.isMovableByWindowBackground = true
        embeddedPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        embeddedPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        embeddedPanel.contentView = NSHostingView(rootView: EmbeddedWidgetView(store: store, present: { [weak self] action in self?.present(action) }))
        if !embeddedPanel.setFrameUsingName("CodexEmbeddedWidget")
            || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: embeddedPanel.frame.midX, y: embeddedPanel.frame.midY)) }) {
            resetEmbeddedPosition()
        }
        embeddedPanel.setContentSize(EmbeddedWidgetView.size)
        embeddedPanel.setFrameAutosaveName("CodexEmbeddedWidget")
    }
    @objc private func resetEmbeddedPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        embeddedPanel.setFrameOrigin(WidgetPlacement.embeddedOrigin(panelSize: embeddedPanel.frame.size, visibleFrame: screen.visibleFrame))
        embeddedPanel.saveFrame(usingName: "CodexEmbeddedWidget")
    }
    @objc private func resetDesktopPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        desktopPanel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 28, y: screen.visibleFrame.maxY - desktopPanel.frame.height - 28))
        desktopPanel.saveFrame(usingName: "CodexDesktopPanel")
    }
    private func updateDesktopPanel() {
        updateResizeLimits(on: desktopPanel.screen ?? NSScreen.main)
        let size = widgetSize(on: desktopPanel.screen ?? NSScreen.main)
        if !desktopPanel.inLiveResize && !desktopPanel.resizingFromHandle && desktopPanel.frame.size != size {
            let top = desktopPanel.frame.maxY
            desktopPanel.setContentSize(size)
            let bottom = desktopPanel.screen?.visibleFrame.minY ?? 0
            desktopPanel.setFrameOrigin(NSPoint(x: desktopPanel.frame.minX, y: max(bottom, top - size.height)))
        }
        desktopPanel.level = (store.desktopPinned || shortcutPresented) ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if store.desktopVisible { desktopPanel.orderFrontRegardless() } else { desktopPanel.orderOut(nil) }
        if store.embeddedVisible { embeddedPanel.orderFrontRegardless() } else { embeddedPanel.orderOut(nil) }
    }
    private func registerShortcut() {
        if store.shortcutChoice == "none" { hotKey.stop(); store.shortcutIssue = nil; updateMenu(); return }
        let result = hotKey.register(store.shortcutChoice)
        store.shortcutIssue = result == 0 ? nil : "\(store.shortcutLabel) 无法注册，可能已被其他应用占用。请选择另一个两键组合。"
        updateMenu()
    }
    private func toggleFromShortcut() { interaction.cancelPendingOpen(); presentWidget(toggle: true) }
    private func presentWidget(toggle: Bool) {
        // The status item can be mirrored across displays; its window.screen may
        // still refer to the primary display. Use the pointer's global position.
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let target = WidgetPlacement.screenIndex(containing: pointer, frames: screens.map(\.frame)).map { screens[$0] }
            ?? desktopPanel.screen ?? NSScreen.main
        let sameScreen = target.map { $0.frame == desktopPanel.screen?.frame } ?? true
        if toggle && store.desktopVisible && (shortcutPresented || store.desktopPinned) && sameScreen {
            shortcutPresented = false; store.setDesktopVisible(false)
        } else {
            if let target = target {
                updateResizeLimits(on: target)
                desktopPanel.setContentSize(widgetSize(on: target))
                desktopPanel.setFrameOrigin(WidgetPlacement.origin(near: pointer, panelSize: desktopPanel.frame.size, visibleFrame: target.visibleFrame))
                desktopPanel.saveFrame(usingName: "CodexDesktopPanel")
            }
            shortcutPresented = true; store.setDesktopVisible(true); store.refreshAll()
        }
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        interaction.cancelPendingOpen()
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else {
            toggleFromShortcut()
        }
    }
    @objc private func toggleDesktop() { store.setEmbeddedVisible(!store.embeddedVisible) }
    @objc private func toggleDesktopPin() { store.setDesktopPinned(!store.desktopPinned) }
    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === desktopPanel else { return }
        desktopPanel.saveFrame(usingName: "CodexDesktopPanel")
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === desktopPanel else { return }
        saveWidgetSize()
    }
    private func saveWidgetSize() {
        UserDefaults.standard.set(desktopPanel.frame.width, forKey: "desktop.width")
        UserDefaults.standard.set(desktopPanel.frame.height, forKey: "desktop.height")
        desktopPanel.saveFrame(usingName: "CodexDesktopPanel")
    }
    @objc private func resetDesktopSize() {
        UserDefaults.standard.removeObject(forKey: "desktop.width")
        UserDefaults.standard.removeObject(forKey: "desktop.height")
        updateDesktopPanel()
    }
    private func installMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem(); main.addItem(application)
        let appMenu = NSMenu(title: "Codex Accounts Beta")
        application.submenu = appMenu
        let about = NSMenuItem(title: "关于 Codex Accounts Beta", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp; appMenu.addItem(about)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self; appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏账号管家", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp; appMenu.addItem(hide)
        let quitItem = NSMenuItem(title: "退出账号管家", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        let file = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口"); file.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        main.addItem(edit); NSApp.mainMenu = main
    }
    /// The menu-bar tile hops while Codex requests are being routed, and rests when they finish.
    private func animateStatusIcon(busy: Bool) {
        guard busy, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hopTimer?.invalidate(); hopTimer = nil; hopFrame = 0
            statusItem.button?.image = StatusIcon.image
            return
        }
        guard hopTimer == nil else { return }
        hopTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusItem.button?.image = StatusIcon.hop[self.hopFrame % StatusIcon.hop.count]
                self.hopFrame += 1
            }
        }
        RunLoop.main.add(hopTimer!, forMode: .common)
    }
    private func updateMenu() {
        statusItem.button?.title = " " + (store.preview ? "额度预览" : store.menuTitle)
        let menu = NSMenu()
        let open = NSMenuItem(title: "显示账号卡片", action: #selector(showWidget), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let desktop = NSMenuItem(title: "嵌入桌面组件", action: #selector(toggleDesktop), keyEquivalent: "")
        desktop.target = self; desktop.state = store.embeddedVisible ? .on : .off; menu.addItem(desktop)
        let pin = NSMenuItem(title: "组件置顶", action: #selector(toggleDesktopPin), keyEquivalent: "")
        pin.target = self; pin.state = store.desktopPinned ? .on : .off; menu.addItem(pin)
        let position = NSMenuItem(title: "重置组件位置", action: #selector(resetPositions), keyEquivalent: "")
        position.target = self; menu.addItem(position)
        let size = NSMenuItem(title: "恢复默认尺寸", action: #selector(resetDesktopSize), keyEquivalent: "")
        size.target = self; menu.addItem(size)
        menu.addItem(.separator())
        for slot in store.saved.accounts {
            let remaining = slot.snapshot?.rates.windows.compactMap(\.remaining).min().map { "\(Int($0))%" } ?? "未知"
            let status = store.status[slot.id] ?? .disconnected
            let freshness = slot.snapshot?.isFresh(at: store.now) == true && status == .connected ? "" : " · 待同步"
            let item = NSMenuItem(title: "\(slot.displayName)  ·  \(remaining)\(freshness)", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新全部账号", action: #selector(refreshAll), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置…", action: #selector(settings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出账号管家", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusMenu = menu
    }
    @objc private func showWidget() { presentWidget(toggle: false) }
    @objc private func resetPositions() { resetDesktopPosition(); resetEmbeddedPosition() }
    private func present(_ action: WidgetAction) {
        // Align with whichever account view is on screen before the transient one closes.
        let anchor = desktopPanel.isVisible ? desktopPanel.frame : (embeddedPanel.isVisible ? embeddedPanel.frame : nil)
        if case .settings = action { store.settingsHeight = min(800, max(560, anchor.map { desktopPanel.isVisible ? $0.height : 640 } ?? 640)) }
        dismissTransientPanel()
        window?.close()
        let content = WidgetActionView(store: store, action: action, onClose: { [weak self] in self?.window?.close() }, present: { [weak self] in self?.present($0) })
        let utility = NSWindow(contentViewController: NSHostingController(rootView: content))
        utility.title = action.title
        utility.styleMask = [.titled, .closable]
        if case .settings = action {
            // Same chrome as the dashboard: no title bar strip, only the window buttons.
            utility.styleMask.insert(.fullSizeContentView)
            utility.titlebarAppearsTransparent = true; utility.titleVisibility = .hidden
            utility.isMovableByWindowBackground = true; utility.backgroundColor = NSColor(white: 0.97, alpha: 1)
        }
        if case .activity = action {
            utility.styleMask.insert(.resizable)
            utility.contentMinSize = NSSize(width: 520, height: 500)
            utility.setContentSize(NSSize(width: 580, height: 600))
            utility.setFrameUsingName("CodexTokenActivity")
            utility.setFrameAutosaveName("CodexTokenActivity")
        }
        utility.isReleasedWhenClosed = false
        utility.delegate = self
        utility.level = .floating
        window = utility
        let screen = desktopPanel.screen ?? NSScreen.main
        if let area = screen?.visibleFrame, utility.frameAutosaveName.isEmpty {
            utility.setFrameOrigin(WidgetPlacement.besideOrigin(windowSize: utility.frame.size, anchor: anchor, visibleFrame: area))
        }
        NSApp.setActivationPolicy(.regular)
        utility.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func refreshAll() { store.refreshAll() }
    @objc private func settings() { present(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWidget(); return true }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            // Closing a retained NSWindow does not reliably call SwiftUI onDisappear.
            store.endPersonalXInteraction()
            NSApp.setActivationPolicy(.accessory)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { interaction.stop(); hotKey.stop(); store.shutdown() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    /// A reset notification opens Tibo's original post; only a validated x.com/thsottiaux link is followed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo["url"] as? String, let url = TiboPostLink.parse(text)?.url {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
