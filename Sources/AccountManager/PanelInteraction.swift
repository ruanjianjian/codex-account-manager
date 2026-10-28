import AppKit
import AccountCore
import OSLog

/// Observes mouse position without recording trajectories or installing a key tap.
@MainActor final class PanelInteraction: NSObject {
    weak var panel: NSPanel?
    weak var trigger: NSView?
    var pinned: () -> Bool = { false }
    var canShow: () -> Bool = { true }
    var show: () -> Void = {}
    var hide: () -> Void = {}
    private var hover = PanelHover()
    private var timer: Timer?
    private var menuDepth = 0
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusFrames: [CGRect] = []
    private var lastFrameRefresh: TimeInterval = -.infinity
    private let log = Logger(subsystem: "io.github.ruanjianjian.codex-accounts", category: "hover")

    func start(panel: NSPanel, trigger: NSView) {
        stop()
        self.panel = panel; self.trigger = trigger
        // NSStatusBarButton tracking callbacks are not reliable on all menu-bar
        // hosts. Sampling also detects entry while another app is frontmost.
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // System-hosted status items may be reported as global events.
                let pointer = NSEvent.mouseLocation
                if !self.triggerFrames(at: pointer).contains(where: { $0.contains(pointer) }) { self.outsideInteraction() }
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel && event.window !== self.trigger?.window { self.outsideInteraction() }
            }
            return event
        }) { monitors.append(monitor) }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuDepth += 1; self?.cancelPendingOpen() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.menuDepth = max(0, self.menuDepth - 1) }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
                    self?.outsideInteraction()
                }
            })
        }
    }

    private func triggerFrames(at pointer: NSPoint) -> [CGRect] {
        guard let trigger, let window = trigger.window else { return [] }
        let screens = NSScreen.screens
        // Only inspect our menu-bar windows while the pointer is near a menu bar.
        guard screens.contains(where: { $0.frame.contains(pointer) && pointer.y >= $0.frame.maxY - max(40, NSStatusBar.system.thickness + $0.safeAreaInsets.top) }) else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrameRefresh >= 1 {
            lastFrameRefresh = now
            let primaryTop = screens.first?.frame.maxY ?? 0
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            statusFrames = list.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier,
                      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == window.level.rawValue,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
                return PanelHover.appKitRect(fromQuartz: rect, primaryTop: primaryTop)
            }
        }
        // Use the button's current bounds as well: its width can change with quota
        // updates before the cached system list refreshes. Never guess a mirrored
        // icon position from another display's dimensions.
        var frames = statusFrames
        if window.isVisible && !trigger.isHidden {
            frames.append(window.convertToScreen(trigger.convert(trigger.bounds, to: nil)))
        }
        return frames
    }
    private func samplePointer() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let overTrigger = triggerFrames(at: pointer).contains { $0.contains(pointer) }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
        let sameScreen = pointerScreen?.frame == panel.screen?.frame
        let action = hover.sample(now: ProcessInfo.processInfo.systemUptime,
                                  overTrigger: overTrigger,
                                  overPanel: panel.isVisible && panel.frame.contains(pointer),
                                  visible: panel.isVisible,
                                  needsShow: !panel.isVisible || !sameScreen,
                                  pinned: pinned(),
                                  interacting: menuDepth > 0 || NSEvent.pressedMouseButtons != 0 || panel.inLiveResize || !canShow())
        switch action {
        case .show:
            show()
            // Diagnostics contain only event timestamps, no coordinates/accounts.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hover.lastOpenedAt")
            log.info("Pointer dwell opened account panel")
        case .hide:
            hide()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hover.lastDismissedAt")
        case nil: break
        }
    }
    func cancelPendingOpen() { hover.suppressUntilExit() }
    private func outsideInteraction() {
        cancelPendingOpen()
        guard !pinned(), menuDepth == 0 else { return }
        hide()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers.removeAll()
        statusFrames.removeAll(); lastFrameRefresh = -.infinity; menuDepth = 0; hover = PanelHover()
    }
}
