import Foundation

/// Before it sends a message, Codex asks the service about the account it is signed in to, and locks the composer
/// when that account is out. The message never reaches routing, so the way out is to sign Codex in to an account
/// that still has quota. Routing spends the quota that resets soonest first, so Codex goes to the account with the
/// most left (the latest reset on a tie): that one keeps Codex unlocked longest.
public enum CodexLoginSwitch {
    public static func target(desktop: RateResponse?, others: [(id: String, rates: RateResponse?)], now: Date = Date()) -> String? {
        // No reading yet is not "out": Codex may well be sending.
        guard let desktop, !BankedResetRule.hasQuota(desktop, now: now) else { return nil }
        let usable = others.compactMap { account in account.rates.flatMap { BankedResetRule.hasQuota($0, now: now) ? (account.id, $0) : nil } }
        return usable.max { (left($0.1), $0.1.windows.quotaReset ?? 0) < (left($1.1), $1.1.windows.quotaReset ?? 0) }?.0
    }
    static func left(_ rates: RateResponse) -> Double { rates.windows.compactMap(\.remaining).min() ?? 0 }

    /// The system notification Tibot posts when Codex's own account runs out. Clicking it, or its button,
    /// switches Codex's login.
    public static let noticeCategory = "codex-login-out"
    public static let noticeAction = "switch"
    public static let noticeFlag = "codexLoginSwitch"
    public static func notice(from: String, to: String) -> (body: String, button: String) {
        (L("Codex 登录的 \(from) 没额度了，新消息发不出去。点这里换到 \(to)，Codex 会重开一次。",
           "\(from), the account Codex is signed in to, is out, so new messages stay unsent. Click to switch Codex to \(to); it reopens once."),
         L("换到 \(to)", "Switch to \(to)"))
    }
    /// One notice per used-up window. The service reports a window's reset a few seconds apart from one reading
    /// to the next, so a reset within the hour of one already noticed is the same window. nil: already noticed.
    public static func noticeKey(reset: Double, noticed keys: [String]) -> String? {
        let prefix = "codex-login-out-"
        let seen = keys.compactMap { $0.hasPrefix(prefix) ? Double($0.dropFirst(prefix.count)) : nil }
        return seen.contains { abs($0 - reset) < 3600 } ? nil : prefix + String(Int(reset))
    }
}
