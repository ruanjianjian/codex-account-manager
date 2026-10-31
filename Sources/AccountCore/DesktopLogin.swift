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
    case unsupportedStorage, identity, persistence, busy, collectorsBusy, collectorStop
    public var errorDescription: String? {
        switch self {
        case .unsupportedStorage: return L("当前 Codex 登录存储配置尚未适配，未修改登录。", "This Codex login storage setup is not supported yet; the login was left unchanged.")
        case .identity: return L("登录凭据与所选账号不符。", "The login does not match the selected account.")
        case .persistence: return L("登录备份或保存失败。", "Could not back up or save the login.")
        case .busy: return L("仍有采集或登录操作进行中，请稍后再试。", "A sync or login is still running. Try again in a moment.")
        case .collectorsBusy: return L("额度或用量查询尚未结束，请等待同步结束后重试。", "Quota or usage is still syncing. Try again when it finishes.")
        case .collectorStop: return L("Tibot 的采集进程未能退出，请重新打开 Tibot 后重试。", "Tibot's sync process did not quit. Reopen Tibot and try again.")
        }
    }
}

/// Reads a JWT's payload without verifying it: for display and expiry only, never to authenticate.
public enum JWTClaims {
    public static func decode(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public struct DesktopCredential {
    public let data: Data
    public let accountID: String
    /// From the id_token, to show the user which account this is: the email and the name Codex shows.
    public let email: String?
    public let name: String?
    public init(_ data: Data, expected: String? = nil) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any],
              let id = tokens["account_id"] as? String, !id.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              expected == nil || id == expected else { throw DesktopSwitchFailure.identity }
        self.data = data; accountID = id
        let claims = (tokens["id_token"] as? String).flatMap(JWTClaims.decode)
        email = claims?["email"] as? String
        name = (claims?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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

