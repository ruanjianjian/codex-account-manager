import Foundation

public struct TiboPostLink: Codable, Equatable, Identifiable {
    public static let profileURL = URL(string: "https://x.com/thsottiaux")!
    public let id: String
    public var url: URL { URL(string: "https://x.com/thsottiaux/status/\(id)")! }
    // X snowflake timestamp is only an estimate, never proof of content freshness.
    public var estimatedDate: Date? {
        guard let number = UInt64(id) else { return nil }
        return Date(timeIntervalSince1970: Double((number >> 22) + 1_288_834_974_657) / 1000)
    }
    public static func parse(_ text: String) -> TiboPostLink? {
        guard let url = URL(string: text), url.scheme == "https",
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0].lowercased() == "thsottiaux", parts[1] == "status",
              parts[2].range(of: #"^[0-9]{10,20}$"#, options: .regularExpression) != nil,
              UInt64(parts[2]) != nil else { return nil }
        return TiboPostLink(id: String(parts[2]))
    }
    public static func extract(from markdown: String, now: Date) -> [TiboPostLink] {
        let detector = try! NSRegularExpression(pattern: #"https://[^\s<>\[\]()\"']+"#)
        let range = NSRange(markdown.startIndex..., in: markdown)
        var seen = Set<String>()
        return detector.matches(in: markdown, range: range).compactMap { match -> TiboPostLink? in
            guard let range = Range(match.range, in: markdown), let post = parse(String(markdown[range])),
                  let date = post.estimatedDate, date >= Date(timeIntervalSince1970: 1_288_834_974),
                  date <= now.addingTimeInterval(300), seen.insert(post.id).inserted else { return nil }
            return post
        }.sorted { UInt64($0.id)! > UInt64($1.id)! }
    }
}

public struct XVisiblePost: Codable, Equatable, Identifiable {
    public let url: String
    public let text: String
    public let publishedAt: String
    public let truncated: Bool
    public var id: String { TiboPostLink.parse(url)?.id ?? "" }
    public var date: Date? { ResetFeed.date(publishedAt) }
    public var originalURL: URL? { TiboPostLink.parse(url)?.url }
    public func isValid(at now: Date) -> Bool {
        guard originalURL != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 80_000, let date,
              date >= Date(timeIntervalSince1970: 1_288_834_974), date <= now.addingTimeInterval(300) else { return false }
        return true
    }
    public var resetKind: String? {
        guard !truncated else { return nil }
        if LimitsAnnouncement.matches(text) { return "limits" }
        let value = text.lowercased().replacingOccurrences(of: "’", with: "'")
        func matches(_ expression: String) -> Bool { value.range(of: expression, options: .regularExpression) != nil }
        guard matches(#"\breset(?:s|ting)?\b"#),
              !matches(#"\b(no|not|never|won't|cannot|can't|haven't|hasn't|didn't)\b.{0,40}\breset"#),
              !matches(#"\b(if|wish|hope|should|could|would)\b.{0,50}\breset"#),
              !matches(#"\bevery (day|week|month|hour)\b"#),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return nil }
        let global = matches(#"\b(everyone|everybody|all users|all codex users|all pro users|all plus users|all accounts|globally)\b"#)
        let quota = matches(#"\b(codex|limits?|banked|usage)\b"#)
        // Tibo also posts short campaign messages such as "Day 20/ Rest and reset".
        // Those are signals for a harmless quota read, not evidence of a completed global reset.
        guard global && quota else {
            return quota || matches(#"\bday\s+\d+\s*[/.:]|\breset day\b|\btoday\b.{0,40}\breset\b"#) ? "possible_reset" : nil
        }
        if matches(#"\bbanked\b"#) && matches(#"\b(giv\w*|grant\w*|gift\w*|add\w*|receiv\w*)\b"#) { return "banked" }
        if matches(#"\b(will|going to|later|tomorrow|tonight|soon)\b"#) { return "planned" }
        return "reported_completed"
    }
}

public struct XTimelinePage: Decodable {
    public let pageURL: String
    public let loggedIn: Bool
    public let posts: [XVisiblePost]
    public func validated(at now: Date) throws -> [XVisiblePost] {
        guard let page = URL(string: pageURL), page.scheme == "https", page.host?.lowercased() == "x.com",
              page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "thsottiaux" else {
            throw PersonalXError.wrongPage
        }
        guard loggedIn else { throw PersonalXError.loginRequired }
        var seen = Set<String>()
        let valid = posts.filter { $0.isValid(at: now) && seen.insert($0.id).inserted }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard !valid.isEmpty else { throw PersonalXError.noPosts }
        return Array(valid.prefix(40))
    }
}

public enum PersonalXError: LocalizedError {
    case loginRequired, wrongPage, noPosts, unavailable, busy, storage
    public var errorDescription: String? {
        switch self {
        case .loginRequired: return "需要登录个人 X；请打开 X 登录窗口完成验证。"
        case .wrongPage: return "请在 X 窗口打开 Tibo 主页，再测试读取。"
        case .noPosts: return "没有读到 Tibo 的有效帖子。可能仍在加载、被限流或页面结构已变化。"
        case .unavailable: return "X 页面加载失败，稍后重试；账号额度同步继续。"
        case .busy: return "X 登录窗口正在使用，后台检查暂缓。"
        case .storage: return "X 监控记录无法保存，已暂停监控，避免丢失去重记录。"
        }
    }
}

public struct PersonalXState: Codable {
    public var enabled = false
    public var baselineAt: Date?
    public var seenIDs: [String] = []
    public var lastCheckedAt: Date?
    public var lastPosts: [XVisiblePost] = []
    public var lastError: String?
    public var possibleGap = false
    public init() { }
    public mutating func start(with posts: [XVisiblePost], now: Date) {
        enabled = true; baselineAt = now; seenIDs = posts.map(\.id)
        lastPosts = posts; lastCheckedAt = now; lastError = nil; possibleGap = false
    }
    /// The first successful read establishes a baseline. Historical announcements never replay.
    public mutating func ingest(_ posts: [XVisiblePost], now: Date) -> ResetFeed {
        let valid = posts.filter { $0.isValid(at: now) }
        let seen = Set(seenIDs)
        let fresh = valid.filter { !seen.contains($0.id) }
        possibleGap = !seen.isEmpty && !valid.contains(where: { seen.contains($0.id) })
            && valid.map(\.date).compactMap { $0 }.min().map { $0 > (lastCheckedAt ?? now) } == true
        let items: [ResetAnnouncement] = baselineAt == nil ? [] : fresh.compactMap { post in
            guard let kind = post.resetKind, let date = post.date, date >= baselineAt!,
                  date >= now.addingTimeInterval(-72 * 3600) else { return nil }
            return ResetAnnouncement(id: post.id, text: post.text, published_at: post.publishedAt,
                                     url: post.originalURL!.absoluteString, kind: kind)
        }
        if baselineAt == nil { baselineAt = now }
        // A post still cut off ("Show more") is read again next time instead of being settled half-read.
        let settled = baselineAt == now ? fresh : fresh.filter { !$0.truncated }
        seenIDs = Array((seenIDs + settled.map(\.id)).suffix(1000))
        lastPosts = valid; lastCheckedAt = now; lastError = nil
        return ResetFeed(available: true, stale: possibleGap, handle: "thsottiaux",
                         updated_at: ISO8601DateFormatter().string(from: now), items: items)
    }
}
