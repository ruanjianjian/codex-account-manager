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
}
