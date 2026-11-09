import Foundation

public struct GatewayActivityEvent: Codable, Sendable {
    public var kind: String
    public var account: String?
    public var request: String?
    public var status: Int?
    /// Fixed category from the gateway (never request content), e.g. "sealed_owner_unavailable".
    public var reason: String?
    /// Token counts of a completed streamed reply; `cached` is the prompt-cache hit.
    public var input: Int64?
    public var cached: Int64?
    public init(kind: String, account: String? = nil, request: String? = nil, status: Int? = nil, reason: String? = nil,
                input: Int64? = nil, cached: Int64? = nil) {
        self.kind = kind; self.account = account; self.request = request; self.status = status; self.reason = reason
        self.input = input; self.cached = cached
    }
}

/// The gateway's fixed failure words, in the user's words.
public enum GatewayFault {
    /// Stream failure codes that are the account's own refusal (its quota or rate limit).
    public static let accountCodes: Set<String> = ["insufficient_quota", "usage_limit_reached", "usage_not_included", "rate_limit_exceeded"]
    /// A network failure is never an account's: every account goes through the same network and proxy.
    public static func networkCaption(_ reason: String?) -> String {
        let reason = reason ?? ""
        let proxy = reason.hasPrefix("proxy_")
        let what: String
        switch proxy ? String(reason.dropFirst(6)) : reason {
        case "header_timeout": what = L("迟迟没等到回复", "no reply in time")
        case "upstream": what = L("代理连不到服务", "the proxy could not connect onward")
        case "dns": what = L("域名解析失败", "name lookup failed")
        case "refused": what = L("连接被拒绝", "connection refused")
        case "reset": what = L("连接被重置", "connection reset")
        case "tls": what = L("加密连接失败", "secure connection failed")
        case "timeout": what = L("连接超时", "connection timed out")
        case "eof": what = L("连接被断开", "connection closed")
        default: what = L("网络出错", "network error")
        }
        let place = proxy ? L("（经代理）", " through the proxy") : ""
        return L("连不上 Codex 服务\(place)：\(what)。请检查代理或网络，不是账号问题", "Can't reach the Codex service\(place): \(what). Check the network or proxy; not an account problem")
    }
}

public struct PromptCacheUse: Equatable, Sendable {
    public let cached: Int64
    public let input: Int64
    public var hit: Bool { cached > 0 }
    public var percent: Int { input > 0 ? Int((Double(cached) / Double(input) * 100).rounded()) : 0 }
}

/// Transient activity only. No credentials, prompts or conversation content.
public struct RoutingActivity: Sendable {
    public private(set) var active: [String: String] = [:]
    public private(set) var completed = 0
    public private(set) var reroutes = 0
    public private(set) var lastAccount: String?
    public private(set) var lastKind = "ready"
    public private(set) var changedAt = Date.distantPast
    /// Whether the latest request reached an account and finished; nil before the first outcome.
    /// A refusal that a retry then serves ends as success.
    public private(set) var lastRouted: Bool?
    public private(set) var lastCache: PromptCacheUse?
    private var attempted: Set<String> = []
    public init() {}
    public mutating func receive(_ event: GatewayActivityEvent, at date: Date = Date()) {
        if event.kind == "stopped" {
            active.removeAll(); attempted.removeAll(); lastKind = "stopped"; changedAt = date
            lastRouted = nil; lastCache = nil
            return
        }
        guard let request = event.request else { return }
        switch event.kind {
        case "routing":
            guard let account = event.account else { return }
            if attempted.contains(request) { reroutes += 1 }
            attempted.insert(request); active[request] = account
            lastAccount = account; lastKind = "routing"; changedAt = date
        case "completed":
            guard active.removeValue(forKey: request) != nil else { return }
            completed += 1; lastAccount = event.account; lastKind = "completed"; changedAt = date
            lastRouted = true
            if let input = event.input, input > 0 { lastCache = PromptCacheUse(cached: event.cached ?? 0, input: input) }
        case "refused", "network_error", "interrupted", "rejected":
            active.removeValue(forKey: request)
            lastAccount = event.account; lastKind = event.kind; changedAt = date
            lastRouted = false
        case "finished":
            if active.removeValue(forKey: request) != nil {
                lastKind = "ended"; changedAt = date
            }
            attempted.remove(request)
        default: break
        }
    }
    public func count(for account: String) -> Int { active.values.filter { $0 == account }.count }
}
