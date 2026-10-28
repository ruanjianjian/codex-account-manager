import Foundation

public struct QuotaWindow: Codable, Equatable {
    public var usedPercent: Double?
    public var windowDurationMins: Int?
    public var resetsAt: Double?
    public var remaining: Double? { usedPercent.flatMap { $0.isFinite ? min(100, max(0, 100 - $0)) : nil } }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    public var label: String {
        guard let mins = windowDurationMins else { return "额度窗口" }
        if mins == 10080 { return "每周额度" }
        if mins % 1440 == 0 { return "\(mins / 1440) 天额度" }
        if mins % 60 == 0 { return "\(mins / 60) 小时额度" }
        return "\(mins) 分钟额度"
    }
    public init(usedPercent: Double? = nil, windowDurationMins: Int? = nil, resetsAt: Double? = nil) {
        self.usedPercent = usedPercent; self.windowDurationMins = windowDurationMins; self.resetsAt = resetsAt
    }
}
public struct QuotaBucket: Codable, Equatable {
    public var limitId: String?
    public var limitName: String?
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var planType: String?
    public var rateLimitReachedType: String?
    public var spendControlReached: Bool?
}
public struct ResetCredit: Codable, Equatable, Identifiable {
    public var id: String
    public var status: String?
    public var expiresAt: Double?
    public var title: String?
}
public struct ResetCredits: Codable, Equatable {
    public var availableCount: Int?
    public var credits: [ResetCredit]?
    public var nearestExpiry: Date? {
        credits?.filter { $0.status == "available" }.compactMap { $0.expiresAt }.min().map(Date.init(timeIntervalSince1970:))
    }
}
public struct RateResponse: Codable, Equatable {
    public var accountId: String?
    public var rateLimits: QuotaBucket?
    public var rateLimitsByLimitId: [String: QuotaBucket]?
    public var rateLimitResetCredits: ResetCredits?
    public var ordinaryUsageAllowed: Bool?
    public var buckets: [(String, QuotaBucket)] {
        if let map = rateLimitsByLimitId { return map.sorted { $0.key < $1.key } }
        if let single = rateLimits { return [(single.limitId ?? "codex", single)] }
        return []
    }
    public var windows: [QuotaWindow] { buckets.flatMap { [$0.1.primary, $0.1.secondary].compactMap { $0 } } }
    public var canRecommend: Bool {
        ordinaryUsageAllowed != false && !buckets.isEmpty && !windows.isEmpty &&
        buckets.allSatisfy { $0.1.rateLimitReachedType == nil && $0.1.spendControlReached != true } &&
        windows.allSatisfy { ($0.remaining ?? 0) > 0 }
    }
}
public struct AccountIdentity: Codable, Equatable {
    public var type: String
    public var email: String?
    public var planType: String?
}
public struct AccountRead: Codable { public var account: AccountIdentity? }
public struct Snapshot: Codable, Equatable {
    public var fetchedAt: Date
    public var identity: AccountIdentity
    public var rates: RateResponse
    public init(fetchedAt: Date = Date(), identity: AccountIdentity, rates: RateResponse) {
        self.fetchedAt = fetchedAt; self.identity = identity; self.rates = rates
    }
    public func isFresh(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < 180 && now >= fetchedAt.addingTimeInterval(-60) &&
        !rates.windows.contains { ($0.resetDate ?? .distantFuture) <= now }
    }
}
public struct AccountSlot: Codable, Identifiable {
    public var id: String
    public var name: String
    public var codexName: String?
    public var nameOverride: String?
    public var displayName: String {
        if let value = nameOverride, !value.isEmpty { return value }
        if let value = codexName, !value.isEmpty { return value }
        if let email = snapshot?.identity.email ?? expectedEmail { return Presentation.maskedEmail(email) }
        return name
    }
    public var chromeProfile: String // "dedicated" or Chrome's directory name
    public var expectedEmail: String?
    public var expectedAccountID: String?
    public var snapshot: Snapshot?
    public var tokenUsage: TokenUsageSnapshot?
    public var reminderKeys: [String]
    public init(id: String, name: String, chromeProfile: String) {
        self.id = id; self.name = name; self.chromeProfile = chromeProfile; reminderKeys = []
    }
    public static func validID(_ id: String) -> Bool {
        id.range(of: "^account-[a-zA-Z0-9-]{1,80}$", options: .regularExpression) != nil
    }
    public static var defaults: [AccountSlot] { [
        .init(id: "account-1", name: "示例账号 1", chromeProfile: "dedicated"),
        .init(id: "account-2", name: "示例账号 2", chromeProfile: "dedicated"),
        .init(id: "account-3", name: "示例账号 3", chromeProfile: "dedicated"),
        .init(id: "account-4", name: "示例账号 4", chromeProfile: "dedicated"),
        .init(id: "account-5", name: "账号 5", chromeProfile: "dedicated"),
        .init(id: "account-6", name: "账号 6", chromeProfile: "dedicated")
    ] }
}
public struct ActivityEntry: Codable, Identifiable {
    public var id: UUID
    public var time: Date
    public var text: String
    public init(_ text: String) { id = UUID(); time = Date(); self.text = text }
}
public struct SavedState: Codable {
    public var version: Int = 3
    public var accounts: [AccountSlot]
    public var events: [ActivityEntry] = []
    public var notificationsEnabled = false
    public init(accounts: [AccountSlot] = []) { self.accounts = accounts }
    public func migrated() throws -> SavedState {
        let ids = accounts.map(\.id)
        guard [1, 2, 3].contains(version), Set(ids).count == ids.count,
              ids.allSatisfy(AccountSlot.validID) else { throw ClientFailure.invalidResponse }
        if version < 3 && !Set(ids).isSubset(of: Set(AccountSlot.defaults.map(\.id))) { throw ClientFailure.invalidResponse }
        var updated = self; updated.version = 3
        return updated
    }
}
public enum IdentityCheck: Equatable {
    case valid, changed, duplicate(String), unverifiable
    public static func evaluate(slot: AccountSlot, identity: AccountIdentity, accountID: String?, others: [AccountSlot]) -> IdentityCheck {
        let email = identity.email?.lowercased()
        if let expected = slot.expectedEmail, email != expected.lowercased() { return .changed }
        if let expected = slot.expectedAccountID, let actual = accountID, expected != actual { return .changed }
        guard email != nil || accountID != nil else { return .unverifiable }
        for other in others where other.id != slot.id {
            if let email, let otherEmail = other.expectedEmail, email == otherEmail.lowercased() { return .duplicate(other.displayName) }
            if let accountID, let otherID = other.expectedAccountID, accountID == otherID { return .duplicate(other.displayName) }
        }
        return .valid
    }
}
public enum Presentation {
    public static func maskedEmail(_ email: String?) -> String {
        guard let email, let at = email.firstIndex(of: "@") else { return "已验证账号" }
        return "\(email[..<at].prefix(2))•••\(email[at...])"
    }
    public static func countdown(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "重置时间未知" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "已到重置时间 · 待同步" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分后" }
        return "\(minutes) 分钟后"
    }
    public static func recommendation(_ slots: [AccountSlot], healthy: Set<String>, now: Date = Date()) -> String? {
        let candidates = slots.filter { healthy.contains($0.id) && $0.snapshot?.isFresh(at: now) == true && $0.snapshot?.rates.canRecommend == true }
        let ranked = candidates.compactMap { slot -> (AccountSlot, QuotaWindow)? in
            guard let window = slot.snapshot?.rates.windows.filter({ $0.resetDate != nil && $0.remaining != nil }).min(by: { $0.resetDate! < $1.resetDate! }) else { return nil }
            return (slot, window)
        }.sorted { $0.1.resetDate! < $1.1.resetDate! }
        guard let first = ranked.first else { return nil }
        return "优先考虑 \(first.0.displayName) · \(first.1.label)剩余 \(Int(first.1.remaining!))%，\(countdown(first.1.resetDate, now: now))重置"
    }
}
