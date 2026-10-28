import Foundation

public enum GatewayConfigurationError: LocalizedError {
    case conflict, credentials, unavailable, desktopIdentity
    public var errorDescription: String? {
        switch self {
        case .conflict: return "Codex 配置已被其他程序修改，自动恢复已停止。备份仍保留在网关目录。"
        case .credentials: return "请先连接账号并启用本地文件存储，再启用自动路由。"
        case .unavailable: return "本机网关启动失败；请检查端口占用后重试。"
        case .desktopIdentity: return "Codex 当前登录未匹配已连接账号，或桌面凭据已过期。请先将当前账号连接到管家；未修改 Codex 配置。"
        }
    }
}

/// Installs a provider without touching auth.json or session databases.
/// Restore owns only the provider selection and our table; unrelated edits survive.
public struct GatewayConfiguration {
    public let home: URL
    public let root: URL
    public init(home: URL, root: URL) { self.home = home; self.root = root }
    private var path: URL { home.appendingPathComponent("config.toml") }
    private var backup: URL { root.appendingPathComponent("config.before-gateway") }
    private var applied: URL { root.appendingPathComponent("config.gateway-applied") }
    public var installed: Bool { FileManager.default.fileExists(atPath: applied.path) }
    public func install(key: String, port: Int) throws {
        guard key.count >= 32, key.allSatisfy({ $0.isHexDigit }), (1024...65535).contains(port) else { throw GatewayConfigurationError.unavailable }
        guard path.standardizedFileURL == path.resolvingSymlinksInPath() else { throw GatewayConfigurationError.conflict }
        if installed {
            _ = try checkedCurrent()
            let installedParts = try parts(String(contentsOf: applied, encoding: .utf8))
            if installedParts.base == "openai_base_url = \"http://127.0.0.1:\(port)/backend-api/codex\"",
               installedParts.block.contains("experimental_bearer_token = \"\(key)\"") { return }
            // First restore our old fields, preserving concurrent edits, then install native routing.
            try restore()
            try install(key: key, port: port)
            return
        }
        let original = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : Data()
        guard let text = String(data: original, encoding: .utf8), !text.contains("codex_accounts_gateway") else { throw GatewayConfigurationError.conflict }
        guard !text.contains("\"\"\""), !text.contains("'''"), !text.contains("model_providers =") else { throw GatewayConfigurationError.conflict }
        var inTop = true
        let lines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inTop = false }
            return !(inTop && trimmed.range(of: #"^(model_provider|openai_base_url)\s*="# , options: .regularExpression) != nil)
        }
        let result = "model_provider = \"openai\"\nopenai_base_url = \"http://127.0.0.1:\(port)/backend-api/codex\"\n" + lines.joined(separator: "\n") + """


        [model_providers.codex_accounts_gateway]
        name = "Codex Accounts"
        base_url = "http://127.0.0.1:\(port)/v1"
        wire_api = "responses"
        requires_openai_auth = false
        experimental_bearer_token = "\(key)"
        supports_websockets = false
        request_max_retries = 0
        stream_max_retries = 0

        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateAtomicFile.write(original, to: backup)
        try PrivateAtomicFile.write(Data(result.utf8), to: applied)
        // If interrupted here the app sees installed=true and refuses unsafe restoration.
        try PrivateAtomicFile.write(Data(result.utf8), to: path)
    }
    private func parts(_ text: String) throws -> (provider: String, base: String?, block: String, remainder: String) {
        guard !text.contains("\"\"\""), !text.contains("'''") else { throw GatewayConfigurationError.conflict }
        let pattern = #"(?m)^\[model_providers\.codex_accounts_gateway\][^\n]*\n(?:[^\[][^\n]*\n|\n)*"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1 else { throw GatewayConfigurationError.conflict }
        let range = matches[0].range
        let block = ns.substring(with: range)
        let withoutBlock = ns.replacingCharacters(in: range, with: "")
        var top = true, providers: [String] = [], bases: [String] = []
        let rest = withoutBlock.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { top = false }
            if top && trimmed.range(of: #"^openai_base_url\s*="# , options: .regularExpression) != nil {
                bases.append(line); return false
            }
            if top && trimmed.range(of: #"^model_provider\s*="# , options: .regularExpression) != nil {
                providers.append(line); return false
            }
            return true
        }.joined(separator: "\n")
        guard providers.count == 1, bases.count <= 1 else { throw GatewayConfigurationError.conflict }
        return (providers[0], bases.first, block, rest)
    }
    private func checkedCurrent() throws -> String {
        guard path.standardizedFileURL == path.resolvingSymlinksInPath() else { throw GatewayConfigurationError.conflict }
        let current = try String(contentsOf: path, encoding: .utf8)
        let a = try parts(String(contentsOf: applied, encoding: .utf8)), b = try parts(current)
        guard a.provider == b.provider, a.base == b.base, a.block == b.block else { throw GatewayConfigurationError.conflict }
        return current
    }
    public func restore() throws {
        guard installed else { return }
        let current = try checkedCurrent()
        let original = try Data(contentsOf: backup)
        if Data(current.utf8) == (try Data(contentsOf: applied)) {
            try PrivateAtomicFile.write(original, to: path)
        } else {
            var top = true
            let originalProvider = String(decoding: original, as: UTF8.self).components(separatedBy: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { top = false }
                return top && trimmed.range(of: #"^(model_provider|openai_base_url)\s*="# , options: .regularExpression) != nil
            }
            let rest = try parts(current).remainder
            let result = (originalProvider.isEmpty ? "" : originalProvider.joined(separator: "\n") + "\n") + rest
            try PrivateAtomicFile.write(Data(result.utf8), to: path)
        }
        try FileManager.default.removeItem(at: applied)
        try FileManager.default.removeItem(at: backup)
    }
}

public struct GatewayAccount: Codable {
    public let id: String
    public let accountID: String
    public let access: String
    public let expires: Double
    public let available: Bool
    public let reset: Double
    public init(id: String, credential: DesktopCredential, available: Bool, reset: Double) throws {
        let raw = try JSONSerialization.jsonObject(with: credential.data) as? [String: Any]
        guard let token = (raw?["tokens"] as? [String: Any])?["access_token"] as? String else { throw GatewayConfigurationError.credentials }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw GatewayConfigurationError.credentials }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = claims["exp"] as? Double else { throw GatewayConfigurationError.credentials }
        self.id = id; self.accountID = credential.accountID; self.access = token; self.expires = exp
        self.available = available; self.reset = reset
    }
}

public struct GatewayPool: Codable {
    public let key: String
    public let preferred: String
    public let accounts: [GatewayAccount]
    public let clients: [GatewayClientIdentity]
    public init(key: String, preferred: String, accounts: [GatewayAccount], clients: [GatewayClientIdentity] = []) { self.key = key; self.preferred = preferred; self.accounts = accounts; self.clients = clients }
}

public struct GatewayClientIdentity: Codable {
    public let id: String
    public let accountID: String
    public init(id: String, accountID: String) { self.id = id; self.accountID = accountID }
}

public enum GatewayCredentialSource {
    /// The switch receipt is historical, not authoritative after a desktop login.
    public static func select(expected: String, desktop: Data?, stored: () throws -> Data) throws -> DesktopCredential {
        if let desktop, let credential = try? DesktopCredential(desktop, expected: expected),
           let value = try? GatewayAccount(id: "desktop", credential: credential, available: true, reset: 0),
           value.expires > Date().timeIntervalSince1970 { return credential }
        return try DesktopCredential(stored(), expected: expected)
    }
}
