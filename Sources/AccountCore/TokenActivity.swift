import Foundation

public struct TokenUsageResponse: Codable, Equatable {
    public struct Summary: Codable, Equatable { public var lifetimeTokens: Int64? }
    public struct Bucket: Codable, Equatable {
        public var startDate: String
        public var tokens: Int64
        public init(startDate: String, tokens: Int64) { self.startDate = startDate; self.tokens = tokens }
    }
    public var summary: Summary
    public var dailyUsageBuckets: [Bucket]?
    public init(lifetimeTokens: Int64? = nil, buckets: [Bucket]?) {
        summary = Summary(lifetimeTokens: lifetimeTokens); dailyUsageBuckets = buckets
    }
}
public struct TokenUsageSnapshot: Codable, Equatable {
    public var fetchedAt: Date
    public var response: TokenUsageResponse
    public init(response: TokenUsageResponse, fetchedAt: Date = Date()) { self.response = response; self.fetchedAt = fetchedAt }
}
public struct TokenDay: Identifiable, Equatable {
    public var id: String
    public var tokens: Int64?
    public var reportedAccounts: Int
    public var expectedAccounts: Int
    public var isComplete: Bool { expectedAccounts > 0 && reportedAccounts == expectedAccounts }
}
public enum TokenActivity {
    public static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func recentDates(count: Int, now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return (0..<max(0, count)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map(dateKey)
    }
    /// Every day back to the earliest one any account returned, in whole weeks ending today, oldest first; the last
    /// week is the last 7 days.
    public static func weeks(_ responses: [TokenUsageResponse?], now: Date = Date()) -> [[TokenDay]] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone; parser.dateFormat = "yyyy-MM-dd"
        let earliest = responses.compactMap { $0?.dailyUsageBuckets?.compactMap { parser.date(from: $0.startDate) }.min() }.min()
        let span = earliest.flatMap { calendar.dateComponents([.day], from: $0, to: calendar.startOfDay(for: now)).day } ?? 0
        let days = aggregate(responses, dates: recentDates(count: max(1, (span + 7) / 7) * 7, now: now))
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0 ..< $0 + 7]) }
    }
    /// "近 7 天", "上周", then the week's dates ("10-10 – 10-16").
    public static func weekTitle(_ week: [TokenDay], weeksAgo: Int) -> String {
        switch weeksAgo {
        case 0: return L("近 7 天", "Last 7 days")
        case 1: return L("上周", "Last week")
        default: return "\(week.first?.id.suffix(5) ?? "") – \(week.last?.id.suffix(5) ?? "")"
        }
    }
    // A missing bucket is unknown, never an invented zero. Duplicate dates in a
    // single account response count once; repeated refreshes replace snapshots.
    public static func aggregate(_ responses: [TokenUsageResponse?], dates: [String]) -> [TokenDay] {
        let maps = responses.map { response -> [String: Int64] in
            var map: [String: Int64] = [:]
            for bucket in response?.dailyUsageBuckets ?? [] where bucket.tokens >= 0 {
                guard bucket.startDate.count == 10 else { continue }
                map[bucket.startDate] = bucket.tokens
            }
            return map
        }
        return dates.map { day in
            let values = maps.compactMap { $0[day] }
            let total = values.reduce(Int64(0)) { partial, next in
                let result = partial.addingReportingOverflow(next)
                return result.overflow ? Int64.max : result.partialValue
            }
            return TokenDay(id: day, tokens: values.isEmpty ? nil : total, reportedAccounts: values.count, expectedAccounts: responses.count)
        }
    }
    public static func compact(_ count: Int64) -> String {
        let units: [(Int64, String)] = L10n.chinese ? [(100_000_000, " 亿"), (10_000_000, " 千万"), (1_000_000, " 百万"), (10_000, " 万")]
            : [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        guard let (scale, unit) = units.first(where: { count >= $0.0 }) else { return count.formatted() }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: L10n.chinese ? "zh_CN" : "en_US")
        formatter.maximumFractionDigits = 2; formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return (formatter.string(from: NSNumber(value: Double(count) / Double(scale))) ?? String(count)) + unit
    }

}

public enum PanelDismissal {
    public static func allowed(pinned: Bool, pointerInside: Bool, menuOpen: Bool, dragging: Bool) -> Bool {
        !pinned && !pointerInside && !menuOpen && !dragging
    }
}
