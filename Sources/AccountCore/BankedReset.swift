import CryptoKit
import Foundation

/// When Tibot spends a banked reset by itself: only when no account has quota left, and then once, on the
/// account that would wait longest, if its reset is still two days or more away. It uses the credit that expires first.
public enum BankedResetRule {
    public static let minimumWait: TimeInterval = 48 * 3600
    public struct Plan: Equatable {
        /// nil when the service lists only a count; it then picks the next credit itself.
        public var creditID: String?
        public var window: QuotaWindow
        public var idempotencyKey: String
        public var creditsLeft: Int
    }
    public static func pick(_ accounts: [(id: String, rates: RateResponse?)], now: Date = Date()) -> (id: String, plan: Plan)? {
        // An account without a reading may still have quota. A reset being redeemed may not show yet.
        guard !accounts.isEmpty, !accounts.contains(where: { hasQuota($0.rates, now: now) }),
              !accounts.contains(where: { $0.rates?.rateLimitResetCredits?.credits?.contains { $0.status == "redeeming" } == true }) else { return nil }
        return accounts.compactMap { account in account.rates.flatMap { plan(accountID: account.id, rates: $0, now: now) }.map { (account.id, $0) } }
            .max { ($0.1.window.resetsAt ?? 0) < ($1.1.window.resetsAt ?? 0) }
    }
    static func hasQuota(_ rates: RateResponse?, now: Date) -> Bool {
        guard let rates else { return true }
        return !rates.windows.contains { ($0.remaining ?? 100) <= 0 && ($0.resetDate ?? .distantFuture) > now }
    }
    public static func plan(accountID: String, rates: RateResponse, now: Date = Date()) -> Plan? {
        let summary = rates.rateLimitResetCredits
        let credits = summary?.credits ?? []
        // A reset being redeemed still shows the old usage for a moment: never spend a second credit on it.
        guard !credits.contains(where: { $0.status == "redeeming" }) else { return nil }
        let usable = credits.filter { $0.status == "available" && ($0.expiresAt ?? .infinity) > now.timeIntervalSince1970 }
            .sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
        let count = summary?.credits == nil ? summary?.availableCount ?? 0 : usable.count
        guard count > 0 else { return nil }
        let spent = rates.windows.filter { ($0.usedPercent ?? 0) >= 100 && ($0.resetsAt ?? 0) - now.timeIntervalSince1970 >= minimumWait }
        guard let window = spent.max(by: { ($0.resetsAt ?? 0) < ($1.resetsAt ?? 0) }), let reset = window.resetsAt else { return nil }
        return Plan(creditID: usable.first?.id, window: window, idempotencyKey: key(accountID, reset), creditsLeft: count - 1)
    }
    /// The same used-up window always gives the same key, so a retry after a lost reply or a restart
    /// is the same attempt to the service and can never spend a second credit.
    static func key(_ accountID: String, _ reset: Double) -> String {
        var b = Array(SHA256.hash(data: Data("tibot-banked-reset|\(accountID)|\(Int(reset))".utf8)).prefix(16))
        b[6] = b[6] & 0x0f | 0x50; b[8] = b[8] & 0x3f | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString.lowercased()
    }
}
