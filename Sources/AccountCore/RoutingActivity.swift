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
