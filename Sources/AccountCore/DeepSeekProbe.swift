import Foundation

public struct FetchedPage: Codable, Equatable {
    public let title: String
    public let content: String
}

public struct TiboPostLink: Codable, Equatable, Identifiable {
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

public enum DeepSeekProbeError: LocalizedError, Equatable {
    case invalidKey, invalidPostURL, http(Int), invalidResponse, emptyContent, network
    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "请填写有效的 DeepSeek API Key（不能包含空格或换行）。"
        case .invalidPostURL: return "请填写 Tibo 本人的 X 帖子链接，或留空。"
        case .http(401): return "Key 无效或已失效（401），请重新填写。"
        case .http(402): return "DeepSeek 余额不足（402）。"
        case .http(403): return "DeepSeek 安全策略拒绝抓取（403）。"
        case .http(404): return "未取得可用正文（404）：可能被 X 限制，或页面无法提取。"
        case .http(429): return "DeepSeek 请求受限（429），请稍后手动重试。"
        case .http(let code): return "抓取未成功（HTTP \(code)），请稍后手动重试。"
        case .invalidResponse: return "DeepSeek 返回格式异常，无法确认抓取结果。"
        case .emptyContent: return "返回了空正文，不能视为抓取成功。"
        case .network: return "网络连接失败或超时，请稍后手动重试。"
        }
    }
}

public struct DeepSeekProbeResult: Codable {
    public let checkedAt: Date
    public let profile: FetchedPage
    public let posts: [TiboPostLink]
    public let requestedPost: TiboPostLink?
    public let detailTarget: TiboPostLink?
    public let detail: FetchedPage?
    public let detailError: String?
    public var summary: String {
        if posts.isEmpty { return "读到了页面，但未识别出 Tibo 帖子链接；尚不能用于监控。" }
        if let requestedPost, !posts.contains(requestedPost) {
            return "主页未包含你提供的对照帖子；尚不能确认能及时发现新帖。"
        }
        if detail == nil { return "主页识别到帖子链接，但帖子正文抓取失败；尚不能用于监控。" }
        return "已取得主页和帖子页面内容；是否为最新、正文是否完整，仍需对照 X 核验。"
    }
}

/// No redirects: credentials must only be sent to the fixed DeepSeek endpoint.
private final class NoProbeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum DeepSeekProbe {
    public static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/fetch")!
    public static let profileURL = URL(string: "https://x.com/thsottiaux")!
    public static func validatedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 1024, key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw DeepSeekProbeError.invalidKey
        }
        return key
    }
    static func request(key: String, url: URL) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + (try validatedKey(key)), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["url": url.absoluteString])
        return request
    }
    static func decode(_ data: Data, status: Int, key: String) throws -> FetchedPage {
        guard status == 200 else { throw DeepSeekProbeError.http(status) }
        guard data.count <= 4_000_000, let page = try? JSONDecoder().decode(FetchedPage.self, from: data) else {
            throw DeepSeekProbeError.invalidResponse
        }
        guard !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekProbeError.emptyContent }
        // Never surface credentials, even if an upstream error accidentally echoes them.
        return FetchedPage(title: String(page.title.replacingOccurrences(of: key, with: "[REDACTED]").prefix(500)),
                           content: String(page.content.replacingOccurrences(of: key, with: "[REDACTED]").prefix(100_000)))
    }
    public static func run(key: String, referenceURL: String = "") async throws -> DeepSeekProbeResult {
        let key = try validatedKey(key)
        let reference = referenceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPost = reference.isEmpty ? nil : TiboPostLink.parse(reference)
        guard reference.isEmpty || requestedPost != nil else { throw DeepSeekProbeError.invalidPostURL }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: NoProbeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await probe(reference: requestedPost) { url in
            do {
                let request = try request(key: key, url: url)
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw DeepSeekProbeError.invalidResponse }
                return try decode(data, status: response.statusCode, key: key)
            } catch is CancellationError { throw CancellationError() }
            catch let error as DeepSeekProbeError { throw error }
            catch { throw DeepSeekProbeError.network }
        }
    }
    static func probe(reference: TiboPostLink?, fetch: (URL) async throws -> FetchedPage) async throws -> DeepSeekProbeResult {
        let profile = try await fetch(profileURL)
        try Task.checkCancellation()
        let posts = Array(TiboPostLink.extract(from: profile.content, now: Date()).prefix(10))
        let target = reference ?? posts.first
        var detail: FetchedPage?, failure: String?
        if let target {
            do { detail = try await fetch(target.url) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = (error as? DeepSeekProbeError ?? .network).localizedDescription }
        }
        try Task.checkCancellation()
        return DeepSeekProbeResult(checkedAt: Date(), profile: profile, posts: posts, requestedPost: reference,
                                   detailTarget: target, detail: detail, detailError: failure)
    }
}
