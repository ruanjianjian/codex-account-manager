import Foundation

/// Release tags look like v0.4.6-beta.1; the app's version string is 0.4.6.
public enum AppVersion {
    public static func numbers(_ text: String) -> [Int] {
        let core = text.trimmingCharacters(in: .whitespaces).drop { $0 == "v" }.split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = numbers(tag), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    /// The release the one-line installer points at: its `LATEST="…"` line.
    public static func latestTag(inInstaller script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix("LATEST=\"") {
            let tag = line.dropFirst("LATEST=\"".count).prefix { $0 != "\"" }
            if tag.range(of: #"^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil { return String(tag) }
        }
        return nil
    }
    /// The checksum SHA256SUMS.txt lists for one file.
    public static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == Substring(file), parts[0].count == 64 { return parts[0].lowercased() }
        }
        return nil
    }
}
