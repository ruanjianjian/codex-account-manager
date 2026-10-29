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
        case .disconnected: return "尚未连接"
        case .checking: return "正在同步"
        case .connected: return "已连接"
        case .waiting: return "等待浏览器授权"
        case .needsAuth: return "需要重新验证"
        case .failure: return "同步失败 · 保留旧数据"
        case .wrongAccount: return "请核对账号"
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
    @Published var gatewayCaption = "自动路由未开启"
    @Published var gatewayAccount: String?
    @Published var gatewayPreferred = UserDefaults.standard.string(forKey: "gateway.preferred") ?? ""
    private lazy var gateway = GatewayController(root: root)
    var usesFileCredentials: Bool { sharedDesktop.fileStore.enabled }
    @Published var banner: String?
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
    var shortcutLabel: String { shortcutChoice == "none" ? "未设置快捷键" : shortcutChoice == "ctrl-semicolon" ? "⌃ ;" : (shortcutChoice == "space" ? "⌥ 空格" : "⌥ " + shortcutChoice.uppercased()) }
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
        banner = "\(slot(id)?.displayName ?? "账号")：\(CollectorRetryPolicy.message)"
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
                let alert = NSAlert(); alert.messageText = "账号管家已经在运行"; alert.informativeText = "请从菜单栏打开现有窗口。"; alert.runModal(); exit(0)
            }
            let stateURL = root.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                saved = try state.migrated()
            }
        } catch {
            persistenceEnabled = false
            banner = "本机状态文件无法读取，已停止保存和连接以保护原数据。请检查数据目录后重新打开。"
        }
        if shortcutChoice == "c" { shortcutChoice = "ctrl-semicolon"; UserDefaults.standard.set(shortcutChoice, forKey: "desktop.shortcut") }
        profiles = Self.readChromeProfiles()
        loginAtLaunch = SMAppService.mainApp.status == .enabled
        if !preview { collectorRetry = CollectorRetryPolicy(paused: Set(UserDefaults.standard.stringArray(forKey: collectorPauseKey) ?? [])) }
        for slot in saved.accounts {
            status[slot.id] = collectorRetry.paused.contains(slot.id) ? .failure(CollectorRetryPolicy.message) : .disconnected
        }
        if preview { loadPreview(); return }
        if sharedDesktop.interruptedSwitch { banner = "旧版本留下了一次未完成的桌面切换。新版不再改 Codex 登录；如账号不对，请在 Codex 里重新登录。" }
        loadResetMonitor()
        loadPersonalX()
        checkResetAnnouncements()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.nextPoll.removeAll(); self?.refreshAll(); self?.checkResetAnnouncements(force: true)
        } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } })
        desktopSlotSeen = desktopSelection?.slotID
        setupGateway()
        if CommandLine.arguments.contains("--setup-routing") { installerSetup = true }
        continueInstallerSetup()
        Task { await refreshSequentially() }
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
                    self.gatewayCaption = "网关就绪 · 支持新旧会话，升级后重启 Codex"
                } catch { self.gatewayReady = false; self.gatewayCaption = error.localizedDescription }
            case "routing":
                self.gatewayAccount = id
                self.gatewayCaption = "正在使用 \(id.flatMap { self.slot($0)?.displayName } ?? "账号")"
            case "completed": self.gatewayCaption = "路由成功 · \(id.flatMap { self.slot($0)?.displayName } ?? "账号")"
            case "refused":
                self.gatewayCaption = "账号暂不可用，正在尝试其他账号"
                if let id, code == 401 { self.refresh(id) }
            case "interrupted": self.gatewayCaption = "回复中断，未重复执行；请在 Codex 中重试"
            case "stopped": self.fallBackToDirect("网关已停止：\(event.reason ?? "进程已退出")")
            case "rejected": if let caption = self.rejectionCaption(event) { self.gatewayCaption = caption }
            case "local_auth_rejected": self.gatewayCaption = "桌面认证不匹配；请确认当前登录账号已连接到管家"
            case "local_auth_unavailable": self.gatewayCaption = "本机认证记录不可用；保留现场并检查私有文件权限"
            default: break
            }
        }
        if gatewayEnabled || CommandLine.arguments.contains("--enable-gateway") { setGatewayEnabled(true) }
        else if gateway.configuration.installed { fallBackToDirect("自动路由未开启") }
    }
    /// Never leave Codex pointed at a port nobody serves. Codex reloads config.toml for new and
    /// resumed conversations, so restoring the direct provider recovers them; the toggle stays as chosen.
    private func fallBackToDirect(_ reason: String) {
        let wasInstalled = gateway.configuration.installed
        // Restore first: if the provider table was edited elsewhere, a helper that still runs keeps serving.
        do { try gateway.configuration.restore() } catch {
            gatewayCaption = "\(reason) · \(error.localizedDescription) 请在 ~/.codex/config.toml 删除 openai_base_url 一行后重启 Codex。"
            if gateway.running { return }
            gatewayReady = false; gatewayAccount = nil; routingActivity.receive(.init(kind: "stopped"))
            return
        }
        try? gateway.stop(restore: false)
        gatewayReady = false; gatewayAccount = nil; routingActivity.receive(.init(kind: "stopped"))
        // Conversations the gateway created on another account carry that account's sealed history.
        gatewayCaption = wasInstalled ? "\(reason) · 已恢复直连；经网关在其他账号上开的会话需等网关恢复后再继续" : reason
    }
    /// Only reasons a Codex conversation can cause; local probes (for example a web page) never change the caption.
    private func rejectionCaption(_ event: GatewayActivityEvent) -> String? {
        let name = event.account.flatMap { slot($0)?.displayName } ?? "原账号"
        switch event.reason {
        case "sealed_owner_unavailable": return "旧会话含加密历史，只能用 \(name)；它暂不可用，请等额度恢复或新开会话"
        case "sealed_owner_unknown": return "旧会话的原账号未知，网关未换号转发；请新开会话"
        case "no_available_account", "all_accounts_declined": return "没有可用账号；刷新账号或等待额度重置"
        case "unsupported_route": return "Codex 调用了网关尚未支持的接口，已记录到诊断日志"
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
            if let value = try? GatewayAccount(id: slot.id, credential: credential, available: !spent, reset: windows.compactMap(\.resetsAt).min() ?? 0) { accounts.append(value) }
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
                gatewayCaption = "正在启动本机网关…"
            } else {
                try gateway.stop(restore: true); routingActivity.receive(.init(kind: "stopped")); gatewayReady = false; gatewayAccount = nil
                gatewayCaption = "已恢复原配置 · 重启 Codex 生效"
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
        if gatewayEnabled { banner = "已自动开启自动路由。已打开的 Codex 会话重启 Codex 后也会经过路由。" }
    }
    /// The desktop's own login becomes an account: no browser sign-in, and no copy of its token.
    func connectDesktopAccount() {
        guard canConnect, loginSlotID == nil, launchingDesktop.isEmpty, case .desktopAccount = routingSetup,
              let accountID = sharedDesktop.desktopAccountID() else { return }
        let id = "account-" + UUID().uuidString.lowercased()
        var slot = AccountSlot(id: id, name: "新账号", chromeProfile: "dedicated")
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
    var recommendation: String { Presentation.recommendation(saved.accounts, healthy: healthy, now: now) ?? "连接账号后，这里会优先提示即将重置且仍有余量的账号。" }
    var canConnect: Bool { persistenceEnabled && !preview }
    var loginName: String { saved.accounts.first { $0.id == loginSlotID }?.displayName ?? "账号" }
    var menuTitle: String {
        let active = saved.accounts.filter { healthy.contains($0.id) && $0.snapshot?.isFresh(at: now) == true }
        guard let best = active.min(by: { ($0.snapshot?.rates.windows.compactMap(\.resetDate).min() ?? .distantFuture) < ($1.snapshot?.rates.windows.compactMap(\.resetDate).min() ?? .distantFuture) }),
              let remaining = best.snapshot?.rates.windows.compactMap(\.remaining).min() else { return "Codex \(connectedCount)/\(saved.accounts.count)" }
        return "\(best.displayName) \(Int(remaining))%"
    }
    func slot(_ id: String) -> AccountSlot? { saved.accounts.first { $0.id == id } }
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
    func usageCaption(accountID: String? = nil) -> String {
        let accounts = saved.accounts.filter { accountID == nil || $0.id == accountID }
        let available = accounts.filter { $0.tokenUsage?.response.dailyUsageBuckets != nil }.count
        if accounts.contains(where: { usageLoading.contains($0.id) }) { return "统计更新中" }
        if accounts.contains(where: { usageErrors[$0.id] != nil }) { return "部分更新失败 · 保留旧统计" }
        if available == 0 { return "暂无每日统计" }
        let stale = accounts.contains { Date().timeIntervalSince($0.tokenUsage?.fetchedAt ?? .distantPast) > 600 }
        if stale { return "缓存统计 · 待更新" }
        return available == accounts.count ? "\(available) 个账号 · 服务端统计" : "\(available)/\(accounts.count) 个账号已返回"
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
                status[id] = .wrongAccount("本次登录与原账号不一致。请在绑定的 Chrome 窗口选回原账号，再重新连接；要换账号请先移除本机连接。")
                loginQueue.removeAll(); return
            case .duplicate(let name):
                status[id] = .wrongAccount("已连接到“\(name)”，请选择另一个账号。")
                loginQueue.removeAll(); return
            case .unverifiable:
                status[id] = .wrongAccount("服务未提供可核对的账号身份，暂不计入已连接账号。请稍后重新连接。")
                loginQueue.removeAll(); return
            }
            let old = saved.accounts[i].snapshot
            let snapshot = Snapshot(identity: identity, rates: rates)
            saved.accounts[i].snapshot = snapshot
            saved.accounts[i].expectedEmail = identity.email
            saved.accounts[i].expectedAccountID = rates.accountId ?? saved.accounts[i].expectedAccountID
            status[id] = .connected; failures[id] = 0
            Task { await syncUsage(id) }
            nextPoll[id] = Date().addingTimeInterval(60)
            if old == nil { record("\(saved.accounts[i].displayName) 已连接，登录状态已保存。") }
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
                fallBackToDirect("Codex 当前登录的账号未连接到管家")
            } else { do { try updateGatewayPool() } catch { gatewayCaption = error.localizedDescription } }
        }
        continueInstallerSetup()
        enableRoutingWhenReady()
        checkResetAnnouncements()
        retryResetRefresh()
        if let started = loginStarted, now.timeIntervalSince(started) > 600 {
            Task { await cancelLogin(); banner = "本次登录等待已超时。已有连接未受影响，可重新连接。" }
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
        if loginSlotID == id { return loginURL == nil ? "准备授权…" : "继续授权 →" }
        if loginSlotID != nil { return "请先完成其他账号授权" }
        return busy.contains(id) ? "正在同步…" : "连接账号 →"
    }
    func connectOrContinue(_ id: String) {
        guard canOpenConnection(id) else { return }
        if loginSlotID == id { reopenLogin() } else { connect(id) }
    }
    private func beginLogin(_ id: String) async {
        guard launchingDesktop.isEmpty, desktopSelection?.slotID != id, accountDesktop.running(root: root, id: id) == nil else {
            banner = "此账号正在用于桌面端。请先在 Codex 里登录其他账号并退出旧独立窗口，再重新授权。"; return
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
            record("已为 \(slot(id)?.displayName ?? "账号") 打开绑定的 Chrome 窗口，等待授权。")
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
        record("已取消 \(slot(id)?.displayName ?? "账号") 的本次连接。浏览器窗口保留。")
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
                status[id] = .failure(keyring ? "登录已完成，但系统钥匙串无法保存。请在“管家设置”改用本地文件存储后重新连接。"
                                              : "登录未完成，请重新连接。已有账号不会退出。")
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
        saved.accounts[i].name = String(clean.isEmpty ? "账号 \(i + 1)" : clean.prefix(32))
        saved.accounts[i].nameOverride = clean.isEmpty ? nil : String(clean.prefix(128))
        saved.accounts[i].chromeProfile = profile
        persist(); onChange?()
    }
    func addAccount(profile: String, alias: String) {
        guard launchingDesktop.isEmpty, canConnect, loginSlotID == nil, profiles.contains(where: { $0.id == profile }) else { return }
        let id = "account-" + UUID().uuidString.lowercased()
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var slot = AccountSlot(id: id, name: "新账号", chromeProfile: profile)
        slot.nameOverride = clean.isEmpty ? nil : String(clean.prefix(128))
        saved.accounts.append(slot); status[id] = .disconnected; persist(); onChange?(); onDesktopChange?()
        connect(id)
    }
    func disconnect(_ id: String) async {
        guard launchingDesktop.isEmpty, desktopSelection?.slotID != id, accountDesktop.running(root: root, id: id) == nil else {
            banner = "此账号正在用于桌面端。请先在 Codex 里登录其他账号并退出旧独立窗口，再移除连接。"; return
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
            record("\(slot.displayName) 已从看板移除，Chrome 登录未改变。")
            onDesktopChange?()
            persist(); onChange?()
        } catch { banner = "连接未能移除，原记录保留。\(safeError(error))" }
    }
    func openAccountPage(_ id: String) {
        do { try openChrome(for: id, url: URL(string: "https://chatgpt.com/codex/settings/usage")!) }
        catch { banner = safeError(error) }
    }
    private var canMigrateCredentials: Bool {
        !usesFileCredentials && !migratingCredentials && launchingDesktop.isEmpty && loginSlotID == nil && canConnect
    }
    func enableFileCredentials() {
        guard canMigrateCredentials else { return }
        let alert = NSAlert()
        alert.messageText = "改用本机文件保存登录？"
        alert.informativeText = "自动路由需要这个模式。登录凭据保存在本机私有目录的 auth.json，与 Codex 默认方式一致；文件不加密，同一 macOS 用户下的程序可能读取。原钥匙串记录保留。"
        alert.addButton(withTitle: "同意并迁移")
        alert.addButton(withTitle: "保留钥匙串")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await migrateCredentialsToFiles() }
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
            try sharedDesktop.migrateToFiles(accounts: saved.accounts, legacy: accountDesktop)
            for slot in saved.accounts { resumeCollector(slot.id) }
            banner = "已改用本地文件保存登录，原钥匙串记录保留。当前 Codex 未重启。"
            return true
        } catch {
            banner = "迁移未完成，仍使用原存储。" + ((error as? DesktopSwitchFailure)?.localizedDescription ?? "请检查钥匙串授权或文件权限后重试。")
            return false
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
            Task { await migrateCredentialsToFiles() }
        case .desktopLogin:
            if !installerLoginHinted { installerLoginHinted = true; banner = "登录 Codex 桌面后，管家会自动连接这个账号并开启路由。" }
        case .desktopAccount:
            connectDesktopAccount()
        case .ready:
            installerSetup = false
            // The installer asked for routing, so it also overrides an earlier "off".
            if !gatewayEnabled { setGatewayEnabled(true) }
            if gatewayEnabled {
                banner = "自动路由已设置好。重启一次 Codex，已打开的会话也会经过路由。"
                record("安装程序完成了自动路由设置。")
            }
        }
    }
    /// An account-name click: with routing on it orders new conversations; otherwise offer to turn routing on.
    func chooseAccount(_ id: String) {
        guard !preview, let selected = slot(id), selected.expectedAccountID != nil else { return }
        if !gatewayEnabled && routingSetup != .ready {
            banner = "先完成自动路由的设置：" + (routingSetup == .fileStorage ? "改用本机文件存储" : "连接 Codex 桌面正在登录的账号"); return
        }
        if !gatewayEnabled {
            let alert = NSAlert(); alert.messageText = "开启自动账号路由？"
            alert.informativeText = "开启后新会话优先使用 \(selected.displayName)，额度用完自动换其他账号。已打开的会话需重启 Codex 后才经过路由。"
            alert.addButton(withTitle: "开启路由"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            setGatewayEnabled(true)
            guard gatewayEnabled else { return }
        }
        selectGatewayAccount(id)
        gatewayCaption = "新会话优先使用 \(selected.displayName)"
    }
    func accountActionLabel(_ id: String) -> String {
        guard gatewayEnabled else { return "开启自动路由并设为新会话优先…" }
        return gatewayPreferred == id ? "新会话优先使用此账号" : "设为新会话优先"
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
                banner = "绑定的 Chrome Profile 已不存在，请在账号设置里重新选择。"; throw ClientFailure.fileAccess
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
            return [.init(id: "dedicated", name: "新建此账号专用窗口")]
        }
        return cache.sorted { $0.key < $1.key }.map { ChromeProfile(id: $0.key, name: $0.value["name"] as? String ?? $0.key) } + [.init(id: "dedicated", name: "新建此账号专用窗口")]
    }
    func profileCaption(_ slot: AccountSlot) -> String? {
        guard slot.chromeProfile != "dedicated", let profile = profiles.first(where: { $0.id == slot.chromeProfile }) else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    func profileName(_ id: String) -> String { profiles.first { $0.id == id }?.name ?? "Profile 不可用" }
    private func safeError(_ error: Error) -> String { (error as? ClientFailure)?.localizedDescription ?? "操作暂未完成，请检查网络、Chrome 或钥匙串权限后重试。" }
    private func persist() {
        guard persistenceEnabled, !preview else { return }
        do {
            let url = root.appendingPathComponent("state.json")
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { banner = "本次数据未能保存到磁盘，请检查权限和可用空间。当前窗口仍保留数据。" }
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
            let content = UNMutableNotificationContent(); content.title = "Codex Accounts Beta"; content.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(key)", content: content, trigger: nil))
        }
    }
    private func evaluateReminders(id: String, previous: Snapshot?, current: Snapshot) {
        let name = slot(id)?.displayName ?? "账号", now = Date()
        for (bucketID, bucket) in current.rates.buckets {
            for (position, window) in [bucket.primary, bucket.secondary].enumerated() {
                guard let window, let reset = window.resetsAt, let remaining = window.remaining else { continue }
                let seconds = reset - now.timeIntervalSince1970
                if seconds > 0, seconds <= 12 * 3600, remaining >= 30 {
                    remind(id, key: "soon-\(bucketID)-\(position)-\(reset)", text: "\(name) 的\(window.label)还剩 \(Int(remaining))%，\(Presentation.countdown(window.resetDate))重置。")
                }
                if let oldBucket = previous?.rates.buckets.first(where: { $0.0 == bucketID })?.1,
                   let old = [oldBucket.primary, oldBucket.secondary][position], let oldRemaining = old.remaining,
                   remaining >= oldRemaining + 10 {
                    remind(id, key: "restored-\(bucketID)-\(position)-\(reset)-\(Int(remaining))", text: "\(name) 的\(window.label)已更新，当前剩余 \(Int(remaining))%。")
                }
            }
        }
        for credit in current.rates.rateLimitResetCredits?.credits ?? [] where credit.status == "available" {
            if let expires = credit.expiresAt, expires > now.timeIntervalSince1970, expires - now.timeIntervalSince1970 <= 48 * 3600 {
                remind(id, key: "expiry-\(credit.id)", text: "\(name) 有 banked reset 即将到期：\(Presentation.countdown(Date(timeIntervalSince1970: expires)))。")
            }
        }
    }
    private var resetMonitorURL: URL { root.appendingPathComponent("reset-monitor.json") }
    private var personalXURL: URL { root.appendingPathComponent("personal-x-monitor.json") }
    private func loadPersonalX() {
        guard persistenceEnabled else { personalXStorageAvailable = false; return }
        guard FileManager.default.fileExists(atPath: personalXURL.path) else { return }
        do { personalX = try JSONDecoder().decode(PersonalXState.self, from: Data(contentsOf: personalXURL)) }
        catch { personalXStorageAvailable = false; personalX.lastError = "X 监控记录无法读取，已暂停并保留原文件。" }
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
        if personalXTesting { return "正在测试个人 X 登录态…" }
        guard let checked = personalX.lastCheckedAt else { return resetMonitor.enabled ? "等待首次登录与测试；当前使用第三方公告源。" : "尚未连接个人 X；公告监控已关闭。" }
        let status = personalX.enabled ? "已连接个人 X" : "个人 X 监控已关闭"
        return status + " · 读到 \(personalX.lastPosts.count) 条 · " + checked.formatted(date: .omitted, time: .shortened)
            + (personalX.possibleGap ? " · 中间可能有漏帖，请核对主页" : "")
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
                self.record("个人 X 监控已连接；每分钟检查 Tibo，新公告触发所有账号余量查询。")
            } catch is CancellationError { }
            catch { self.personalX.lastError = (error as? PersonalXError ?? .unavailable).localizedDescription; self.savePersonalX() }
        }
    }
    private func acceptPersonalXPosts(_ posts: [XVisiblePost], now: Date) throws {
        var updated = personalX
        let feed = updated.ingest(posts, now: now)
        let signals = try resetMonitor.ingest(feed, accountIDs: saved.accounts.map(\.id), now: now)
        // Persist refresh work before advancing the X deduplication state. A crash may repeat a quota read, never lose a signal.
        saveResetMonitor()
        guard resetStorageAvailable else { throw PersonalXError.storage }
        personalX = updated
        guard savePersonalX() else { throw PersonalXError.storage }
        if let signal = signals.last {
            resetNextAttempt.removeAll()
            record("个人 X 发现 Tibo \(signal.label)，刷新所有账号。原帖：\(signal.originalURL!.absoluteString)")
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
            resetMonitor.lastError = "公告监控记录无法读取，已停止监控以保留原记录。"
        }
    }
    private func saveResetMonitor() {
        guard !preview, persistenceEnabled, resetStorageAvailable else { return }
        do {
            try JSONEncoder().encode(resetMonitor).write(to: resetMonitorURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resetMonitorURL.path)
        } catch {
            resetStorageAvailable = false; resetMonitor.enabled = false
            resetMonitor.lastError = "公告监控记录无法保存，已停止监控；账号同步继续。"
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
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reset-" + signal.key, content: content, trigger: nil))
    }
    /// A planned reset the user can still act on; shown on the widget and dashboard until it passes.
    var resetAlert: (text: String, url: URL)? {
        guard resetMonitor.enabled, let post = resetMonitor.lastAnnouncement, post.isUpcoming(at: now),
              let timing = post.timing, let url = post.originalURL else { return nil }
        return ("Tibo 预告" + timing.describe(now: now) + " · 抓紧用", url)
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
        if !resetMonitor.enabled { return "已关闭" }
        if personalXTesting { return "正在连接 X…" }
        if let error = resetMonitor.lastError ?? (personalX.enabled ? personalX.lastError : nil) { return error }
        if checkingResetAnnouncements { return "正在检查…" }
        let source = personalX.enabled ? "已连接 X · 每分钟检查" : "未登录 X · 公共源" + (resetMonitor.sourceStale ? "有延迟" : "")
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
                    let posts = try await self.personalXBrowser.readTimeline(reload: true)
                    try Task.checkCancellation()
                    guard self.resetMonitor.enabled, self.resetCheckGeneration == generation else { return }
                    try self.acceptPersonalXPosts(posts, now: Date())
                    self.resetCheckFailures = 0
                    return
                }
                let feed = try await ResetAnnouncementAPI.fetch()
                try Task.checkCancellation()
                guard self.resetMonitor.enabled, self.resetCheckGeneration == generation else { return }
                let signals = try self.resetMonitor.ingest(feed, accountIDs: self.saved.accounts.map(\.id), now: Date())
                self.resetCheckFailures = 0
                self.saveResetMonitor()
                if let signal = signals.last, self.resetStorageAvailable {
                    self.resetNextAttempt.removeAll()
                    self.record("检测到 Tibo \(signal.label)，开始刷新全部账号。原帖：\(signal.originalURL!.absoluteString)")
                    self.notifyReset(signal)
                    self.retryResetRefresh()
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.resetCheckGeneration == generation else { return }
                self.resetCheckFailures += 1
                let base: Double = self.personalX.enabled ? 60 : 300
                self.nextResetCheck = Date().addingTimeInterval(min(1800, base * pow(2, Double(min(self.resetCheckFailures - 1, 5)))))
                if self.personalX.enabled {
                    self.personalX.lastError = (error as? PersonalXError ?? .unavailable).localizedDescription
                    self.savePersonalX()
                    self.resetMonitor.lastError = self.personalX.lastError
                } else { self.resetMonitor.lastError = "公告检查失败，将自动重试；账号额度仍正常同步。" }
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
            if !granted { self.banner = "系统通知未开启，重要变化仍会显示在管家的最近动态里。" }
            self.persist()
        } }
    }
    func setLoginAtLaunch(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginAtLaunch = SMAppService.mainApp.status == .enabled
            if enabled && !loginAtLaunch { banner = "请在系统设置的登录项中允许 Codex Accounts Beta。" }
        } catch { banner = "登录时启动未设置成功，可在系统设置 → 通用 → 登录项中添加账号管家。" }
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
        banner = "界面预览 · 以下是模拟数据，不代表你的真实账号额度。"
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
        status[saved.accounts[2].id] = .failure("网络暂时不可用；显示的是上次同步数据。")
    }
}
