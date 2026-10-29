import Foundation
import CryptoKit
import Darwin

public enum PrivateAtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw DesktopSwitchFailure.persistence }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".account-switch-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DesktopSwitchFailure.persistence }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw DesktopSwitchFailure.persistence }
    }
}

public enum DesktopSwitchFailure: LocalizedError {
    case unsupportedStorage, identity, changed, persistence, recovery, activeWindows, busy, launch
    case otherProcesses([Int32]), processInspection, collectorsBusy, collectorStop, desktopStillRunning, authLocked
    public var errorDescription: String? {
        switch self {
        case .unsupportedStorage: return "当前 Codex 登录存储配置尚未适配，未修改登录。"
        case .identity: return "登录凭据与所选账号不符，未切换。"
        case .changed: return "切换期间登录状态发生变化，已停止以保护当前账号。"
        case .persistence: return "登录备份或保存失败，未完成切换。"
        case .recovery: return "上次切换未完成。请退出 Codex 后重试，将先恢复切换前的登录。"
        case .activeWindows: return "请先退出此前打开的独立账号 Codex 实例，再切换主窗口。"
        case .busy: return "仍有采集或登录操作进行中，请稍后再试。"
        case .otherProcesses(let pids): return "另有 Codex 后台进程正在运行（PID：\(pids.map(String.init).joined(separator: "、"))）。请先结束对应终端或任务，再切换账号；管家不会强制关闭它们。"
        case .processInspection: return "无法检查 Codex 后台进程，未退出桌面应用或修改登录。"
        case .collectorsBusy: return "额度或用量查询尚未结束，本次未退出 Codex。请等待同步结束后重试。"
        case .collectorStop: return "管家的采集进程未能退出，本次未退出 Codex。请重新打开管家后重试。"
        case .desktopStillRunning: return "Codex 尚未完全退出，登录未修改。请处理其退出提示后重试。"
        case .authLocked: return "登录文件正在被其他操作使用，未修改登录。请结束该操作后重试。"
        case .launch: return "Codex 未能重新启动，已尝试恢复切换前的登录。"
        }
    }
}

/// Process metadata only: never read arguments, environment, or credential values.
public struct DesktopSwitchProcess {
    public let pid: Int32
    public let parent: Int32
    public let executable: String
    public static func parse(_ text: String) throws -> [DesktopSwitchProcess] {
        try text.split(separator: "\n").map { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), pid > 0, parent >= 0 else {
                throw DesktopSwitchFailure.processInspection
            }
            return Self(pid: pid, parent: parent, executable: String(fields[2]))
        }
    }
    public static func blockers(in processes: [DesktopSwitchProcess], allowedRoots: Set<Int32>) -> [Int32] {
        let parents = Dictionary(processes.map { ($0.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
        return processes.filter { process in
            guard ["codex", "codex-app-server"].contains(URL(fileURLWithPath: process.executable).lastPathComponent) else { return false }
            var current = process.pid, seen = Set<Int32>()
            while current > 0, seen.insert(current).inserted {
                if allowedRoots.contains(current) { return false }
                guard let parent = parents[current] else { break }
                current = parent
            }
            return true
        }.map(\.pid).sorted()
    }
}

/// Treat the payload as a secret: never print, interpolate or encode it into public state.
public struct DesktopCredential {
    public let data: Data
    public let accountID: String
    public init(_ data: Data, expected: String? = nil) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any],
              let id = tokens["account_id"] as? String, !id.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              expected == nil || id == expected else { throw DesktopSwitchFailure.identity }
        self.data = data; accountID = id
    }
}

/// This first shared-desktop adapter deliberately supports only the default file store.
/// It never rewrites configuration, sessions, databases, projects or Electron user data.
public struct SharedDesktopPlan {
    public let home: URL
    public var auth: URL { home.appendingPathComponent("auth.json") }
    public init(home: URL) throws {
        guard home.isFileURL else { throw DesktopSwitchFailure.unsupportedStorage }
        self.home = home.standardizedFileURL
        for url in [home, home.appendingPathComponent("auth.json"), home.appendingPathComponent("config.toml")] {
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw DesktopSwitchFailure.unsupportedStorage }
        }
    }
    public func validateConfiguration(_ text: String) throws {
        // Conservative parser: unfamiliar declarations affecting authentication fail closed.
        // Do not infer a mode from an auth.json that might be an obsolete fallback.
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.contains("cli_auth_credentials_store") {
                guard line.range(of: #"^cli_auth_credentials_store\s*=\s*["']file["']\s*(#.*)?$"#, options: .regularExpression) != nil else { throw DesktopSwitchFailure.unsupportedStorage }
            }
            if ["forced_login_method", "forced_chatgpt_workspace_id", "auth_keyring_backend", "chatgpt_base_url"].contains(where: line.contains) {
                throw DesktopSwitchFailure.unsupportedStorage
            }
        }
    }
    public static func keyringAccount(home: URL) -> String {
        let digest = SHA256.hash(data: Data(home.resolvingSymlinksInPath().path.utf8))
        return "cli|" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }
}

public struct DesktopSelection: Codable, Equatable {
    public let slotID: String
    public let accountID: String
    public init(slotID: String, accountID: String) { self.slotID = slotID; self.accountID = accountID }
    /// selection.json is only a receipt: a login inside Codex makes it stale. The live desktop
    /// login decides which slot owns the shared home; the receipt only breaks ties between slots.
    public static func live(desktopAccountID: String?, receipt: DesktopSelection?, accounts: [AccountSlot]) -> DesktopSelection? {
        guard let desktopAccountID, !desktopAccountID.isEmpty else { return nil }
        let matches = accounts.filter { $0.expectedAccountID == desktopAccountID }
        guard let slot = matches.first(where: { $0.id == receipt?.slotID }) ?? matches.first else { return nil }
        return DesktopSelection(slotID: slot.id, accountID: desktopAccountID)
    }
}

/// Injected ports allow crash/failure tests without reading any real credentials or apps.
@MainActor public struct DesktopSwitchPorts {
    public var readDesktop: () throws -> Data
    public var writeDesktop: (Data) throws -> Void
    public var saveRollback: (Data) throws -> Void
    public var loadRollback: () throws -> Data
    public var saveOutgoing: (DesktopCredential) throws -> Void
    public var saveSelection: (DesktopSelection?) throws -> Void
    public var setPending: (Bool) throws -> Void
    public var isDesktopStopped: () -> Bool
    public var launch: () async throws -> Void
    public init(readDesktop: @escaping () throws -> Data, writeDesktop: @escaping (Data) throws -> Void,
                saveRollback: @escaping (Data) throws -> Void, loadRollback: @escaping () throws -> Data,
                saveOutgoing: @escaping (DesktopCredential) throws -> Void,
                saveSelection: @escaping (DesktopSelection?) throws -> Void, setPending: @escaping (Bool) throws -> Void,
                isDesktopStopped: @escaping () -> Bool, launch: @escaping () async throws -> Void) {
        self.readDesktop = readDesktop; self.writeDesktop = writeDesktop
        self.saveRollback = saveRollback; self.loadRollback = loadRollback; self.saveOutgoing = saveOutgoing
        self.saveSelection = saveSelection; self.setPending = setPending
        self.isDesktopStopped = isDesktopStopped; self.launch = launch
    }
}

public struct DesktopRollback: Codable {
    public let auth: Data
    public let selection: DesktopSelection?
    public init(auth: Data, selection: DesktopSelection?) { self.auth = auth; self.selection = selection }
}

@MainActor public enum DesktopSwitchTransaction {
    public static func run(target: DesktopCredential, selection: DesktopSelection, previous: DesktopSelection?, ports p: DesktopSwitchPorts) async throws {
        guard target.accountID == selection.accountID else { throw DesktopSwitchFailure.identity }
        guard p.isDesktopStopped() else { throw DesktopSwitchFailure.busy }
        let before = try p.readDesktop()
        let outgoing = try DesktopCredential(before, expected: previous?.accountID)
        try p.saveOutgoing(outgoing)
        let backup = try JSONEncoder().encode(DesktopRollback(auth: before, selection: previous))
        try p.saveRollback(backup)
        guard try p.loadRollback() == backup else { throw DesktopSwitchFailure.persistence }
        try p.setPending(true)
        var wrote = false
        do {
            guard p.isDesktopStopped(), try p.readDesktop() == before else { throw DesktopSwitchFailure.changed }
            // writeDesktop is atomic. Set wrote first to handle a write that throws after rename.
            wrote = true
            try p.writeDesktop(target.data)
            guard try p.readDesktop() == target.data else { throw DesktopSwitchFailure.persistence }
            try p.saveSelection(selection)
            try await p.launch()
            try p.setPending(false)
        } catch {
            // Never roll back under a running process; leave the durable recovery marker instead.
            if wrote {
                guard p.isDesktopStopped() else { throw DesktopSwitchFailure.recovery }
                try p.writeDesktop(before)
                try p.saveSelection(previous)
            }
            try p.setPending(false)
            throw error
        }
    }
    public static func recover(ports p: DesktopSwitchPorts) throws {
        guard p.isDesktopStopped() else { throw DesktopSwitchFailure.recovery }
        let backup = try JSONDecoder().decode(DesktopRollback.self, from: p.loadRollback())
        _ = try DesktopCredential(backup.auth)
        try p.writeDesktop(backup.auth)
        guard try p.readDesktop() == backup.auth else { throw DesktopSwitchFailure.persistence }
        try p.saveSelection(backup.selection)
        try p.setPending(false)
    }
}
