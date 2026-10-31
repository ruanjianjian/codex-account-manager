import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import AccountCore

struct ChromeProfile: Identifiable { let id: String; let name: String }
enum SlotStatus: Equatable {
    case disconnected, checking, connected, waiting, needsAuth, failure(String), wrongAccount(String)
    var label: String {
        switch self {
        case .disconnected: return L("尚未连接", "Not connected")
        case .checking: return L("正在同步", "Syncing")
        case .connected: return L("已连接", "Connected")
        case .waiting: return L("等待浏览器授权", "Waiting for browser sign-in")
        case .needsAuth: return L("需要重新验证", "Needs to sign in again")
        case .failure: return L("同步失败 · 保留旧数据", "Sync failed · old data kept")
        case .wrongAccount: return L("请核对账号", "Check the account")
        }
    }
    var message: String? {
        switch self { case .failure(let message), .wrongAccount(let message): return message; default: return nil }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var saved: SavedState
    @Published var status: [String: SlotStatus] = [:]
    @Published var loginSlotID: String?
    @Published var launchingDesktop = Set<String>()
    private let accountDesktop = AccountDesktopLauncher()
    private lazy var sharedDesktop = SharedDesktopLogin(root: root)
    @Published var migratingCredentials = false
    @Published var gatewayEnabled = UserDefaults.standard.bool(forKey: "gateway.enabled")
    @Published var gatewayReady = false
    @Published var routingActivity = RoutingActivity()
    @Published var gatewayCaption = L("自动路由未开启", "Auto routing is off")
    @Published var gatewayAccount: String?
    @Published var gatewayPreferred = UserDefaults.standard.string(forKey: "gateway.preferred") ?? ""
    private lazy var gateway = GatewayController(root: root)
    var usesFileCredentials: Bool { sharedDesktop.fileStore.enabled }
    @Published var banner: String?
    /// Moving logins out of the Keychain failed; the setup card offers a retry.
    @Published var storageMoveFailed = false
    @Published var now = Date()
    @Published var profiles: [ChromeProfile] = []
    @Published var loginAtLaunch = false
    // The tall dashboard now only stays up when pinned; otherwise it appears from the menu bar.
    @Published var desktopVisible = UserDefaults.standard.bool(forKey: "desktop.pinned")
    @Published var desktopPinned = UserDefaults.standard.bool(forKey: "desktop.pinned")
    /// Settings match the dashboard's height when opened beside it.
    @Published var settingsHeight: CGFloat = 640
    /// Wide component beside macOS's desktop widgets. Replaces the retired unpinned tall panel.
    @Published var embeddedVisible: Bool = {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "embedded.visible") as? Bool { return value }
        // One-time migration: desktop.visible later only tracks the transient menu-bar panel.
        let migrated = (defaults.object(forKey: "desktop.visible") as? Bool ?? true) && !defaults.bool(forKey: "desktop.pinned")
        defaults.set(migrated, forKey: "embedded.visible")
        return migrated
    }()
    @Published var shortcutChoice = UserDefaults.standard.string(forKey: "desktop.shortcut") ?? "none"
    @Published var shortcutIssue: String?
    @Published var usageErrors: [String: String] = [:]
    @Published var usageLoading = Set<String>()
    @Published var resetMonitor = ResetMonitorState()
    @Published var checkingResetAnnouncements = false
    @Published var personalX = PersonalXState()
    @Published var personalXTesting = false
    private var xBrowser: PersonalXBrowser?
    var personalXBrowser: PersonalXBrowser {
        if let xBrowser { return xBrowser }
        let browser = PersonalXBrowser(); xBrowser = browser; return browser
    }
    private var personalXTask: Task<Void, Never>?
    private var personalXStorageAvailable = true
    private var resetCheckTask: Task<Void, Never>?
    private var nextResetCheck = Date.distantPast
    private var resetCheckFailures = 0
    private var resetCheckGeneration = UUID()
    private var resetNextAttempt: [String: Date] = [:]
    private var resetRefreshBusy = false
    private var resetStorageAvailable = true
    private var lastAutoConnect = Date.distantPast
    private var nextUsagePoll: [String: Date] = [:]

    var onShortcutChange: (() -> Void)?
    var shortcutLabel: String { shortcutChoice == "none" ? L("未设置快捷键", "No shortcut") : shortcutChoice == "ctrl-semicolon" ? "⌃ ;" : (shortcutChoice == "space" ? L("⌥ 空格", "⌥ Space") : "⌥ " + shortcutChoice.uppercased()) }
    func setShortcut(_ choice: String) {
        guard ["none", "ctrl-semicolon", "space", "x"].contains(choice) else { return }
        shortcutChoice = choice; UserDefaults.standard.set(choice, forKey: "desktop.shortcut"); onShortcutChange?()
    }
    var onDesktopChange: (() -> Void)?
    let root: URL
    let preview: Bool
    private var clients: [String: RPCClient] = [:]
    private var collectorRetry = CollectorRetryPolicy()
    private let collectorPauseKey = "collector.pausedAccounts"
    private func persistCollectorPause() {
        if !preview { UserDefaults.standard.set(Array(collectorRetry.paused).sorted(), forKey: collectorPauseKey) }
    }
    private func resumeCollector(_ id: String) {
        collectorRetry.resume(id); persistCollectorPause()
    }
    private func pauseCollectorIfNeeded(_ error: Error, id: String) -> Bool {
        if collectorRetry.paused.contains(id) { return true }
        guard collectorRetry.record(error, account: id, usesKeyring: !usesFileCredentials && desktopSelection?.slotID != id) else { return false }
        persistCollectorPause()
        clients.removeValue(forKey: id)?.stop()
        status[id] = .failure(CollectorRetryPolicy.message)
        usageErrors[id] = CollectorRetryPolicy.message
        banner = L("\(slot(id)?.displayName ?? "账号")：\(CollectorRetryPolicy.message)", "\(slot(id)?.displayName ?? "Account"): \(CollectorRetryPolicy.message)")
        onChange?()
        return true
    }
    private var nextPoll: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var busy = Set<String>()
    private var loginID: String?
    private var loginURL: URL?
    private var loginStarted: Date?
    private var loginGeneration = UUID()
    private var loginQueue: [String] = []
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var persistenceEnabled = true
    private var lockFD: Int32 = -1
    var onChange: (() -> Void)?

    init(preview: Bool = false) {
        self.preview = preview
        // CODEX_ACCOUNTS_DATA_DIR runs a clean first launch for testing; it never mixes with the real data directory.
        if !preview, let dir = ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_DATA_DIR"], dir.hasPrefix("/") {
            root = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccountsPublic" + (preview ? "-Preview" : ""))
        }
        saved = SavedState()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            lockFD = open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                let alert = NSAlert(); alert.messageText = L("Tibot 已经在运行", "Tibot is already running"); alert.informativeText = L("请从菜单栏打开现有窗口。", "Open it from the menu bar."); alert.runModal(); exit(0)
            }
            let stateURL = root.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                saved = try state.migrated()
            }
        } catch {
            persistenceEnabled = false
            banner = L("本机状态文件无法读取，已停止保存和连接以保护原数据。请检查数据目录后重新打开。", "Tibot could not read its state file, so saving and connecting are stopped to protect your data. Check the data folder and reopen Tibot.")
        }
        if shortcutChoice == "c" { shortcutChoice = "ctrl-semicolon"; UserDefaults.standard.set(shortcutChoice, forKey: "desktop.shortcut") }
        profiles = Self.readChromeProfiles()
        let reregister = UserDefaults.standard.bool(forKey: "login.reregister")
        if reregister {
            UserDefaults.standard.removeObject(forKey: "login.reregister")
            try? SMAppService.mainApp.register()
        }
        loginAtLaunch = SMAppService.mainApp.status == .enabled
        if reregister { saved.events.insert(ActivityEntry(loginAtLaunch ? L("改名为 Tibot 后，登录 Mac 时启动保持开启。", "After the rename to Tibot, Open at login stays on.") : L("改名为 Tibot 后，登录 Mac 时启动没能保留，请在设置里重新打开。", "After the rename to Tibot, Open at login could not be kept. Turn it on again in Settings.")), at: 0) }
        if !preview { collectorRetry = CollectorRetryPolicy(paused: Set(UserDefaults.standard.stringArray(forKey: collectorPauseKey) ?? [])) }
        for slot in saved.accounts {
            status[slot.id] = collectorRetry.paused.contains(slot.id) ? .failure(CollectorRetryPolicy.message) : .disconnected
        }
        if preview { loadPreview(); return }
        let lastVersion = UserDefaults.standard.string(forKey: "app.version")
        UserDefaults.standard.set(updater.current, forKey: "app.version")
        if let from = UserDefaults.standard.string(forKey: "update.from") {
            UserDefaults.standard.removeObject(forKey: "update.from")
            if from != updater.current { banner = L("已自动更新到 \(updater.current)。", "Updated to \(updater.current)."); record(L("已从 \(from) 自动更新到 \(updater.current)。", "Auto-updated from \(from) to \(updater.current).")) }
        } else if let lastVersion, lastVersion != updater.current {
            record(L("已从 \(lastVersion) 更新到 \(updater.current)。", "Updated from \(lastVersion) to \(updater.current)."))
        }
        if sharedDesktop.interruptedSwitch { banner = L("旧版本留下了一次未完成的桌面切换。新版不再改 Codex 登录；如账号不对，请在 Codex 里重新登录。", "An older version left a desktop switch unfinished. This version no longer changes the Codex login; if the account is wrong, sign in again in Codex.") }
        loadResetMonitor()
        loadPersonalX()
        checkResetAnnouncements()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.nextPoll.removeAll(); self?.refreshAll(); self?.checkResetAnnouncements(force: true)
        } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } })
        desktopSlotSeen = desktopSelection?.slotID
        if !waitForPrivateBuild { importFromPrivateBuild() }
        setupGateway()
        if CommandLine.arguments.contains("--setup-routing") { installerSetup = true }
        if !waitForPrivateBuild { continueInstallerSetup() }
        Task { await useFileStorage(); await refreshSequentially() }
    }
    private func setupGateway() {
        gateway.onEvent = { [weak self] event in
            guard let self else { return }
            self.routingActivity.receive(event)
            let kind = event.kind, id = event.account, code = event.status
            switch kind {
            case "ready":
                guard self.gatewayEnabled, self.gateway.running else { return }
                do {
                    try self.gateway.install(); self.gatewayReady = true
                    self.gatewayCaption = self.restingGatewayCaption
                } catch { self.gatewayReady = false; self.gatewayCaption = error.localizedDescription }
            case "routing":
                self.gatewayAccount = id
                self.gatewayCaption = L("正在使用 \(id.flatMap { self.slot($0)?.displayName } ?? "账号")", "Using \(id.flatMap { self.slot($0)?.displayName } ?? "an account")")
            case "completed": self.gatewayCaption = L("路由成功 · \(id.flatMap { self.slot($0)?.displayName } ?? "账号")", "Routed · \(id.flatMap { self.slot($0)?.displayName } ?? "account")")
            case "refused":
                self.gatewayCaption = L("账号暂不可用，正在尝试其他账号", "Account unavailable, trying another")
                if let id, code == 401 { self.refresh(id) }
            case "interrupted": self.gatewayCaption = L("回复中断，未重复执行；请在 Codex 中重试", "The reply was cut off and not repeated; retry in Codex")
            case "stopped": self.fallBackToDirect(L("网关已停止：\(event.reason ?? "进程已退出")", "Gateway stopped: \(event.reason ?? "the process exited")"))
            case "rejected": if let caption = self.rejectionCaption(event) { self.gatewayCaption = caption }
            case "local_auth_rejected": self.gatewayCaption = L("桌面认证不匹配；请确认当前登录账号已连接到 Tibot", "Desktop login mismatch; make sure the signed-in account is connected to Tibot")
            case "local_auth_unavailable": self.gatewayCaption = L("本机认证记录不可用；保留现场并检查私有文件权限", "Local login records are unavailable; nothing was changed. Check the private file permissions")
            default: break
            }
        }
        if gatewayEnabled || CommandLine.arguments.contains("--enable-gateway") { setGatewayEnabled(true) }
        else if gateway.configuration.installed { fallBackToDirect(L("自动路由未开启", "Auto routing is off")) }
    }
    /// Never leave Codex pointed at a port nobody serves. Codex reloads config.toml for new and
    /// resumed conversations, so restoring the direct provider recovers them; the toggle stays as chosen.
    private func fallBackToDirect(_ reason: String) {
        let wasInstalled = gateway.configuration.installed
        // Restore first: if the provider table was edited elsewhere, a helper that still runs keeps serving.
        do { try gateway.configuration.restore() } catch {
            gatewayCaption = L("\(reason) · \(error.localizedDescription) 请在 ~/.codex/config.toml 删除 openai_base_url 一行后重启 Codex。", "\(reason) · \(error.localizedDescription) Delete the openai_base_url line in ~/.codex/config.toml, then restart Codex.")
            if gateway.running { return }
            gatewayReady = false; gatewayAccount = nil; routingActivity.receive(.init(kind: "stopped"))
            return
        }
        try? gateway.stop(restore: false)
        gatewayReady = false; gatewayAccount = nil; routingActivity.receive(.init(kind: "stopped"))
        gatewayCaption = wasInstalled ? L("\(reason) · 已恢复直连，Codex 改用它自己登录的账号", "\(reason) · Back to direct: Codex uses its own signed-in account") : reason
    }
    /// Only reasons a Codex conversation can cause; local probes (for example a web page) never change the caption.
    private func rejectionCaption(_ event: GatewayActivityEvent) -> String? {
        let name = event.account.flatMap { slot($0)?.displayName } ?? L("原账号", "the original account")
        switch event.reason {
        case "sealed_owner_unavailable": return L("会话接着 \(name) 服务器上保存的回复，只能用它；它暂不可用，请等额度恢复或新开会话", "This chat continues a reply stored on \(name)'s server, so only that account can serve it. It is unavailable now; wait for its quota or start a new chat")
        case "sealed_owner_unknown": return L("会话接着服务器上保存的回复，原账号未知，网关未换号转发；请新开会话", "This chat continues a reply stored on the server and its account is unknown, so the gateway did not switch; start a new chat")
        case "no_available_account", "all_accounts_declined": return L("没有可用账号；刷新账号或等待额度重置", "No account available; refresh accounts or wait for a reset")
        case "unsupported_route": return L("Codex 调用了网关尚未支持的接口，已记录到诊断日志", "Codex called an endpoint the gateway does not support yet; logged for diagnostics")
        default: return nil
        }
    }
    private func updateGatewayPool() throws {
        guard usesFileCredentials else { throw GatewayConfigurationError.credentials }
        let desktopURL = sharedDesktop.home.appendingPathComponent("auth.json")
        let desktopData = desktopURL.standardizedFileURL == desktopURL.resolvingSymlinksInPath() ? try? Data(contentsOf: desktopURL) : nil
        let identities = saved.accounts.compactMap { slot in slot.expectedAccountID.map { GatewayClientIdentity(id: slot.id, accountID: $0) } }
        guard let desktopData, let desktop = try? DesktopCredential(desktopData),
              identities.contains(where: { $0.accountID == desktop.accountID }),
              let desktopValue = try? GatewayAccount(id: "desktop", credential: desktop, available: true, reset: 0),
              desktopValue.expires > Date().timeIntervalSince1970 else { throw GatewayConfigurationError.desktopIdentity }
        var accounts: [GatewayAccount] = []
        for slot in saved.accounts {
            guard let expected = slot.expectedAccountID else { continue }
            if collectorRetry.paused.contains(slot.id) { continue }
            if case .wrongAccount = status[slot.id] { continue }
            let auth = root.appendingPathComponent("accounts/\(slot.id)/auth.json")
            guard auth.standardizedFileURL == auth.resolvingSymlinksInPath(),
                  let credential = try? GatewayCredentialSource.select(expected: expected, desktop: desktopData, stored: { try Data(contentsOf: auth) }) else { continue }
            let windows = slot.snapshot?.rates.windows ?? []
            let spent = windows.contains { ($0.remaining ?? 100) <= 0 && ($0.resetDate ?? .distantFuture) > now }
            if let value = try? GatewayAccount(id: slot.id, credential: credential, available: !spent, reset: windows.quotaReset ?? 0) { accounts.append(value) }
        }
        try gateway.save(accounts: accounts, preferred: gatewayPreferred, clients: identities)
    }
    func setGatewayEnabled(_ enabled: Bool) {
        guard !preview, persistenceEnabled else { return }
        do {
            if enabled {
                do {
                    guard loginSlotID == nil, launchingDesktop.isEmpty else { throw GatewayConfigurationError.unavailable }
                    try updateGatewayPool(); try gateway.start()
                } catch {
                    // A gateway that already serves keeps serving; otherwise do not leave Codex on a dead port.
                    if !gatewayReady { fallBackToDirect(error.localizedDescription) }
                    throw error
                }
                gatewayCaption = L("正在启动本机网关…", "Starting the local gateway…")
            } else {
                try gateway.stop(restore: true); routingActivity.receive(.init(kind: "stopped")); gatewayReady = false; gatewayAccount = nil
                gatewayCaption = L("已恢复原配置 · 重启 Codex 生效", "Original config restored · restart Codex to apply")
            }
            gatewayEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "gateway.enabled")
        } catch {
            banner = error.localizedDescription
            if !enabled { gatewayCaption = error.localizedDescription }
        }
    }
    var routingSetup: RoutingSetup {
        let desktop = sharedDesktop.desktopLogin()
        return RoutingSetup.next(fileStorage: usesFileCredentials, desktopAccountID: desktop.accountID,
                                 desktopEnrolled: desktopSelection != nil, desktopEmail: desktop.email)
    }
    var desktopAccountID: String? { sharedDesktop.desktopAccountID() }
    /// nil until routing is first switched on or off, by the user or by the app.
    var routingChoice: Bool? { UserDefaults.standard.object(forKey: "gateway.enabled") as? Bool }
    private var autoRoutingTried = false
    /// Once the setup is done, routing switches itself on (once per launch, so a failure is not retried every tick).
    private func enableRoutingWhenReady() {
        guard !preview, !autoRoutingTried, RoutingSetup.shouldEnable(routingSetup, enabled: gatewayEnabled, userChoice: routingChoice) else { return }
        autoRoutingTried = true
        setGatewayEnabled(true)
        if gatewayEnabled { banner = L("已自动开启自动路由。已打开的 Codex 会话重启 Codex 后也会经过路由。", "Auto routing is on. Chats already open in Codex go through it after you restart Codex.") }
    }
    /// The desktop's own login becomes an account: no browser sign-in, and no copy of its token.
    func connectDesktopAccount() {
        guard canConnect, loginSlotID == nil, launchingDesktop.isEmpty, case .desktopAccount = routingSetup,
              let accountID = sharedDesktop.desktopAccountID() else { return }
        let id = "account-" + UUID().uuidString.lowercased()
        var slot = AccountSlot(id: id, name: L("新账号", "New account"), chromeProfile: "dedicated")
        slot.expectedAccountID = accountID
        saved.accounts.append(slot); status[id] = .disconnected; persist(); onChange?(); onDesktopChange?()
        refresh(id)
    }
    func selectGatewayAccount(_ id: String) {
        gatewayPreferred = id; UserDefaults.standard.set(id, forKey: "gateway.preferred")
        do { try updateGatewayPool() } catch { banner = error.localizedDescription }
    }
    var healthy: Set<String> { Set(status.filter { $0.value == .connected }.map(\.key)) }
    var connectedCount: Int { healthy.count }
    var isBusy: Bool { !busy.isEmpty }
    var recommendation: String { Presentation.recommendation(saved.accounts, healthy: healthy, now: now) ?? L("连接账号后，这里会优先提示即将重置且仍有余量的账号。", "Once accounts are connected, this shows the account that resets soonest and still has quota.") }
    var canConnect: Bool { persistenceEnabled && !preview }
    var loginName: String { saved.accounts.first { $0.id == loginSlotID }?.displayName ?? L("账号", "Account") }
    var menuTitle: String {
        let active = saved.accounts.filter { healthy.contains($0.id) && $0.snapshot?.isFresh(at: now) == true }
        guard let best = active.min(by: { ($0.snapshot?.rates.windows.compactMap(\.resetDate).min() ?? .distantFuture) < ($1.snapshot?.rates.windows.compactMap(\.resetDate).min() ?? .distantFuture) }),
              let remaining = best.snapshot?.rates.windows.compactMap(\.remaining).min() else { return "Codex \(connectedCount)/\(saved.accounts.count)" }
        return "\(best.displayName) \(Int(remaining))%"
    }
    func slot(_ id: String) -> AccountSlot? { saved.accounts.first { $0.id == id } }
    /// The account Codex is on now: the one routing last used while it still has quota, else the one routing
    /// would pick next. Without routing it is the account the desktop is signed in to.
    var currentAccountID: String? {
        guard gatewayEnabled else {
            return desktopAccountID.flatMap { id in saved.accounts.first { $0.expectedAccountID == id }?.id }
        }
        func usable(_ slot: AccountSlot) -> Bool { (slot.snapshot?.rates.windows.compactMap(\.remaining).min() ?? 0) > 0 }
        if let id = gatewayAccount ?? routingActivity.lastAccount, let slot = self.slot(id), usable(slot) { return id }
        if let slot = self.slot(gatewayPreferred), usable(slot) { return slot.id }
        // Automatic routing: the account whose quota resets first, like the gateway picks.
        let reset = { (slot: AccountSlot) in slot.snapshot?.rates.windows.quotaReset ?? .infinity }
        return saved.accounts.filter(usable).min { reset($0) < reset($1) }?.id
    }
    var mascotAccounts: [Mascot.Account] {
        saved.accounts.map { Mascot.Account(id: $0.id, name: $0.displayName, windows: $0.snapshot?.rates.windows ?? []) }
    }
    /// What the mascot says at the top of the panel.
    func mascotLine(switched: Mascot.Switch?) -> Mascot.Line {
        var input = Mascot.Input(accounts: mascotAccounts)
        input.routing = gatewayEnabled; input.gatewayReady = gatewayReady; input.current = currentAccountID
        input.cacheHit = routingActivity.lastCache?.hit; input.switched = switched; input.resetAlert = resetAlert?.text; input.now = now
        return Mascot.line(input)
    }
    private func index(_ id: String) -> Int? { saved.accounts.firstIndex { $0.id == id } }
    private static func binary() throws -> URL {
        let paths = [
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ClientFailure.missingBinary }
        return URL(fileURLWithPath: path)
    }
    /// Live desktop owner; selection.json alone goes stale after a login inside Codex.
    private var desktopSelection: DesktopSelection? { sharedDesktop.selection(accounts: saved.accounts) }
    private var desktopSlotSeen: String?
    private var unenrolledDesktopTicks = 0
    /// A collector created before a login inside Codex still points at its old home.
    private func retireCollectorsIfDesktopChanged() {
        let current = desktopSelection?.slotID
        guard current != desktopSlotSeen else { return }
        let affected = [desktopSlotSeen, current].compactMap { $0 }
        guard affected.allSatisfy({ !busy.contains($0) && !usageLoading.contains($0) && loginSlotID != $0 }) else { return }
        for id in affected { clients[id]?.stop(); clients.removeValue(forKey: id) }
        desktopSlotSeen = current
    }
    /// The user name Codex shows, from the account's own login: the desktop's for the desktop account,
    /// the stored file otherwise (keychain storage has no file, so the card keeps the email).
    private func codexName(_ id: String) -> String? {
        let url = desktopSelection?.slotID == id ? sharedDesktop.home.appendingPathComponent("auth.json")
                                                 : root.appendingPathComponent("accounts/\(id)/auth.json")
        guard url.standardizedFileURL == url.resolvingSymlinksInPath(), let data = try? Data(contentsOf: url),
              let credential = try? DesktopCredential(data, expected: slot(id)?.expectedAccountID),
              let name = credential.name, !name.isEmpty else { return nil }
        return name
    }
    private func verifySharedIdentity(_ id: String) throws {
        guard desktopSelection?.slotID == id else { return }
        guard let expected = slot(id)?.expectedAccountID,
              desktopSelection?.accountID == expected else { throw ClientFailure.authentication }
        _ = try DesktopCredential(Data(contentsOf: sharedDesktop.home.appendingPathComponent("auth.json")), expected: expected)
    }
    private func client(_ id: String) throws -> RPCClient {
        try verifySharedIdentity(id)
        let shared = desktopSelection?.slotID == id
        let home = shared ? sharedDesktop.home : root.appendingPathComponent("accounts/\(id)")
        // A login inside Codex can move the desktop between ticks: never reuse a client aimed at the
        // other home (a logout sent to the shared home would sign the desktop out).
        if let client = clients[id] {
            if client.home.standardizedFileURL == home.standardizedFileURL { return client }
            client.stop(); clients.removeValue(forKey: id)
        }
        let client: RPCClient
        if shared {
            let plan = try SharedDesktopPlan(home: sharedDesktop.home)
            let config = sharedDesktop.home.appendingPathComponent("config.toml")
            try plan.validateConfiguration(FileManager.default.fileExists(atPath: config.path) ? try String(contentsOf: config, encoding: .utf8) : "")
            client = RPCClient(home: sharedDesktop.home, executable: try Self.binary(), prepareHome: false, credentialStore: "file")
        } else {
            client = RPCClient(home: home, executable: try Self.binary(), credentialStore: usesFileCredentials ? "file" : "keyring")
        }
        client.onNotification = { [weak self] method, params in self?.handleNotification(id, method, params) }
        clients[id] = client
        return client
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    func refreshAll() { Task { await refreshSequentially(force: true) }; refreshUsage() }
    func refreshUsage(force: Bool = false) {
        for account in saved.accounts where status[account.id] == .connected {
            Task { await syncUsage(account.id, force: force) }
        }
    }
    private func syncUsage(_ id: String, force: Bool = false) async {
        guard launchingDesktop.isEmpty, !preview, persistenceEnabled, index(id) != nil, loginSlotID != id, !usageLoading.contains(id), !collectorRetry.paused.contains(id) else { return }
        if !force, let next = nextUsagePoll[id], next > Date() { return }
        usageLoading.insert(id); defer { usageLoading.remove(id) }
        nextUsagePoll[id] = Date().addingTimeInterval(300)
        do {
            let response = try decode(TokenUsageResponse.self, await client(id).request("account/usage/read"))
            try verifySharedIdentity(id)
            guard let i = index(id), loginSlotID != id, !collectorRetry.paused.contains(id) else { return }
            saved.accounts[i].tokenUsage = TokenUsageSnapshot(response: response)
            usageErrors.removeValue(forKey: id); persist()
        } catch {
            guard index(id) != nil else { return }
            if pauseCollectorIfNeeded(error, id: id) { return }
            usageErrors[id] = safeError(error)
        }
    }
    func tokenDays(count: Int, accountID: String? = nil) -> [TokenDay] {
        let accounts = saved.accounts.filter { accountID == nil || $0.id == accountID }
        let dates: [String]
        if count > 0 { dates = TokenActivity.recentDates(count: count, now: now) }
        else { dates = Set(accounts.flatMap { $0.tokenUsage?.response.dailyUsageBuckets?.map(\.startDate) ?? [] }).sorted() }
        return TokenActivity.aggregate(accounts.map { $0.tokenUsage?.response }, dates: dates)
    }
    func tokenWeeks() -> [[TokenDay]] { TokenActivity.weeks(saved.accounts.map { $0.tokenUsage?.response }, now: now) }
    func usageCaption(accountID: String? = nil) -> String {
        let accounts = saved.accounts.filter { accountID == nil || $0.id == accountID }
        let available = accounts.filter { $0.tokenUsage?.response.dailyUsageBuckets != nil }.count
        if accounts.contains(where: { usageLoading.contains($0.id) }) { return L("统计更新中", "Updating stats") }
        if accounts.contains(where: { usageErrors[$0.id] != nil }) { return L("部分更新失败 · 保留旧统计", "Some updates failed · old stats kept") }
        if available == 0 { return L("暂无每日统计", "No daily stats yet") }
        let stale = accounts.contains { Date().timeIntervalSince($0.tokenUsage?.fetchedAt ?? .distantPast) > 600 }
        if stale { return L("缓存统计 · 待更新", "Cached stats · update pending") }
        return available == accounts.count ? L("\(available) 个账号 · 服务端统计", "\(available) account\(available == 1 ? "" : "s") · server stats") : L("\(available)/\(accounts.count) 个账号已返回", "\(available)/\(accounts.count) accounts reported")
    }
    func refresh(_ id: String) {
        guard launchingDesktop.isEmpty, loginSlotID != id, !busy.contains(id), !usageLoading.contains(id) else { return }
        resumeCollector(id)
        Task { await sync(id, force: true) }
    }
    private func refreshSequentially(force: Bool = false) async {
        for slot in saved.accounts { await sync(slot.id, force: force) }
    }
    private func sync(_ id: String, force: Bool = false) async {
        guard launchingDesktop.isEmpty, persistenceEnabled, !preview, !busy.contains(id), loginSlotID != id, index(id) != nil else { return }
        guard !collectorRetry.paused.contains(id) else { return }
        if case .wrongAccount = status[id] { return }
        if !force, let next = nextPoll[id], next > Date() { return }
        let syncStartedAt = Date()
        busy.insert(id); status[id] = .checking; onChange?()
        defer { busy.remove(id); onChange?() }
        do {
            let client = try client(id)
            let identityResult = try decode(AccountRead.self, await client.request("account/read", params: ["refreshToken": false]))
            // Finish the current request, but do not begin another network call during a switch.
            guard launchingDesktop.isEmpty else {
                status[id] = slot(id)?.snapshot == nil ? .disconnected : .connected
                return
            }
            guard let i = index(id), !collectorRetry.paused.contains(id) else { return }
            guard let identity = identityResult.account, identity.type == "chatgpt" else {
                status[id] = saved.accounts[i].expectedEmail == nil ? .disconnected : .needsAuth
                nextPoll[id] = .distantFuture
                client.stop(); return
            }
            let rates = try decode(RateResponse.self, await client.request("account/rateLimits/read"))
            guard let i = index(id), !collectorRetry.paused.contains(id) else { return }
            let check = IdentityCheck.evaluate(slot: saved.accounts[i], identity: identity, accountID: rates.accountId, others: saved.accounts)
            switch check {
            case .valid: break
            case .changed:
                status[id] = .wrongAccount(L("本次登录与原账号不一致。请在绑定的 Chrome 窗口选回原账号，再重新连接；要换账号请先移除本机连接。", "This sign-in is a different account. Pick the original account in the linked Chrome window and reconnect; to use another account, remove this one first."))
                loginQueue.removeAll(); return
            case .duplicate(let name):
                status[id] = .wrongAccount(L("已连接到“\(name)”，请选择另一个账号。", "Already connected as “\(name)”. Choose another account."))
                loginQueue.removeAll(); return
            case .unverifiable:
                status[id] = .wrongAccount(L("服务未提供可核对的账号身份，暂不计入已连接账号。请稍后重新连接。", "The service gave no account identity to check, so it is not counted as connected. Reconnect later."))
                loginQueue.removeAll(); return
            }
            let old = saved.accounts[i].snapshot
            let snapshot = Snapshot(identity: identity, rates: rates)
            saved.accounts[i].snapshot = snapshot
            saved.accounts[i].expectedEmail = identity.email
            saved.accounts[i].expectedAccountID = rates.accountId ?? saved.accounts[i].expectedAccountID
            if let name = codexName(id) { saved.accounts[i].codexName = String(name.prefix(128)) }
            status[id] = .connected; failures[id] = 0
            Task { await syncUsage(id) }
            nextPoll[id] = Date().addingTimeInterval(60)
            if old == nil { record(L("\(saved.accounts[i].displayName) 已连接，登录状态已保存。", "\(saved.accounts[i].displayName) connected; the login is saved.")) }
            evaluateReminders(id: id, previous: old, current: snapshot)
            resetMonitor.acknowledge(id, syncStartedAt: syncStartedAt)
            saveResetMonitor()
            persist()
        } catch {
            if pauseCollectorIfNeeded(error, id: id) { return }
            let isAuth: Bool = { if case ClientFailure.authentication = error { return true }; return false }()
            status[id] = isAuth ? .needsAuth : .failure(safeError(error))
            let count = min((failures[id] ?? 0) + 1, 4); failures[id] = count
            nextPoll[id] = Date().addingTimeInterval(min(1800, 60 * pow(2, Double(count - 1))) + Double.random(in: 0...25))
        }
    }
    private func tick() {
        now = Date(); onChange?()
        retireCollectorsIfDesktopChanged()
        // Never rewrite the token snapshot while the gateway is stopped.
        if gatewayEnabled && gateway.running {
            // A login inside Codex to an account the manager does not know can only get 401s from the
            // gateway. Seen three ticks in a row (not one half-written auth.json), go direct instead.
            unenrolledDesktopTicks = sharedDesktop.desktopAccountID() != nil && desktopSelection == nil ? unenrolledDesktopTicks + 1 : 0
            if unenrolledDesktopTicks >= 3 {
                unenrolledDesktopTicks = 0
                fallBackToDirect(L("Codex 当前登录的账号未连接到 Tibot", "The account Codex is signed in to is not connected to Tibot"))
            } else { do { try updateGatewayPool() } catch { gatewayCaption = error.localizedDescription } }
        }
        if !waitForPrivateBuild {
            importFromPrivateBuild()
            continueInstallerSetup()
            enableRoutingWhenReady()
        }
        checkResetAnnouncements()
        retryResetRefresh()
        keepUpToDate()
        if let started = loginStarted, now.timeIntervalSince(started) > 600 {
            Task { await cancelLogin(); banner = L("本次登录等待已超时。已有连接未受影响，可重新连接。", "Waiting for the sign-in timed out. Existing connections are fine; you can reconnect.") }
        }
        for slot in saved.accounts {
            if let reset = slot.snapshot?.rates.windows.compactMap(\.resetDate).min(), reset <= now,
               slot.snapshot?.fetchedAt ?? .distantPast < reset, status[slot.id] == .connected {
                nextPoll[slot.id] = .distantPast
            }
        }
        Task { await refreshSequentially() }
    }
    func connectAll() {
        guard loginSlotID == nil, canConnect else { return }
        loginQueue = saved.accounts.filter { status[$0.id] != .connected }.map(\.id)
        connectNext()
    }
    private func connectNext() {
        guard !loginQueue.isEmpty, loginSlotID == nil else { return }
        let id = loginQueue.removeFirst(); Task { await beginLogin(id) }
    }
    func connect(_ id: String) { loginQueue.removeAll(); Task { await beginLogin(id) } }
    func canOpenConnection(_ id: String) -> Bool {
        guard launchingDesktop.isEmpty, canConnect, index(id) != nil else { return false }
        if loginSlotID == id { return loginURL != nil }
        return loginSlotID == nil && !busy.contains(id)
    }
    func connectionLabel(_ id: String) -> String {
        if loginSlotID == id { return loginURL == nil ? L("准备授权…", "Preparing sign-in…") : L("继续授权 →", "Continue sign-in →") }
        if loginSlotID != nil { return L("请先完成其他账号授权", "Finish the other sign-in first") }
        return busy.contains(id) ? L("正在同步…", "Syncing…") : L("连接账号 →", "Connect account →")
    }
    func connectOrContinue(_ id: String) {
        guard canOpenConnection(id) else { return }
        if loginSlotID == id { reopenLogin() } else { connect(id) }
    }
    private func beginLogin(_ id: String) async {
        guard launchingDesktop.isEmpty, desktopSelection?.slotID != id, accountDesktop.running(root: root, id: id) == nil else {
            banner = L("此账号正在用于桌面端。请先在 Codex 里登录其他账号并退出旧独立窗口，再重新授权。", "This account is in use by the desktop app. Sign in to another account in Codex and quit the old separate window, then sign in again."); return
        }
        guard loginSlotID == nil, canConnect, !busy.contains(id), !usageLoading.contains(id), index(id) != nil else { return }
        resumeCollector(id)
        loginSlotID = id; loginStarted = Date(); status[id] = .waiting
        let generation = UUID(); loginGeneration = generation
        do {
            let result = try await client(id).request("account/login/start", params: ["type": "chatgpt"], timeout: 35)
            guard loginGeneration == generation, loginSlotID == id else { return }
            guard let login = result["loginId"] as? String, let raw = result["authUrl"] as? String,
                  let url = URL(string: raw), url.scheme == "https", let host = url.host,
                  ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host) else { throw ClientFailure.invalidResponse }
            loginID = login; loginURL = url
            try openChrome(for: id, url: url)
            record(L("已为 \(slot(id)?.displayName ?? "账号") 打开绑定的 Chrome 窗口，等待授权。", "Opened the linked Chrome window for \(slot(id)?.displayName ?? "the account"); waiting for sign-in."))
        } catch {
            guard loginGeneration == generation else { return }
            // Stop the isolated process to close any callback whose ID was not returned.
            clients[id]?.stop(); clearLogin()
            status[id] = .failure(safeError(error)); loginQueue.removeAll()
            _ = pauseCollectorIfNeeded(error, id: id)
        }
    }
    func reopenLogin() {
        guard let id = loginSlotID, let url = loginURL else { return }
        do { try openChrome(for: id, url: url) } catch { banner = safeError(error) }
    }
    func cancelLogin() async {
        guard let id = loginSlotID else { return }
        let remoteID = loginID
        loginGeneration = UUID(); loginQueue.removeAll()
        loginID = nil; loginURL = nil; loginStarted = nil
        if let remoteID { _ = try? await clients[id]?.request("account/login/cancel", params: ["loginId": remoteID], timeout: 5) }
        clients[id]?.stop(); clearLogin()
        status[id] = slot(id)?.snapshot == nil ? .disconnected : .needsAuth
        record(L("已取消 \(slot(id)?.displayName ?? "账号") 的本次连接。浏览器窗口保留。", "Cancelled connecting \(slot(id)?.displayName ?? "the account"). The browser window stays open."))
    }
    private func clearLogin() { loginSlotID = nil; loginID = nil; loginURL = nil; loginStarted = nil }
    private func handleNotification(_ id: String, _ method: String, _ params: [String: Any]) {
        if method == "account/login/completed", loginSlotID == id, let current = loginID, params["loginId"] as? String == current {
            let success = params["success"] as? Bool == true
            clearLogin()
            if success {
                status[id] = .disconnected
                Task { await sync(id, force: true)
                    if status[id] == .connected { connectNext() } else { loginQueue.removeAll() }
                }
            } else {
                // Some Codex builds cannot write the Keychain when started by another app; the browser sign-in still succeeded.
                let reason = (params["error"] as? String ?? "").lowercased()
                let keyring = !usesFileCredentials && ["keyring", "secure storage", "keychain"].contains { reason.contains($0) }
                status[id] = .failure(keyring ? L("登录已完成，但系统钥匙串无法保存。请先在自动路由设置里点「重试」把登录改存本机文件，再重新连接。", "Signed in, but the Keychain could not save it. In the auto routing settings click “Retry” to store logins in local files, then reconnect.")
                                              : L("登录未完成，请重新连接。已有账号不会退出。", "Sign-in did not finish; reconnect. Other accounts stay signed in."))
                loginQueue.removeAll()
            }
        } else if method == "account/rateLimits/updated", !busy.contains(id), loginSlotID != id,
                  let fetched = slot(id)?.snapshot?.fetchedAt, Date().timeIntervalSince(fetched) > 30 {
            // Re-read the complete response: notifications can omit banked reset and other buckets.
            Task { await sync(id, force: true) }
        }
    }
    func rename(_ id: String, name: String, profile: String) {
        guard canConnect, loginSlotID != id, let i = index(id) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.accounts[i].name = clean.isEmpty ? L("账号 \(i + 1)", "Account \(i + 1)") : String(clean.prefix(32))
        saved.accounts[i].nameOverride = clean.isEmpty ? nil : String(clean.prefix(128))
        saved.accounts[i].chromeProfile = profile
        persist(); onChange?()
    }
    func addAccount(profile: String, alias: String) {
        guard launchingDesktop.isEmpty, canConnect, loginSlotID == nil, profiles.contains(where: { $0.id == profile }) else { return }
        let id = "account-" + UUID().uuidString.lowercased()
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var slot = AccountSlot(id: id, name: L("新账号", "New account"), chromeProfile: profile)
        slot.nameOverride = clean.isEmpty ? nil : String(clean.prefix(128))
        saved.accounts.append(slot); status[id] = .disconnected; persist(); onChange?(); onDesktopChange?()
        connect(id)
    }
    func disconnect(_ id: String) async {
        guard launchingDesktop.isEmpty, desktopSelection?.slotID != id, accountDesktop.running(root: root, id: id) == nil else {
            banner = L("此账号正在用于桌面端。请先在 Codex 里登录其他账号并退出旧独立窗口，再移除连接。", "This account is in use by the desktop app. Sign in to another account in Codex and quit the old separate window, then remove it."); return
        }
        guard canConnect, index(id) != nil, !busy.contains(id), !usageLoading.contains(id), loginSlotID == nil else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            _ = try await client(id).request("account/logout", timeout: 15)
            clients[id]?.stop(); clients.removeValue(forKey: id)
            usageErrors.removeValue(forKey: id); nextUsagePoll.removeValue(forKey: id)
            guard let i = index(id) else { return }
            let slot = saved.accounts[i]
            saved.accounts.remove(at: i)
            resumeCollector(id)
            status.removeValue(forKey: id); nextPoll.removeValue(forKey: id); failures.removeValue(forKey: id)
            record(L("\(slot.displayName) 已从看板移除，Chrome 登录未改变。", "Removed \(slot.displayName). The Chrome login is unchanged."))
            onDesktopChange?()
            persist(); onChange?()
        } catch { banner = L("连接未能移除，原记录保留。\(safeError(error))", "Could not remove the account; nothing was changed. \(safeError(error))") }
    }
    func openAccountPage(_ id: String) {
        do { try openChrome(for: id, url: URL(string: "https://chatgpt.com/codex/settings/usage")!) }
        catch { banner = safeError(error) }
    }
    private var canMigrateCredentials: Bool {
        !usesFileCredentials && !migratingCredentials && launchingDesktop.isEmpty && loginSlotID == nil && canConnect
    }
    /// Logins live in files only, like Codex's own ~/.codex/auth.json. A fresh install starts there; logins an older
    /// version kept in the Keychain move over once (macOS may ask once per item, never again afterwards).
    func retryFileStorage() { Task { await useFileStorage() } }
    private func useFileStorage() async {
        guard !preview, persistenceEnabled, !usesFileCredentials else { return }
        if saved.accounts.isEmpty { try? sharedDesktop.fileStore.activate([]); return }
        await migrateCredentialsToFiles()
    }
    @discardableResult private func migrateCredentialsToFiles() async -> Bool {
        guard canMigrateCredentials else { return usesFileCredentials }
        migratingCredentials = true; launchingDesktop.insert("credential-migration")
        defer {
            migratingCredentials = false; launchingDesktop.remove("credential-migration")
            nextPoll.removeAll(); nextUsagePoll.removeAll(); onChange?()
        }
        do {
            for _ in 0..<650 {
                if busy.isEmpty && usageLoading.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard busy.isEmpty, usageLoading.isEmpty else { throw DesktopSwitchFailure.collectorsBusy }
            for client in clients.values {
                guard await client.stopAndWait() else { throw DesktopSwitchFailure.collectorStop }
            }
            clients.removeAll()
            let unreadable = try sharedDesktop.migrateToFiles(accounts: saved.accounts, legacy: accountDesktop)
            for slot in saved.accounts { resumeCollector(slot.id) }
            for id in unreadable { status[id] = .needsAuth }
            storageMoveFailed = false
            record(L("登录已改存本机文件，以后不再访问钥匙串。", "Logins are now stored in local files; the Keychain is no longer used."))
            if !unreadable.isEmpty { banner = L("有 \(unreadable.count) 个账号的旧登录没能从钥匙串读出，请重新连接这几个账号。", "Could not read the old login of \(unreadable.count) account\(unreadable.count == 1 ? "" : "s") from the Keychain. Reconnect \(unreadable.count == 1 ? "it" : "them").") }
            return true
        } catch {
            storageMoveFailed = true
            banner = L("登录没能改存本机文件：", "Could not move logins to local files: ") + ((error as? DesktopSwitchFailure)?.localizedDescription ?? L("请检查数据目录权限。", "check the data folder permissions.")) + L("可在自动路由设置里点「重试」。", " Click “Retry” in the auto routing settings.")
            return false
        }
    }
    let updater = AppUpdater()
    @Published var updateCaption = ""
    var autoUpdate: Bool { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
    /// Settings → Language: follow the Mac, or always Chinese or English. Read once at launch, before any wording.
    static func loadLanguage() { L10n.choice = UILanguage(rawValue: UserDefaults.standard.string(forKey: "ui.language") ?? "") ?? .system }
    var language: UILanguage { L10n.choice }
    var onLanguageChange: (() -> Void)?
    func setLanguage(_ choice: UILanguage) {
        guard choice != L10n.choice else { return }
        UserDefaults.standard.set(choice.rawValue, forKey: "ui.language"); L10n.choice = choice
        // Lines already worded keep their language until they next change; restate the ones that would linger.
        // Account statuses are reworded by the next sync, within a minute.
        profiles = Self.readChromeProfiles(); banner = nil
        gatewayCaption = restingGatewayCaption
        updateCaption = pendingUpdate.map { L("发现 \($0)，空闲时自动更新", "\($0) available; updates when idle") } ?? ""
        objectWillChange.send(); onLanguageChange?(); onChange?()
    }
    private var restingGatewayCaption: String {
        guard gatewayEnabled else { return L("自动路由未开启", "Auto routing is off") }
        return gatewayReady ? L("网关就绪 · 支持新旧会话，升级后重启 Codex", "Gateway ready · new and existing chats; restart Codex after upgrading")
            : L("正在启动本机网关…", "Starting the local gateway…")
    }
    func setAutoUpdate(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "update.auto")
        if on { nextUpdateCheck = .distantPast } else { pendingUpdate = nil; updateCaption = "" }
        onChange?()
    }
    private var nextUpdateCheck = Date().addingTimeInterval(
        Double(ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_UPDATE_AFTER"] ?? "") ?? 120)
    private var pendingUpdate: String?
    private var updating = false
    /// Never in the middle of a Codex request, a sign-in or a storage migration.
    private var idleForUpdate: Bool { routingActivity.active.isEmpty && loginSlotID == nil && !migratingCredentials && launchingDesktop.isEmpty }
    /// Checks every six hours; a newer release is installed at the next idle moment.
    private func keepUpToDate() {
        guard !preview, persistenceEnabled, autoUpdate, !updating else { return }
        if let tag = pendingUpdate { installWhenIdle(tag); return }
        guard Date() >= nextUpdateCheck else { return }
        nextUpdateCheck = Date().addingTimeInterval(6 * 3600)
        Task {
            do {
                if let tag = try await updater.newerRelease() {
                    pendingUpdate = tag; updateCaption = L("发现 \(tag)，空闲时自动更新", "\(tag) available; updates when idle")
                    installWhenIdle(tag)
                } else { updateCaption = L("已是最新 · \(updater.current)", "Up to date · \(updater.current)") }
            } catch { updateCaption = L("检查更新失败，稍后再试", "Could not check for updates; will try later") }
        }
    }
    private func installWhenIdle(_ tag: String) {
        guard idleForUpdate, !updating else { return }
        updating = true; updateCaption = L("正在更新到 \(tag)…", "Updating to \(tag)…")
        Task {
            do {
                let app = try await updater.prepare(tag)
                // A request may have started while downloading: wait for the next idle moment.
                guard idleForUpdate else { updating = false; return }
                try await updater.install(app)
                UserDefaults.standard.set(updater.current, forKey: "update.from")
                record(L("自动更新到 \(tag)，正在重启 Tibot。", "Auto-updating to \(tag); restarting Tibot."))
                NSApp.terminate(nil)
            } catch {
                updating = false; pendingUpdate = nil; nextUpdateCheck = Date().addingTimeInterval(3600)
                updateCaption = L("自动更新没完成：\(error.localizedDescription)，一小时后再试", "Auto update did not finish: \(error.localizedDescription). Trying again in an hour")
                record(updateCaption)
            }
        }
    }
    /// The private build's data folder (CODEX_ACCOUNTS_IMPORT_FROM points elsewhere for testing).
    private var privateRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_IMPORT_FROM"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(PrivateBuildImport.folderName)")
    }
    /// The private build holds this lock while it runs.
    private var privateBuildRunning: Bool {
        let fd = open(privateRoot.appendingPathComponent("app.lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN); return false
    }
    private var privateImportHinted = false
    private var privateImportFailed = false
    /// While the private build runs, setup waits: it would fight over Codex's configuration, and two
    /// programs refreshing one login sign each other out.
    private var waitForPrivateBuild: Bool {
        guard FileManager.default.fileExists(atPath: privateRoot.appendingPathComponent("state.json").path), privateBuildRunning else { return false }
        if !privateImportHinted {
            privateImportHinted = true
            banner = L("检测到私人版正在运行。退出私人版后，会自动导入它的账号和登录、开启路由，不用重新授权。", "The private build is running. Quit it and Tibot imports its accounts and logins and turns on routing, no new sign-in needed.")
        }
        return true
    }
    /// Once, the private build's accounts and logins come over (any not here yet), so nobody signs in again.
    private func importFromPrivateBuild() {
        guard !preview, persistenceEnabled, loginSlotID == nil, !privateImportFailed,
              !UserDefaults.standard.bool(forKey: "import.privateBuild"),
              FileManager.default.fileExists(atPath: privateRoot.appendingPathComponent("state.json").path) else { return }
        do {
            let desktop = (try? Data(contentsOf: sharedDesktop.home.appendingPathComponent("auth.json"))).flatMap { try? DesktopCredential($0) }
            guard let plan = try PrivateBuildImport.plan(privateRoot: privateRoot, desktop: desktop,
                                                          keychain: { [sharedDesktop] home in sharedDesktop.keychainLogin(home: home) }) else { return }
            let known = Set(saved.accounts.compactMap(\.expectedAccountID)), ids = Set(saved.accounts.map(\.id))
            let added = plan.accounts.filter { !known.contains($0.expectedAccountID ?? "") && !ids.contains($0.id) }
            let credentials = plan.credentials.filter { item in added.contains { $0.id == item.0 } }
            if !added.isEmpty {
                if usesFileCredentials { for (id, credential) in credentials { try sharedDesktop.fileStore.write(credential, id: id) } }
                else { try sharedDesktop.fileStore.activate(credentials) }
                saved.accounts += added
                for slot in added { status[slot.id] = .disconnected }
                record(L("已从私人版导入 \(added.count) 个账号和登录。", "Imported \(added.count) account\(added.count == 1 ? "" : "s") and logins from the private build."))
                banner = L("已从私人版导入 \(added.count) 个账号和登录，不用重新授权。之后只用这个版本，不要再打开私人版，免得两边互相顶掉登录。", "Imported \(added.count) account\(added.count == 1 ? "" : "s") and logins from the private build, no new sign-in needed. From now on use only this version; opening the private build again would make them sign each other out.")
                    + (plan.skipped > 0 ? L("另有 \(plan.skipped) 个账号读不到登录，需要重新连接。", "\(plan.skipped) more account\(plan.skipped == 1 ? "" : "s") had no readable login and need\(plan.skipped == 1 ? "s" : "") reconnecting.") : "")
                persist(); onChange?(); onDesktopChange?()
                Task { await refreshSequentially(force: true) }
            }
            UserDefaults.standard.set(true, forKey: "import.privateBuild")
        } catch {
            privateImportFailed = true
            banner = L("私人版账号没能导入，下次打开会再试：", "Could not import the private build's accounts; will try again next launch: ") + error.localizedDescription
        }
    }
    /// Set by the one-line installer (`--setup-routing`), whose user agreed to file storage. The first-run
    /// steps then happen without clicks, including connecting the desktop once the user signs in to Codex.
    private var installerSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "setup.installer") }
        set { UserDefaults.standard.set(newValue, forKey: "setup.installer") }
    }
    private var installerMigrationTried = false
    private var installerLoginHinted = false
    private func continueInstallerSetup() {
        guard installerSetup, !preview, persistenceEnabled else { return }
        switch routingSetup {
        case .fileStorage:
            guard !installerMigrationTried else { return }
            installerMigrationTried = true
            Task { await useFileStorage() }
        case .desktopLogin:
            if !installerLoginHinted { installerLoginHinted = true; banner = L("登录 Codex 桌面后，Tibot 会自动连接这个账号并开启路由。", "Sign in to the Codex desktop app and Tibot connects that account and turns on routing.") }
        case .desktopAccount:
            connectDesktopAccount()
        case .ready:
            installerSetup = false
            // The installer asked for routing, so it also overrides an earlier "off". When routing was already
            // on, the installer was an update: open conversations keep working without a Codex restart.
            let wasOn = gatewayEnabled
            if !wasOn { setGatewayEnabled(true) }
            if gatewayEnabled && !wasOn {
                banner = L("自动路由已设置好。重启一次 Codex，已打开的会话也会经过路由。", "Auto routing is set up. Restart Codex once so chats already open go through it too.")
                record(L("安装程序完成了自动路由设置。", "The installer finished setting up auto routing."))
            }
        }
    }
    /// An account-name click: with routing on it orders new conversations; otherwise offer to turn routing on.
    func chooseAccount(_ id: String) {
        guard !preview, let selected = slot(id), selected.expectedAccountID != nil else { return }
        if !gatewayEnabled && routingSetup != .ready {
            banner = L("先完成自动路由的设置：", "Finish setting up auto routing first: ") + (routingSetup == .fileStorage ? L("把登录改存本机文件", "store logins in local files") : L("连接 Codex 桌面正在登录的账号", "connect the account signed in to the Codex desktop app")); return
        }
        if !gatewayEnabled {
            let alert = NSAlert(); alert.messageText = L("开启自动账号路由？", "Turn on automatic account routing?")
            alert.informativeText = L("开启后新会话优先使用 \(selected.displayName)，额度用完自动换其他账号。已打开的会话需重启 Codex 后才经过路由。", "New chats will use \(selected.displayName) first and switch to another account when it runs out. Chats already open go through routing after you restart Codex.")
            alert.addButton(withTitle: L("开启路由", "Turn on routing")); alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            setGatewayEnabled(true)
            guard gatewayEnabled else { return }
        }
        // Clicking the account that is already preferred hands new conversations back to automatic routing.
        if gatewayPreferred == id { selectGatewayAccount(""); gatewayCaption = L("新会话改回自动：先用最早重置的账号", "New chats are automatic again: soonest reset first"); return }
        selectGatewayAccount(id)
        gatewayCaption = L("新会话优先使用 \(selected.displayName)", "New chats use \(selected.displayName) first")
    }
    func accountActionLabel(_ id: String) -> String {
        guard gatewayEnabled else { return L("开启自动路由并设为新会话优先…", "Turn on auto routing and prefer for new chats…") }
        return gatewayPreferred == id ? L("改回自动（先用最早重置的账号）", "Back to automatic (soonest reset first)") : L("设为新会话优先", "Prefer for new chats")
    }
    private func openChrome(for id: String, url: URL) throws {
        guard let slot = slot(id) else { return }
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else { throw ClientFailure.missingBinary }
        let proc = Process(); proc.executableURL = chrome
        var arguments: [String]
        if slot.chromeProfile == "dedicated" {
            let directory = root.appendingPathComponent("browsers/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            arguments = ["--user-data-dir=\(directory.path)", "--no-first-run"]
        } else {
            guard profiles.contains(where: { $0.id == slot.chromeProfile }) else {
                banner = L("绑定的 Chrome Profile 已不存在，请在账号设置里重新选择。", "The linked Chrome profile no longer exists. Choose another in the account settings."); throw ClientFailure.fileAccess
            }
            arguments = ["--profile-directory=\(slot.chromeProfile)"]
        }
        proc.arguments = arguments + ["--new-window", url.absoluteString]
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        try proc.run()
    }
    static func readChromeProfiles() -> [ChromeProfile] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: path), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = object["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] else {
            return [.init(id: "dedicated", name: L("新建此账号专用窗口", "New window just for this account"))]
        }
        return cache.sorted { $0.key < $1.key }.map { ChromeProfile(id: $0.key, name: $0.value["name"] as? String ?? $0.key) } + [.init(id: "dedicated", name: L("新建此账号专用窗口", "New window just for this account"))]
    }
    func profileCaption(_ slot: AccountSlot) -> String? {
        guard slot.chromeProfile != "dedicated", let profile = profiles.first(where: { $0.id == slot.chromeProfile }) else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    func profileName(_ id: String) -> String { profiles.first { $0.id == id }?.name ?? L("Profile 不可用", "Profile unavailable") }
    private func safeError(_ error: Error) -> String { (error as? ClientFailure)?.localizedDescription ?? L("操作暂未完成，请检查网络、Chrome 或钥匙串权限后重试。", "That did not finish. Check the network, Chrome or Keychain access and try again.") }
    private func persist() {
        guard persistenceEnabled, !preview else { return }
        do {
            let url = root.appendingPathComponent("state.json")
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { banner = L("本次数据未能保存到磁盘，请检查权限和可用空间。当前窗口仍保留数据。", "Could not save to disk. Check permissions and free space; this window still has the data.") }
    }
    private func record(_ text: String) {
        saved.events.insert(ActivityEntry(text), at: 0)
        saved.events = Array(saved.events.prefix(50)); persist()
    }
    private func remind(_ id: String, key: String, text: String) {
        guard let i = index(id), !saved.accounts[i].reminderKeys.contains(key) else { return }
        saved.accounts[i].reminderKeys.append(key)
        saved.accounts[i].reminderKeys = Array(saved.accounts[i].reminderKeys.suffix(120))
        record(text)
        if saved.notificationsEnabled {
            let content = UNMutableNotificationContent(); content.title = "Tibot"; content.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(key)", content: content, trigger: nil))
        }
    }
    private func evaluateReminders(id: String, previous: Snapshot?, current: Snapshot) {
        let name = slot(id)?.displayName ?? L("账号", "Account"), now = Date()
        for (bucketID, bucket) in current.rates.buckets {
            for (position, window) in [bucket.primary, bucket.secondary].enumerated() {
                guard let window, let reset = window.resetsAt, let remaining = window.remaining else { continue }
                let seconds = reset - now.timeIntervalSince1970
                if seconds > 0, seconds <= 12 * 3600, remaining >= 30 {
                    remind(id, key: "soon-\(bucketID)-\(position)-\(reset)", text: L("\(name) 的\(window.label)还剩 \(Int(remaining))%，\(Presentation.resetCountdown(window.resetDate))。", "\(name) · \(window.label): \(Int(remaining))% left, \(Presentation.resetCountdown(window.resetDate))."))
                }
                if let oldBucket = previous?.rates.buckets.first(where: { $0.0 == bucketID })?.1,
                   let old = [oldBucket.primary, oldBucket.secondary][position], let oldRemaining = old.remaining,
                   remaining >= oldRemaining + 10 {
                    remind(id, key: "restored-\(bucketID)-\(position)-\(reset)-\(Int(remaining))", text: L("\(name) 的\(window.label)已更新，当前剩余 \(Int(remaining))%。", "\(name) · \(window.label) refreshed: \(Int(remaining))% left."))
                }
            }
        }
        for credit in current.rates.rateLimitResetCredits?.credits ?? [] where credit.status == "available" {
            if let expires = credit.expiresAt, expires > now.timeIntervalSince1970, expires - now.timeIntervalSince1970 <= 48 * 3600 {
                remind(id, key: "expiry-\(credit.id)", text: L("\(name) 有 banked reset 即将到期：\(Presentation.countdown(Date(timeIntervalSince1970: expires)))。", "\(name) has a banked reset expiring \(Presentation.countdown(Date(timeIntervalSince1970: expires)))."))
            }
        }
    }
    private var resetMonitorURL: URL { root.appendingPathComponent("reset-monitor.json") }
    private var personalXURL: URL { root.appendingPathComponent("personal-x-monitor.json") }
    private func loadPersonalX() {
        guard persistenceEnabled else { personalXStorageAvailable = false; return }
        guard FileManager.default.fileExists(atPath: personalXURL.path) else { return }
        do { personalX = try JSONDecoder().decode(PersonalXState.self, from: Data(contentsOf: personalXURL)) }
        catch { personalXStorageAvailable = false; personalX.lastError = L("X 监控记录无法读取，已暂停并保留原文件。", "Could not read the X watch history; watching is paused and the file is kept.") }
    }
    @discardableResult private func savePersonalX() -> Bool {
        guard !preview, persistenceEnabled, personalXStorageAvailable else { return false }
        do {
            try JSONEncoder().encode(personalX).write(to: personalXURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: personalXURL.path)
            return true
        } catch {
            personalXStorageAvailable = false; personalX.enabled = false
            personalX.lastError = PersonalXError.storage.localizedDescription; return false
        }
    }
    var personalXCaption: String {
        if let error = personalX.lastError { return error }
        if personalXTesting { return L("正在测试个人 X 登录态…", "Testing your X sign-in…") }
        guard let checked = personalX.lastCheckedAt else { return resetMonitor.enabled ? L("等待首次登录与测试；当前使用第三方公告源。", "Waiting for the first sign-in and test; using the third-party source for now.") : L("尚未连接个人 X；公告监控已关闭。", "Your X account is not connected; announcement watching is off.") }
        let status = personalX.enabled ? L("已连接个人 X", "Your X account is connected") : L("个人 X 监控已关闭", "X watching is off")
        return status + L(" · 读到 \(personalX.lastPosts.count) 条 · ", " · read \(personalX.lastPosts.count) post\(personalX.lastPosts.count == 1 ? "" : "s") · ") + checked.formatted(date: .omitted, time: .shortened)
            + (personalX.possibleGap ? L(" · 中间可能有漏帖，请核对主页", " · some posts may be missing; check the profile") : "")
    }
    func disablePersonalX() {
        guard !personalXTesting else { return }
        personalX.enabled = false; savePersonalX()
        resetCheckGeneration = UUID(); resetCheckTask?.cancel(); resetCheckTask = nil
        checkingResetAnnouncements = false; nextResetCheck = .distantPast
        checkResetAnnouncements(force: true)
    }
    func endPersonalXInteraction() { xBrowser?.interactive = false }
    func testAndEnablePersonalX() {
        guard !preview, persistenceEnabled, resetStorageAvailable, personalXStorageAvailable, !personalXTesting else { return }
        resetCheckGeneration = UUID(); resetCheckTask?.cancel(); resetCheckTask = nil; checkingResetAnnouncements = false
        personalXTesting = true; personalX.lastError = nil
        personalXTask = Task { [weak self] in
            guard let self else { return }
            defer { self.personalXTesting = false; self.personalXTask = nil }
            do {
                let posts = try await self.personalXBrowser.readTimeline(reload: false)
                try Task.checkCancellation()
                let now = Date()
                if self.personalX.enabled { try self.acceptPersonalXPosts(posts, now: now) }
                else {
                    self.personalX.start(with: posts, now: now)
                    guard self.savePersonalX() else { throw PersonalXError.storage }
                }
                self.resetMonitor.enabled = true; self.resetMonitor.lastError = nil
                self.resetMonitor.lastCheckedAt = now; self.resetMonitor.sourceUpdatedAt = now; self.resetMonitor.sourceStale = false
                self.saveResetMonitor(); self.nextResetCheck = now.addingTimeInterval(60)
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                self.record(L("个人 X 监控已连接；每分钟检查 Tibo，新公告触发所有账号余量查询。", "X watching is on: Tibo is checked every minute, and a new announcement refreshes every account's quota."))
            } catch is CancellationError { }
            catch { self.personalX.lastError = (error as? PersonalXError ?? .unavailable).localizedDescription; self.savePersonalX() }
        }
    }
    /// The user's Codex reading of new posts, when they chose it in settings. A post is asked about once;
    /// one the model could not judge falls back to the rules.
    private func judge(_ posts: [(id: String, text: String, publishedAt: String)], among all: [(publishedAt: String, text: String)]) async -> [String: ResetJudge.Verdict] {
        guard resetUsesModel, !posts.isEmpty, let binary = try? Self.binary() else { return [:] }
        let gatewayURL = gatewayEnabled ? "http://127.0.0.1:\(gateway.port)/backend-api/codex" : nil
        let newestFirst = all.sorted { $0.publishedAt > $1.publishedAt }
        var verdicts: [String: ResetJudge.Verdict] = [:], judged = resetMonitor.judged ?? [:], failed = 0
        for post in posts.prefix(5) {
            if let known = judged[post.id] { verdicts[post.id] = known; continue }
            guard ResetJudge.worthAsking(post.text) else { continue }
            let earlier = newestFirst.filter { $0.publishedAt < post.publishedAt }.map(\.text)
            if let verdict = await CodexJudge.verdict(text: post.text, postedAt: post.publishedAt, earlier: earlier, binary: binary, gateway: gatewayURL) {
                verdicts[post.id] = verdict; judged[post.id] = verdict
            } else { failed += 1 }
        }
        // Tweet ids grow over time: keep the newest readings.
        if judged.count > 300 { judged = Dictionary(uniqueKeysWithValues: judged.sorted { ($0.key.count, $0.key) > ($1.key.count, $1.key) }.prefix(300).map { ($0.key, $0.value) }) }
        resetMonitor.judged = judged; saveResetMonitor()
        if failed > 0 { record(L("有 \(failed) 条 Tibo 新帖 Codex 没判断出来，已按规则判断。", "Codex could not judge \(failed) new Tibo post\(failed == 1 ? "" : "s"); used the rules instead.")) }
        return verdicts
    }
    @Published private(set) var resetUsesModel = UserDefaults.standard.bool(forKey: "reset.model")
    func setResetUsesModel(_ on: Bool) { resetUsesModel = on; UserDefaults.standard.set(on, forKey: "reset.model") }
    private func acceptPersonalXPosts(_ posts: [XVisiblePost], now: Date, verdicts: [String: ResetJudge.Verdict] = [:]) throws {
        var updated = personalX
        let feed = updated.ingest(posts, now: now, verdicts: verdicts)
        let signals = try resetMonitor.ingest(feed, accountIDs: saved.accounts.filter { $0.expectedAccountID != nil }.map(\.id), now: now)
        // Persist refresh work before advancing the X deduplication state. A crash may repeat a quota read, never lose a signal.
        saveResetMonitor()
        guard resetStorageAvailable else { throw PersonalXError.storage }
        personalX = updated
        guard savePersonalX() else { throw PersonalXError.storage }
        if let signal = signals.last {
            resetNextAttempt.removeAll()
            record(L("个人 X 发现 Tibo \(signal.label)\(signal.note == nil ? "" : "（Codex 判断）")，刷新所有账号。原帖：\(signal.originalURL!.absoluteString)", "X: Tibo \(signal.label)\(signal.note == nil ? "" : " (judged by Codex)"); refreshing all accounts. Post: \(signal.originalURL!.absoluteString)"))
            notifyReset(signal)
            retryResetRefresh()
        }
    }
    private func loadResetMonitor() {
        guard persistenceEnabled else { resetStorageAvailable = false; return }
        do {
            if FileManager.default.fileExists(atPath: resetMonitorURL.path) {
                resetMonitor = try JSONDecoder().decode(ResetMonitorState.self, from: Data(contentsOf: resetMonitorURL))
            } else { resetMonitor.enabled = false; saveResetMonitor() }
        } catch {
            resetStorageAvailable = false; resetMonitor.enabled = false
            resetMonitor.lastError = L("公告监控记录无法读取，已停止监控以保留原记录。", "Could not read the announcement history; watching stopped to keep it intact.")
        }
    }
    private func saveResetMonitor() {
        guard !preview, persistenceEnabled, resetStorageAvailable else { return }
        do {
            try JSONEncoder().encode(resetMonitor).write(to: resetMonitorURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resetMonitorURL.path)
        } catch {
            resetStorageAvailable = false; resetMonitor.enabled = false
            resetMonitor.lastError = L("公告监控记录无法保存，已停止监控；账号同步继续。", "Could not save the announcement history; watching stopped. Account sync goes on.")
        }
    }
    /// Tells the user right away, with what is left to use before a planned reset wipes it.
    private func notifyReset(_ signal: ResetAnnouncement) {
        let accounts = saved.accounts.compactMap { slot -> ResetNotice.Account? in
            // A global reset refills the longest window too; that is the quota that would go unused.
            guard let window = slot.snapshot?.rates.windows.filter({ $0.remaining != nil })
                .max(by: { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }) else { return nil }
            return .init(name: slot.displayName, remaining: window.remaining!)
        }
        guard let notice = ResetNotice.message(for: signal, accounts: accounts, now: Date()) else { return }
        let content = UNMutableNotificationContent(); content.title = notice.title; content.body = notice.body; content.sound = .default
        if let link = signal.originalURL { content.userInfo = ["url": link.absoluteString] }
        // The star-eyed mascot as the thumbnail; the system moves the file into its own store.
        let thumbnail = FileManager.default.temporaryDirectory.appendingPathComponent("tibot-reset-\(UUID().uuidString).png")
        if let png = Dango.png(.star), (try? png.write(to: thumbnail)) != nil,
           let attachment = try? UNNotificationAttachment(identifier: "mascot", url: thumbnail) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: "reset-" + signal.key, content: content, trigger: nil)
        // A reminder that silently never shows is worse than none: say why in the activity list.
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]); status = await center.notificationSettings().authorizationStatus }
            guard status == .authorized || status == .provisional else {
                self?.record(L("Tibo 提醒没能弹出：系统通知未允许 Tibot，请在「系统设置 → 通知 → Tibot」里打开。", "The Tibo alert could not show: notifications are off for Tibot. Turn them on in System Settings → Notifications → Tibot.")); return
            }
            do { try await center.add(request); self?.record(L("已发出系统通知「\(notice.title)」。", "Sent the notification “\(notice.title)”.")) }
            catch { self?.record(L("Tibo 提醒没能弹出：\(error.localizedDescription)", "The Tibo alert could not show: \(error.localizedDescription)")) }
        }
    }
    /// A planned reset the user can still act on; shown on the widget and dashboard until it passes.
    var resetAlert: (text: String, url: URL)? {
        guard resetMonitor.enabled, let post = resetMonitor.lastAnnouncement, post.isUpcoming(at: now),
              let timing = post.timing, let url = post.originalURL else { return nil }
        return (L("Tibo 预告", "Tibo: ") + timing.describe(now: now) + L(" · 抓紧用", " · use it up"), url)
    }
    func setResetMonitoring(_ enabled: Bool) {
        guard !preview, resetStorageAvailable else { return }
        resetMonitor.enabled = enabled; saveResetMonitor()
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            checkResetAnnouncements(force: true)
        }
        else { resetCheckGeneration = UUID(); resetCheckTask?.cancel(); resetCheckTask = nil; checkingResetAnnouncements = false }
    }
    var resetSourceCaption: String {
        if !resetMonitor.enabled { return L("已关闭", "Off") }
        if personalXTesting { return L("正在连接 X…", "Connecting to X…") }
        if let error = resetMonitor.lastError ?? (personalX.enabled ? personalX.lastError : nil) { return error }
        if checkingResetAnnouncements { return L("正在检查…", "Checking…") }
        let source = personalX.enabled ? L("已连接 X · 每分钟检查", "X connected · checked every minute") : L("未登录 X · 公共源", "Not signed in to X · public source") + (resetMonitor.sourceStale ? L("有延迟", " (delayed)") : "")
        guard let checked = resetMonitor.lastCheckedAt else { return source }
        return source + " · " + checked.formatted(date: .omitted, time: .shortened)
    }
    /// While the X window is open: once signed in, open Tibo's page and start monitoring without extra clicks.
    func autoConnectPersonalX() async {
        guard !preview, !personalX.enabled, !personalXTesting, Date().timeIntervalSince(lastAutoConnect) >= 8,
              let page = await personalXBrowser.pageState(), page.loggedIn else { return }
        lastAutoConnect = Date()
        if page.onTibo { testAndEnablePersonalX() } else { personalXBrowser.openTibo() }
    }
    func checkResetAnnouncements(force: Bool = false) {
        guard !preview, persistenceEnabled, resetStorageAvailable, resetMonitor.enabled,
              !checkingResetAnnouncements, !personalXTesting, force || Date() >= nextResetCheck else { return }
        if personalX.enabled && xBrowser?.interactive == true { return }
        checkingResetAnnouncements = true
        nextResetCheck = Date().addingTimeInterval(personalX.enabled ? 60 : 300)
        let generation = UUID(); resetCheckGeneration = generation
        resetCheckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.resetCheckGeneration == generation { self.checkingResetAnnouncements = false; self.resetCheckTask = nil }
            }
            do {
                if self.personalX.enabled {
                    do {
                        var posts = try await self.personalXBrowser.readTimeline(reload: true)
                        // A new long post is cut off on the profile; read it in full before deciding what it says.
                        let seen = Set(self.personalX.seenIDs), since = self.personalX.baselineAt ?? .distantFuture
                        for (i, post) in posts.enumerated().filter({ $0.element.truncated && !seen.contains($0.element.id) && ($0.element.date ?? .distantPast) >= since }).prefix(3) {
                            if let url = post.originalURL, let full = try await self.personalXBrowser.readPost(url) { posts[i] = full }
                        }
                        let recent = Date().addingTimeInterval(-72 * 3600)
                        let fresh = posts.filter { !seen.contains($0.id) && !$0.truncated && ($0.date ?? .distantPast) >= max(since, recent) }
                        let verdicts = await self.judge(fresh.map { ($0.id, $0.text, $0.publishedAt) }, among: posts.map { ($0.publishedAt, $0.text) })
                        try Task.checkCancellation()
                        guard self.resetMonitor.enabled, self.resetCheckGeneration == generation else { return }
                        try self.acceptPersonalXPosts(posts, now: Date(), verdicts: verdicts)
                        self.resetCheckFailures = 0
                        return
                    } catch is CancellationError { return }
                    catch {
                        // X unreadable (signed out, rate-limited, page changed): say so, and still read the public source.
                        guard !Task.isCancelled, self.resetCheckGeneration == generation else { return }
                        self.personalX.lastError = (error as? PersonalXError ?? .unavailable).localizedDescription
                        self.savePersonalX()
                        self.nextResetCheck = Date().addingTimeInterval(300)
                    }
                }
                var feed = try await ResetAnnouncementAPI.fetch()
                if self.resetUsesModel {
                    let seenIDs = Set(self.resetMonitor.seenKeys.compactMap { $0.split(separator: ":").first.map(String.init) })
                    let recent = Date().addingTimeInterval(-72 * 3600)
                    let fresh = feed.items.filter { !seenIDs.contains($0.id) && ($0.date ?? .distantPast) >= max(self.resetMonitor.startedAt, recent) }
                    feed = feed.applying(await self.judge(fresh.map { ($0.id, $0.text, $0.published_at) }, among: feed.items.map { ($0.published_at, $0.text) }))
                }
                try Task.checkCancellation()
                guard self.resetMonitor.enabled, self.resetCheckGeneration == generation else { return }
                let signals = try self.resetMonitor.ingest(feed, accountIDs: self.saved.accounts.filter { $0.expectedAccountID != nil }.map(\.id), now: Date())
                self.resetCheckFailures = 0
                if self.personalX.enabled, let xError = self.personalX.lastError { self.resetMonitor.lastError = xError + L(" 已改用公共源。", " Switched to the public source.") }
                self.saveResetMonitor()
                if let signal = signals.last, self.resetStorageAvailable {
                    self.resetNextAttempt.removeAll()
                    self.record(L("检测到 Tibo \(signal.label)\(signal.note == nil ? "" : "（Codex 判断）")，开始刷新全部账号。原帖：\(signal.originalURL!.absoluteString)", "Tibo: \(signal.label)\(signal.note == nil ? "" : " (judged by Codex)"); refreshing all accounts. Post: \(signal.originalURL!.absoluteString)"))
                    self.notifyReset(signal)
                    self.retryResetRefresh()
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.resetCheckGeneration == generation else { return }
                self.resetCheckFailures += 1
                let base: Double = self.personalX.enabled ? 60 : 300
                self.nextResetCheck = Date().addingTimeInterval(min(1800, base * pow(2, Double(min(self.resetCheckFailures - 1, 5)))))
                self.resetMonitor.lastError = self.personalX.enabled
                    ? (self.personalX.lastError ?? L("公告检查失败，将自动重试。", "The announcement check failed; retrying automatically."))
                    : L("公告检查失败，将自动重试；账号额度仍正常同步。", "The announcement check failed; retrying automatically. Quotas still sync.")
                self.saveResetMonitor()
            }
        }
    }
    private func retryResetRefresh() {
        guard !preview, !resetRefreshBusy, resetMonitor.canRetry(at: Date()) else { return }
        resetRefreshBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.resetRefreshBusy = false }
            for id in self.resetMonitor.pendingAccountIDs {
                guard self.resetMonitor.enabled, !Task.isCancelled else { return }
                guard self.index(id) != nil, !self.busy.contains(id), self.loginSlotID != id,
                      (self.resetNextAttempt[id] ?? .distantPast) <= Date() else { continue }
                if self.status[id] == .needsAuth { continue }
                if case .wrongAccount = self.status[id] { continue }
                self.resetNextAttempt[id] = Date().addingTimeInterval(60)
                await self.sync(id, force: true)
            }
        }
    }

    func setDesktopVisible(_ visible: Bool) {
        desktopVisible = visible; UserDefaults.standard.set(visible, forKey: "desktop.visible")
        onDesktopChange?()
    }
    func setDesktopPinned(_ pinned: Bool) {
        desktopPinned = pinned; UserDefaults.standard.set(pinned, forKey: "desktop.pinned")
        onDesktopChange?()
    }
    enum DesktopMode: String, CaseIterable { case off, embedded, floating }
    var desktopMode: DesktopMode { desktopPinned ? .floating : (embeddedVisible ? .embedded : .off) }
    func setDesktopMode(_ mode: DesktopMode) {
        embeddedVisible = mode == .embedded; UserDefaults.standard.set(embeddedVisible, forKey: "embedded.visible")
        desktopPinned = mode == .floating; UserDefaults.standard.set(desktopPinned, forKey: "desktop.pinned")
        desktopVisible = desktopPinned; UserDefaults.standard.set(desktopVisible, forKey: "desktop.visible")
        onDesktopChange?()
    }
    func setEmbeddedVisible(_ visible: Bool) { setDesktopMode(visible ? .embedded : (desktopPinned ? .floating : .off)) }
    func setNotifications(_ enabled: Bool) {
        guard !preview else { return }
        if !enabled { saved.notificationsEnabled = false; persist(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in Task { @MainActor in
            guard let self else { return }; self.saved.notificationsEnabled = granted
            if !granted { self.banner = L("系统通知未开启，重要变化仍会显示在 Tibot 的最近动态里。", "Notifications are off; important changes still show in Tibot's recent activity.") }
            self.persist()
        } }
    }
    func setLoginAtLaunch(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginAtLaunch = SMAppService.mainApp.status == .enabled
            if enabled && !loginAtLaunch { banner = L("请在系统设置的登录项中允许 Tibot。", "Allow Tibot in System Settings → General → Login Items.") }
        } catch { banner = L("登录时启动未设置成功，可在系统设置 → 通用 → 登录项中添加 Tibot。", "Could not turn on Open at login. Add Tibot in System Settings → General → Login Items.") }
    }
    func shutdown() {
        // Keep the routing preference for the next launch, but leave Codex on the direct provider while we are gone.
        try? gateway.configuration.restore(); try? gateway.stop(restore: false)
        personalXTask?.cancel(); xBrowser?.stop()
        timer?.invalidate(); resetCheckTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        clients.values.forEach { $0.stop() }
        persist()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    private func loadPreview() {
        saved.accounts = AccountSlot.defaults
        for slot in saved.accounts { status[slot.id] = .disconnected }
        banner = L("界面预览 · 以下是模拟数据，不代表你的真实账号额度。", "Preview · sample data, not your real quotas.")
        let fixtures = [
            #"{"accountId":"preview1","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":RESET},"secondary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":SHORT}}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"demo","status":"available","expiresAt":EXPIRY}]}}"#,
            #"{"accountId":"preview2","rateLimits":{"primary":{"usedPercent":82,"windowDurationMins":10080,"resetsAt":RESET}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#,
            #"{"accountId":"preview3","rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":RESET}},"rateLimitResetCredits":null}"#
        ]
        for i in fixtures.indices {
            let text = fixtures[i].replacingOccurrences(of: "RESET", with: "\(Date().addingTimeInterval(Double(i + 1) * 28800).timeIntervalSince1970)")
                .replacingOccurrences(of: "SHORT", with: "\(Date().addingTimeInterval(7200).timeIntervalSince1970)")
                .replacingOccurrences(of: "EXPIRY", with: "\(Date().addingTimeInterval(86400).timeIntervalSince1970)")
            if let rates = try? JSONDecoder().decode(RateResponse.self, from: Data(text.utf8)),
               let identity = try? JSONDecoder().decode(AccountIdentity.self, from: Data(#"{"type":"chatgpt","email":"demo@example.com","planType":"pro"}"#.utf8)) {
                saved.accounts[i].snapshot = Snapshot(identity: identity, rates: rates); status[saved.accounts[i].id] = .connected
            }
        }
        if CommandLine.arguments.contains("--routing-preview") || Bundle.main.bundleIdentifier?.contains("routing-preview") == true {
            gatewayEnabled = true; gatewayReady = true
            routingActivity.receive(.init(kind: "routing", account: saved.accounts[0].id, request: "preview-a"))
            routingActivity.receive(.init(kind: "routing", account: saved.accounts[2].id, request: "preview-b"))
        }
        saved.accounts[2].snapshot?.fetchedAt = Date().addingTimeInterval(-3600)
        status[saved.accounts[2].id] = .failure(L("网络暂时不可用；显示的是上次同步数据。", "The network is unavailable; showing the last synced data."))
    }
}
