import Foundation

/// The faces of Tibot's mascot.
public enum MascotMood: String, Sendable { case open, blink, hop, star, hello, sad, puzzled }

/// What the mascot looks like and says for the app's state. The panel, the desktop widget and the menu bar
/// all ask here, so they never disagree.
public enum Mascot {
    public struct Account: Sendable {
        public let id: String
        public let name: String
        /// The lowest window left; nil before the first snapshot.
        public let remaining: Double?
        /// When a spent account comes back.
        public let backAt: Date?
        public init(id: String, name: String, remaining: Double?, backAt: Date?) {
            self.id = id; self.name = name; self.remaining = remaining; self.backAt = backAt
        }
        public init(id: String, name: String, windows: [QuotaWindow]) {
            self.init(id: id, name: name, remaining: windows.compactMap(\.remaining).min(), backAt: windows.comesBackAt)
        }
        var spent: Bool { (remaining ?? 1) <= 0 }
    }
    /// Routing moved Codex from one account to another a moment ago.
    public struct Switch: Equatable, Sendable {
        public let from: String, to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }
    public struct Input: Sendable {
        public var accounts: [Account]
        public var routing = false
        public var gatewayReady = false
        /// The account Codex is on now.
        public var current: String?
        public var cacheHit: Bool?
        public var switched: Switch?
        /// The planned reset Tibo announced, already worded for the user.
        public var resetAlert: String?
        public var now = Date()
        public init(accounts: [Account]) { self.accounts = accounts }
    }
    public struct Line: Equatable, Sendable {
        public let mood: MascotMood
        public let text: String
        public init(_ mood: MascotMood, _ text: String) { self.mood = mood; self.text = text }
    }

    /// Every account with quota data is out: there is nothing to switch to until one comes back.
    public static func allSpent(_ accounts: [Account]) -> Bool {
        let known = accounts.filter { $0.remaining != nil }
        return !known.isEmpty && known.allSatisfy(\.spent)
    }
    /// The spent account that comes back first.
    public static func nextBack(_ accounts: [Account]) -> Account? {
        accounts.filter(\.spent).min { ($0.backAt ?? .distantFuture) < ($1.backAt ?? .distantFuture) }
    }

    public static func line(_ input: Input) -> Line {
        let accounts = input.accounts
        func name(_ id: String?) -> String? { id.flatMap { id in accounts.first { $0.id == id }?.name } }
        if accounts.isEmpty { return Line(.hello, "嗨，我是 Tibot") }
        if allSpent(accounts), let next = nextBack(accounts) {
            return Line(.sad, "额度都用完了，\(next.name) \(comesBack(next.backAt, now: input.now))")
        }
        if let alert = input.resetAlert { return Line(.star, alert) }
        if let move = input.switched, let to = name(move.to) {
            if let from = accounts.first(where: { $0.id == move.from }), from.spent { return Line(.hop, "\(from.name) 用完，换到 \(to)") }
            return Line(.hop, "换到 \(to)")
        }
        if input.routing && !input.gatewayReady { return Line(.puzzled, "等待网关…") }
        guard let current = name(input.current) else {
            if !accounts.contains(where: { $0.remaining != nil }) { return Line(.hello, "先连上账号吧") }
            return Line(.open, input.routing ? "等待请求" : "嗨，我是 Tibot")
        }
        return Line(.open, "正在用 \(current)" + (input.routing && input.cacheHit == true ? " · 缓存命中" : ""))
    }

    /// "5 天后" / "3 小时后" / "20 分钟后": how long until a spent account comes back.
    public static func untilReset(_ date: Date?, now: Date) -> String {
        guard let date else { return "等待重置" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "即将恢复" }
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) 天后" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600)) 小时后" }
        return "\(max(1, Int(seconds / 60))) 分钟后"
    }
    /// "3 小时后恢复", or "即将恢复" / "等待重置" when the time has passed or is unknown.
    public static func comesBack(_ date: Date?, now: Date) -> String {
        guard let date, date > now else { return untilReset(date, now: now) }
        return untilReset(date, now: now) + "恢复"
    }
}

extension Array where Element == QuotaWindow {
    /// When a spent account can be used again: the last reset among its spent windows.
    public var comesBackAt: Date? {
        let spent = filter { ($0.remaining ?? 1) <= 0 }.compactMap(\.resetDate)
        return spent.max() ?? compactMap(\.resetDate).min()
    }
}
