import Foundation

/// Separate UI storage, shared only with this account's existing official CLI home.
/// Credentials never appear in launch arguments or get copied to another home.
public struct DesktopLaunchPlan {
    public let home: URL
    public let userData: URL
    public let record: URL
    public init(root: URL, accountID: String) throws {
        guard root.isFileURL, AccountSlot.validID(accountID) else { throw DesktopLaunchError.invalidAccount }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        home = base.appendingPathComponent("accounts/\(accountID)")
        userData = base.appendingPathComponent("desktop/\(accountID)/user-data")
        record = base.appendingPathComponent("desktop/\(accountID)/instance.json")
        // Never follow an account or desktop symlink into another user's/global profile.
        for path in [home, userData, record] {
            guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path else { throw DesktopLaunchError.invalidAccount }
        }
    }
    public var arguments: [String] { ["--user-data-dir=\(userData.path)"] }
    @MainActor public func environment(inherited: [String: String]) -> [String: String] {
        var env = RPCClient.isolatedEnvironment(home: home, inherited: inherited)
        env["CODEX_ELECTRON_USER_DATA_PATH"] = userData.path
        return env
    }
}

public enum DesktopLaunchError: LocalizedError {
    case invalidAccount, missingApp, unsupportedApp, failed, persistence
    public var errorDescription: String? {
        switch self {
        case .invalidAccount: return "账号目录异常，未打开 Codex。"
        case .missingApp: return "未找到 Codex 桌面应用。请先安装并启动一次。"
        case .unsupportedApp: return "此 Codex 桌面版本尚未适配账号切换，请查看 README 支持版本。"
        case .failed: return "未能打开 Codex 独立窗口，当前窗口未改变。"
        case .persistence: return "窗口记录未能保存，请先关闭新开的独立窗口再重试。"
        }
    }
}
