import Foundation

public enum ClientFailure: Error, LocalizedError {
    case missingBinary, timeout, disconnected, invalidResponse, authentication, keychainAccess, service(Int), fileAccess
    public var errorDescription: String? {
        switch self {
        case .missingBinary: return "未找到 Codex CLI，请安装后重新打开管家。"
        case .timeout: return "服务响应超时，已保留上次数据；稍后自动重试。"
        case .disconnected: return "采集连接已中断，稍后会重新连接。"
        case .invalidResponse: return "服务返回格式无法识别，请更新管家后重试。"
        case .keychainAccess: return "钥匙串访问未完成，已暂停自动同步。请从此账号菜单点“刷新”手动重试。"
        case .authentication: return "登录需要重新验证，请点“重新连接”。"
        case .service(let code): return "服务暂不可用（\(code)），已保留登录；稍后重试。若持续失败，请检查网络与钥匙串权限。"
        case .fileAccess: return "无法保存本机数据，请检查目录权限。"
        }
    }
}

/// One process owns one isolated auth home. No API inference, reset consumption, or global credential access.
@MainActor public final class RPCClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var startup: Task<Void, Error>?
    public var onNotification: ((String, [String: Any]) -> Void)?
    public let home: URL
    private let executable: URL
    private let prepareHome: Bool
    private let credentialStore: String
    public init(home: URL, executable: URL, prepareHome: Bool = true, credentialStore: String = "keyring") {
        self.home = home; self.executable = executable; self.prepareHome = prepareHome; self.credentialStore = credentialStore
    }

    public static func isolatedEnvironment(home: URL, inherited: [String: String]) -> [String: String] {
        let keep = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"]
        var env = inherited.filter { keep.contains($0.key) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["CODEX_HOME"] = home.path
        env["RUST_LOG"] = "off"
        return env
    }
    public func start() async throws {
        if let startup { try await startup.value; return }
        if process?.isRunning == true { return }
        let task = Task { @MainActor in try await self.launch() }
        startup = task
        do { try await task.value; startup = nil } catch { startup = nil; stop(); throw error }
    }
    private func launch() async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClientFailure.missingBinary }
        if prepareHome {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        }
        let config = "cli_auth_credentials_store = \"\(credentialStore)\"\n[analytics]\nenabled = false\n"
        // A desktop window may now share this account's home. Preserve its settings.
        let configURL = home.appendingPathComponent("config.toml")
        if prepareHome && !FileManager.default.fileExists(atPath: configURL.path) {
            try Data(config.utf8).write(to: configURL, options: .withoutOverwriting)
        }
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        proc.executableURL = executable
        guard ["keyring", "file"].contains(credentialStore) else { throw ClientFailure.fileAccess }
        // Account collection must retain ChatGPT auth even when inference uses our custom provider.
        proc.arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"\(credentialStore)\"", "-c", "model_provider=\"openai\""]
        proc.environment = Self.isolatedEnvironment(home: home, inherited: ProcessInfo.processInfo.environment)
        proc.currentDirectoryURL = home
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = FileHandle.nullDevice
        let current = UUID(); generation = current
        proc.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }
            self.failPending(ClientFailure.disconnected)
            self.process = nil; self.input = nil
        } }
        process = proc; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try proc.run()
        let handle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.receive(chunk)
                }
            }
        }
        _ = try await send("initialize", params: ["clientInfo": ["name": "codex_account_manager", "title": "Codex Accounts Beta", "version": "1.0.0"], "capabilities": ["experimentalApi": true]], timeout: 20)
        try write(["method": "initialized", "params": [:]])
    }
    public func request(_ method: String, params: [String: Any] = [:], timeout: Double = 35) async throws -> [String: Any] {
        try await start()
        return try await send(method, params: params, timeout: timeout)
    }
    private func send(_ method: String, params: [String: Any], timeout: Double) async throws -> [String: Any] {
        sequence += 1; let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id)
                continuation.resume(throwing: ClientFailure.timeout)
            }
            do { try write(["id": id, "method": method, "params": params]) }
            catch { timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    private func write(_ object: [String: Any]) throws {
        guard process?.isRunning == true, let input else { throw ClientFailure.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 8_000_000 { stop(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                if let id = message["id"] { try? write(["id": id, "error": ["code": -32601, "message": "Unsupported client method"]]); continue }
                onNotification?(method, message["params"] as? [String: Any] ?? [:]); continue
            }
            guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                // Never put raw RPC errors, OAuth URLs, or tokens in UI/logs.
                let text = (error["message"] as? String ?? "").lowercased()
                let keychain = ["keyring", "keychain", "errsecinteractionnotallowed", "user canceled", "user cancelled", "-25308", "-128"].contains { text.contains($0) }
                let auth = ["unauthorized", "401", "refresh_token_reused", "refresh token has expired", "not logged in", "authentication required"].contains { text.contains($0) }
                continuation.resume(throwing: keychain ? ClientFailure.keychainAccess : (auth ? ClientFailure.authentication : ClientFailure.service(error["code"] as? Int ?? -1)))
            } else if let result = message["result"] as? [String: Any] { continuation.resume(returning: result) }
            else { continuation.resume(throwing: ClientFailure.invalidResponse) }
        }
    }
    private func failPending(_ error: Error) {
        let values = pending.values; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        values.forEach { $0.resume(throwing: error) }
    }
    public func stop() {
        generation = UUID()
        startup?.cancel(); startup = nil
        failPending(ClientFailure.disconnected)
        try? input?.close(); input = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        }
        process = nil; output = nil; buffer = Data()
    }
    public func stopAndWait() async -> Bool {
        let previous = process
        stop()
        for _ in 0..<40 {
            if previous?.isRunning != true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return previous?.isRunning != true
    }
}
