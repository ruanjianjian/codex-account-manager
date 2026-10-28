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
    @Published var banner: String?
    @Published var now = Date()
    @Published var profiles: [ChromeProfile] = []
    @Published var loginAtLaunch = false
    @Published var desktopVisible = UserDefaults.standard.object(forKey: "desktop.visible") as? Bool ?? true
    @Published var desktopPinned = UserDefaults.standard.bool(forKey: "desktop.pinned")
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
    @Published var deepSeekHasKey = false
    @Published var deepSeekTesting = false
    @Published var deepSeekResult: DeepSeekProbeResult?
    @Published var deepSeekError: String?
    private var deepSeekKey = "" // Session only; never encoded, logged or read from Keychain.
    private var deepSeekTask: Task<Void, Never>?
    private var deepSeekGeneration = UUID()
    private var resetCheckTask: Task<Void, Never>?
    private var nextResetCheck = Date.distantPast
    private var resetCheckFailures = 0
    private var resetCheckGeneration = UUID()
    private var resetNextAttempt: [String: Date] = [:]
    private var resetRefreshBusy = false
    private var resetStorageAvailable = true
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
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccountsPublic" + (preview ? "-Preview" : ""))
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
        for slot in saved.accounts { status[slot.id] = .disconnected }
        if preview { loadPreview(); return }
        loadResetMonitor()
        loadPersonalX()
        checkResetAnnouncements()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.nextPoll.removeAll(); self?.refreshAll(); self?.checkResetAnnouncements(force: true)
        } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } })
        Task { await refreshSequentially() }
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
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ClientFailure.missingBinary }
        return URL(fileURLWithPath: path)
    }
    private func client(_ id: String) throws -> RPCClient {
        if let client = clients[id] { return client }
        let client = RPCClient(home: root.appendingPathComponent("accounts/\(id)"), executable: try Self.binary())
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
        guard !preview, persistenceEnabled, index(id) != nil, loginSlotID != id, !usageLoading.contains(id) else { return }
        if !force, let next = nextUsagePoll[id], next > Date() { return }
        usageLoading.insert(id); defer { usageLoading.remove(id) }
        nextUsagePoll[id] = Date().addingTimeInterval(300)
        do {
            let response = try decode(TokenUsageResponse.self, await client(id).request("account/usage/read"))
            guard let i = index(id), loginSlotID != id else { return }
            saved.accounts[i].tokenUsage = TokenUsageSnapshot(response: response)
            usageErrors.removeValue(forKey: id); persist()
        } catch {
            guard index(id) != nil else { return }
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
    func refresh(_ id: String) { Task { await sync(id, force: true) } }
    private func refreshSequentially(force: Bool = false) async {
        for slot in saved.accounts { await sync(slot.id, force: force) }
    }
    private func sync(_ id: String, force: Bool = false) async {
        guard persistenceEnabled, !preview, !busy.contains(id), loginSlotID != id, index(id) != nil else { return }
        if case .wrongAccount = status[id] { return }
        if !force, let next = nextPoll[id], next > Date() { return }
        let syncStartedAt = Date()
        busy.insert(id); status[id] = .checking; onChange?()
        defer { busy.remove(id); onChange?() }
        do {
            let client = try client(id)
            let identityResult = try decode(AccountRead.self, await client.request("account/read", params: ["refreshToken": false]))
            guard let i = index(id) else { return }
            guard let identity = identityResult.account, identity.type == "chatgpt" else {
                status[id] = saved.accounts[i].expectedEmail == nil ? .disconnected : .needsAuth
                nextPoll[id] = .distantFuture
                client.stop(); return
            }
            let rates = try decode(RateResponse.self, await client.request("account/rateLimits/read"))
            guard let i = index(id) else { return }
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
            let isAuth: Bool = { if case ClientFailure.authentication = error { return true }; return false }()
            status[id] = isAuth ? .needsAuth : .failure(safeError(error))
            let count = min((failures[id] ?? 0) + 1, 4); failures[id] = count
            nextPoll[id] = Date().addingTimeInterval(min(1800, 60 * pow(2, Double(count - 1))) + Double.random(in: 0...25))
        }
    }
    private func tick() {
        now = Date(); onChange?()
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
        guard canConnect, index(id) != nil else { return false }
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
        guard loginSlotID == nil, canConnect, !busy.contains(id), !usageLoading.contains(id), index(id) != nil else { return }
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
                status[id] = .failure("登录未完成，请重新连接。已有账号不会退出。")
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
        guard canConnect, loginSlotID == nil, profiles.contains(where: { $0.id == profile }) else { return }
        let id = "account-" + UUID().uuidString.lowercased()
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var slot = AccountSlot(id: id, name: "新账号", chromeProfile: profile)
        slot.nameOverride = clean.isEmpty ? nil : String(clean.prefix(128))
        saved.accounts.append(slot); status[id] = .disconnected; persist(); onChange?(); onDesktopChange?()
        connect(id)
    }
    func disconnect(_ id: String) async {
        guard canConnect, index(id) != nil, !busy.contains(id), !usageLoading.contains(id), loginSlotID == nil else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            _ = try await client(id).request("account/logout", timeout: 15)
            clients[id]?.stop(); clients.removeValue(forKey: id)
            usageErrors.removeValue(forKey: id); nextUsagePoll.removeValue(forKey: id)
            guard let i = index(id) else { return }
            let slot = saved.accounts[i]
            saved.accounts.remove(at: i)
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
        guard let checked = personalX.lastCheckedAt else { return "等待首次登录与测试；当前仍使用第三方公告源。" }
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
    func setResetMonitoring(_ enabled: Bool) {
        guard !preview, resetStorageAvailable else { return }
        resetMonitor.enabled = enabled; saveResetMonitor()
        if enabled { checkResetAnnouncements(force: true) }
        else { resetCheckGeneration = UUID(); resetCheckTask?.cancel(); resetCheckTask = nil; checkingResetAnnouncements = false }
    }
    var resetMonitorCaption: String {
        if !resetMonitor.enabled { return "已关闭" }
        if let error = resetMonitor.lastError { return error }
        if personalX.enabled { return personalXCaption }
        if checkingResetAnnouncements { return "正在检查公告…" }
        guard let checked = resetMonitor.lastCheckedAt else { return "等待首次检查" }
        let status = resetMonitor.sourceStale ? "公告源有延迟" : "监控中"
        return status + " · 上次检查 " + checked.formatted(date: .omitted, time: .shortened)
    }
    var resetRefreshCaption: String? {
        guard let post = resetMonitor.lastAnnouncement else { return nil }
        let result = "已刷新 \(resetMonitor.refreshedAccountIDs.count)/\(resetMonitor.targetCount) 个账号"
        let tail = resetMonitor.pendingAccountIDs.isEmpty ? "" : (resetMonitor.canRetry(at: now) ? " · 其余重试中" : " · 其余待正常同步或重新登录")
        return post.label + " · " + result + tail
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
    func testDeepSeek(key input: String, referenceURL: String) {
        guard !preview, !deepSeekTesting else { return }
        do {
            let key = try DeepSeekProbe.validatedKey(input.isEmpty ? deepSeekKey : input)
            let reference = referenceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reference.isEmpty || TiboPostLink.parse(reference) != nil else { throw DeepSeekProbeError.invalidPostURL }
            deepSeekKey = key; deepSeekHasKey = true
            deepSeekError = nil; deepSeekResult = nil; deepSeekTesting = true
            let generation = UUID(); deepSeekGeneration = generation
            deepSeekTask = Task { [weak self] in
                do {
                    let result = try await DeepSeekProbe.run(key: key, referenceURL: reference)
                    guard let self, self.deepSeekGeneration == generation else { return }
                    self.deepSeekResult = result
                    // Only public results, with credentials redacted, are retained for diagnosis.
                    do {
                        let file = self.root.appendingPathComponent("deepseek-test-result.json")
                        try JSONEncoder().encode(result).write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    } catch { self.deepSeekError = "抓取完成，但未能保存本机测试结果。" }
                } catch is CancellationError { }
                catch {
                    guard let self, self.deepSeekGeneration == generation else { return }
                    self.deepSeekError = (error as? DeepSeekProbeError ?? .network).localizedDescription
                }
                guard let self, self.deepSeekGeneration == generation else { return }
                self.deepSeekTesting = false; self.deepSeekTask = nil
            }
        } catch { deepSeekError = (error as? DeepSeekProbeError ?? .network).localizedDescription }
    }
    func cancelDeepSeekTest() {
        deepSeekGeneration = UUID(); deepSeekTask?.cancel(); deepSeekTask = nil; deepSeekTesting = false
    }
    func clearDeepSeekKey() {
        cancelDeepSeekTest(); deepSeekKey = ""; deepSeekHasKey = false; deepSeekError = nil
    }
    func shutdown() {
        personalXTask?.cancel(); xBrowser?.stop()
        clearDeepSeekKey()
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
        saved.accounts[2].snapshot?.fetchedAt = Date().addingTimeInterval(-3600)
        status[saved.accounts[2].id] = .failure("网络暂时不可用；显示的是上次同步数据。")
    }
}
