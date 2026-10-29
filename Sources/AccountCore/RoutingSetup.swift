import Foundation

/// What a first run still needs before routing can serve Codex, in the order the user does it.
/// Routing then turns itself on; only a user who switched it off keeps it off.
public enum RoutingSetup: Equatable {
    case fileStorage
    case desktopLogin
    case desktopAccount(email: String?)
    case ready

    public static func next(fileStorage: Bool, desktopAccountID: String?, desktopEnrolled: Bool, desktopEmail: String?) -> RoutingSetup {
        guard fileStorage else { return .fileStorage }
        guard desktopAccountID != nil else { return .desktopLogin }
        guard desktopEnrolled else { return .desktopAccount(email: desktopEmail) }
        return .ready
    }
    /// `userChoice` is the stored toggle: nil until the user or the app first sets it.
    public static func shouldEnable(_ setup: RoutingSetup, enabled: Bool, userChoice: Bool?) -> Bool {
        setup == .ready && !enabled && userChoice != false
    }
    public var remaining: Int {
        switch self {
        case .fileStorage: return 2
        case .desktopLogin, .desktopAccount: return 1
        case .ready: return 0
        }
    }
}
