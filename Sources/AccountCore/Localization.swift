import Foundation

/// The language Tibot speaks, as picked in Settings.
public enum UILanguage: String, CaseIterable, Sendable { case system, zh, en }

/// Tibot speaks Chinese or English. Left to the system, it speaks Chinese when any language in the Mac's list is
/// Chinese (many Chinese users keep English first), and English otherwise.
public enum L10n {
    nonisolated(unsafe) public static var choice: UILanguage = .system
    nonisolated(unsafe) public static var preferred: [String] = Locale.preferredLanguages
    public static var chinese: Bool { chinese(choice, preferred: preferred) }
    public static func chinese(_ choice: UILanguage, preferred: [String]) -> Bool {
        switch choice {
        case .zh: return true
        case .en: return false
        case .system: return preferred.contains { $0.lowercased().hasPrefix("zh") }
        }
    }
}

/// The Chinese or the English wording, whichever Tibot speaks now.
public func L(_ zh: String, _ en: String) -> String { L10n.chinese ? zh : en }
