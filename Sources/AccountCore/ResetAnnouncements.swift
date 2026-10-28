import Foundation

public struct ResetAnnouncement: Codable, Equatable {
    public let id: String
    public let text: String
    public let published_at: String
    public let url: String
    public let kind: String
    public var date: Date? { ResetFeed.date(published_at) }
    public var originalURL: URL? {
        guard id.range(of: #"^[0-9]{10,25}$"#, options: .regularExpression) != nil,
              let link = URL(string: url), link.scheme == "https",
              ["x.com", "twitter.com", "www.x.com", "www.twitter.com"].contains(link.host?.lowercased() ?? ""),
              link.user == nil, link.password == nil, link.port == nil,
              link.path.lowercased() == "/thsottiaux/status/\(id)" else { return nil }
        return URL(string: "https://x.com/thsottiaux/status/\(id)")
    }
    public var key: String { id + ":" + kind }
    public var eligible: Bool { ["planned", "reported_completed", "banked", "possible_reset"].contains(kind) && originalURL != nil && date != nil }
    public var label: String {
        if kind == "possible_reset" { return "重置相关新帖（待额度核验）" }
        return kind == "banked" ? "banked reset 发放公告" : (kind == "planned" ? "重置预告" : "重置完成公告")
    }
}
public struct ResetFeed: Decodable {
    public let available: Bool
    public let stale: Bool
    public let handle: String
    public let updated_at: String?
    public let items: [ResetAnnouncement]
    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    public func validate() throws {
        guard available, handle.lowercased() == "thsottiaux" else { throw ResetFeedError.unavailable }
    }
}
public enum ResetFeedError: LocalizedError {
    case unavailable, invalidResponse
    public var errorDescription: String? { self == .unavailable ? "公告源暂不可用" : "公告接口返回异常" }
}

/// Public announcements only trigger a read of official quotas. They never set a quota.
public struct ResetMonitorState: Codable {
    public var enabled = true
    public var startedAt: Date
    public var seenKeys: [String] = []
    public var lastCheckedAt: Date?
    public var sourceUpdatedAt: Date?
    public var sourceStale = false
    public var lastError: String?
    public var lastAnnouncement: ResetAnnouncement?
    public var requestedAt: Date?
    public var pendingAccountIDs: [String] = []
    public var refreshedAccountIDs: [String] = []
    public var targetCount = 0
    public init(now: Date = Date()) { startedAt = now }

    @discardableResult public mutating func ingest(_ feed: ResetFeed, accountIDs: [String], now: Date) throws -> [ResetAnnouncement] {
        try feed.validate()
        lastCheckedAt = now; sourceUpdatedAt = feed.updated_at.flatMap(ResetFeed.date)
        sourceStale = feed.stale || (sourceUpdatedAt.map { now.timeIntervalSince($0) > 900 || $0 > now.addingTimeInterval(300) } ?? true)
        lastError = nil
        guard enabled else { return [] }
        let seen = Set(seenKeys)
        var newKeys = Set<String>()
        let signals = feed.items.filter { post in
            guard post.eligible, let date = post.date, date >= startedAt,
                  date <= now.addingTimeInterval(300), date >= now.addingTimeInterval(-72 * 3600),
                  !seen.contains(post.key), newKeys.insert(post.key).inserted else { return false }
            return true
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        seenKeys = Array((seenKeys + signals.map(\.key)).suffix(1000))
        if let last = signals.last {
            lastAnnouncement = last; requestedAt = now
            pendingAccountIDs = Array(Set(accountIDs)).sorted(); targetCount = pendingAccountIDs.count
            refreshedAccountIDs = []
        }
        return signals
    }
    public mutating func acknowledge(_ id: String, syncStartedAt: Date) {
        guard let requestedAt, syncStartedAt >= requestedAt, pendingAccountIDs.contains(id) else { return }
        pendingAccountIDs.removeAll { $0 == id }
        if !refreshedAccountIDs.contains(id) { refreshedAccountIDs.append(id) }
    }
    public func canRetry(at now: Date) -> Bool {
        enabled && !pendingAccountIDs.isEmpty && requestedAt.map { now.timeIntervalSince($0) <= 900 } == true
    }
}

public enum ResetAnnouncementAPI {
    public static let endpoint = URL(string: "https://www.codexreset-news.com/api/v1/tibo?limit=100")!
    public static func fetch() async throws -> ResetFeed {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexAccounts/0.1.0-beta.1 (+local-announcement-monitor)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 4_000_000 else { throw ResetFeedError.invalidResponse }
        let feed = try JSONDecoder().decode(ResetFeed.self, from: data)
        try feed.validate(); return feed
    }
}
