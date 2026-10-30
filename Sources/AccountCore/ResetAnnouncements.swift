import Foundation

public struct ResetAnnouncement: Codable, Equatable {
    public let id: String
    public let text: String
    public let published_at: String
    public let url: String
    public let kind: String
    /// Set when the user's Codex judged the post: the reset time it read, and a one-line explanation.
    public var reset_at: String? = nil
    public var note: String? = nil
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
    public var timing: ResetTiming? {
        if let at = reset_at.flatMap(ResetFeed.date) { return ResetTiming(expectedAt: at, hint: "") }
        return date.map { ResetTiming.read(text, postedAt: $0) }
    }
    /// A planned reset stays worth acting on until its time, or for a day when the post names none.
    public func isUpcoming(at now: Date) -> Bool {
        guard kind == "planned", let date, let timing else { return false }
        return (timing.expectedAt ?? date.addingTimeInterval(24 * 3600)) > now
    }
    public var eligible: Bool {
        ["planned", "reported_completed", "banked", "possible_reset", "limits"].contains(kind) && originalURL != nil && date != nil
            && (kind != "limits" || note != nil || LimitsAnnouncement.matches(text))
    }
    public var label: String {
        if kind == "possible_reset" { return "重置相关新帖（待额度核验）" }
        if kind == "limits" { return "额度调整公告" }
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
    /// The model's reading of recent posts, so a post is asked about once.
    public var judged: [String: ResetJudge.Verdict]?
    public init(now: Date = Date()) { startedAt = now }

    @discardableResult public mutating func ingest(_ feed: ResetFeed, accountIDs: [String], now: Date) throws -> [ResetAnnouncement] {
        try feed.validate()
        lastCheckedAt = now; sourceUpdatedAt = feed.updated_at.flatMap(ResetFeed.date)
        sourceStale = feed.stale || (sourceUpdatedAt.map { now.timeIntervalSince($0) > 900 || $0 > now.addingTimeInterval(300) } ?? true)
        lastError = nil
        guard enabled else { return [] }
        let seen = Set(seenKeys)
        // Personal X and the public source classify the same post separately; one post signals once,
        // unless it was only a "possible reset" before.
        var seenIDs = Set(seenKeys.compactMap { key -> String? in
            let parts = key.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[1] != "possible_reset" ? String(parts[0]) : nil
        })
        var newKeys = Set<String>()
        let signals = feed.items.filter { post in
            guard post.eligible, let date = post.date, date >= startedAt,
                  date <= now.addingTimeInterval(300), date >= now.addingTimeInterval(-72 * 3600),
                  !seen.contains(post.key), !seenIDs.contains(post.id), newKeys.insert(post.key).inserted else { return false }
            if post.kind != "possible_reset" { seenIDs.insert(post.id) }
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

/// "We are doubling all usage limits ... effective today": a limit change that applies now refills quota like a
/// reset does. Model launches that merely give "2X more usage" are not limit changes.
public enum LimitsAnnouncement {
    public static func matches(_ text: String) -> Bool {
        let value = text.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ expression: String) -> Bool { value.range(of: expression, options: .regularExpression) != nil }
        return has(#"\b(usage|rate) limits?\b|\blimits\b"#)
            && has(#"\b(doubl\w*|tripl\w*|2x|3x|increas\w*|rais\w*|boost\w*|bump\w*)\b"#)
            && has(#"\b(today|now|effective|starting|immediately)\b"#)
            && !has(#"\b(not|no|never|won't|aren't|isn't)\b.{0,25}\b(doubl|tripl|increas|rais|boost|bump)"#)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }
    /// The post's first sentence without the "Day 25/" campaign prefix, for a notification body.
    public static func headline(_ text: String) -> String {
        var line = text.replacingOccurrences(of: #"^\s*day\s+\d+\s*[/.:]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        line = line.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? line
        if let end = line.range(of: #"[.!。！](\s|$)"#, options: .regularExpression) { line = String(line[..<end.upperBound]) }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
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
        request.setValue("CodexAccounts/0.2.0-beta.1 (+local-announcement-monitor)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 4_000_000 else { throw ResetFeedError.invalidResponse }
        let feed = try JSONDecoder().decode(ResetFeed.self, from: data)
        try feed.validate(); return feed
    }
}

/// When a reset is expected, read only from the announcement's own wording. Never invents a time.
public struct ResetTiming: Equatable {
    public let expectedAt: Date?
    /// Used when the post names no exact time, e.g. "明天".
    public let hint: String
    private static let amount = #"(\d+(?:\.\d+)?|half an?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
    private static let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                                  "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
    public static func read(_ text: String, postedAt: Date) -> ResetTiming {
        let value = text.lowercased()
        let patterns = [#"\bin\s+(?:about\s+|around\s+|roughly\s+|approximately\s+|~\s*|the\s+next\s+)?"# + amount + #"\s*(hours?|hrs?|h|minutes?|mins?)\b"#,
                        #"\b"# + amount + #"\s*(hours?|hrs?|minutes?|mins?)\s+from\s+now\b"#]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let numberRange = Range(match.range(at: 1), in: value), let unitRange = Range(match.range(at: 2), in: value) else { continue }
            let number = String(value[numberRange])
            guard let count = number.hasPrefix("half") ? 0.5 : (Double(number) ?? words[number]), count > 0, count <= 72 else { continue }
            let seconds = count * (value[unitRange].hasPrefix("h") ? 3600 : 60)
            return ResetTiming(expectedAt: postedAt.addingTimeInterval(seconds), hint: "")
        }
        func has(_ expression: String) -> Bool { value.range(of: expression, options: .regularExpression) != nil }
        if has(#"\bfew hours\b"#) { return ResetTiming(expectedAt: nil, hint: "几小时内") }
        if has(#"\btomorrow\b"#) { return ResetTiming(expectedAt: nil, hint: "明天") }
        if has(#"\b(tonight|later today|this (morning|afternoon|evening)|today)\b"#) { return ResetTiming(expectedAt: nil, hint: "今天晚些时候") }
        if has(#"\bthis (week|weekend)\b"#) { return ResetTiming(expectedAt: nil, hint: "本周内") }
        if has(#"\b(soon|shortly|momentarily)\b"#) { return ResetTiming(expectedAt: nil, hint: "即将") }
        return ResetTiming(expectedAt: nil, hint: "")
    }
    public func describe(now: Date) -> String {
        if let expectedAt { return expectedAt > now ? "约 " + Presentation.countdown(expectedAt, now: now) + "重置" : "已到预告的重置时间" }
        return hint.isEmpty ? "重置时间未说明" : hint + "重置"
    }
}

/// The system notification for a new announcement. Only explicit announcements notify.
public enum ResetNotice {
    public struct Account { public let name: String; public let remaining: Double
        public init(name: String, remaining: Double) { self.name = name; self.remaining = remaining } }
    public static func message(for post: ResetAnnouncement, accounts: [Account], now: Date) -> (title: String, body: String)? {
        switch post.kind {
        case "planned":
            let left = accounts.filter { $0.remaining >= 10 }.sorted { $0.remaining > $1.remaining }.prefix(3)
            let usage = left.isEmpty ? "各账号余量已不多。" : "还有余量：" + left.map { "\($0.name) \(Int($0.remaining))%" }.joined(separator: "、") + "，抓紧用。"
            return ("Tibo 预告重置额度", (post.timing?.describe(now: now) ?? "重置时间未说明") + "。" + usage)
        case "reported_completed": return ("Tibo 宣布额度已重置", lead(post) + "正在刷新全部账号额度。")
        case "limits": return ("Tibo 宣布额度调整", (post.note.flatMap { $0.isEmpty ? nil : $0 + " " } ?? LimitsAnnouncement.headline(post.text) + " ") + "正在刷新全部账号额度。")
        case "banked": return ("Tibo 发放 banked reset", lead(post) + "正在刷新各账号的 banked reset。")
        default: return nil
        }
    }
    private static func lead(_ post: ResetAnnouncement) -> String { post.note.flatMap { $0.isEmpty ? nil : $0 + " " } ?? "" }
}
