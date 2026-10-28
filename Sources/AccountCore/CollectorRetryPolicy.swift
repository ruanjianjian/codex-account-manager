import Foundation

/// Durable, per-account stop for failures that can hide an unanswered Keychain prompt.
/// Only an explicit account action clears it; global refresh and wake must respect it.
public struct CollectorRetryPolicy {
    public private(set) var paused: Set<String>
    public init(paused: Set<String> = []) { self.paused = paused }
    public mutating func record(_ error: Error, account: String, usesKeyring: Bool) -> Bool {
        guard usesKeyring else { return false }
        switch error {
        case ClientFailure.keychainAccess, ClientFailure.timeout:
            paused.insert(account); return true
        default: return false
        }
    }
    public mutating func resume(_ account: String) { paused.remove(account) }
    public static let message = "钥匙串访问未完成或查询超时，已暂停自动同步。旧数据保留；请从此账号菜单点“刷新”手动重试。"
}
