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
        let units: [(Int64, String)] = [(100_000_000, "亿"), (10_000_000, "千万"), (1_000_000, "百万"), (10_000, "万")]
        guard let (scale, unit) = units.first(where: { count >= $0.0 }) else { return count.formatted() }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2; formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return (formatter.string(from: NSNumber(value: Double(count) / Double(scale))) ?? String(count)) + " " + unit
    }

}

public enum PanelDismissal {
    public static func allowed(pinned: Bool, pointerInside: Bool, menuOpen: Bool, dragging: Bool) -> Bool {
        !pinned && !pointerInside && !menuOpen && !dragging
    }
}
