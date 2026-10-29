import AppKit
import AccountCore

@MainActor final class GatewayController {
    let root: URL
    let port: Int
    private var process: Process?
    private var key = ""
    private var generation = UUID()
    var onEvent: ((GatewayActivityEvent) -> Void)?
    var running: Bool { process?.isRunning == true }
    var configuration: GatewayConfiguration { GatewayConfiguration(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), root: root) }
    init(root: URL) { self.root = root.appendingPathComponent("gateway"); port = Bundle.main.bundleIdentifier?.contains("Public") == true || Bundle.main.bundleIdentifier?.contains("io.github") == true ? 18456 : 18455 }
    func save(accounts: [GatewayAccount], preferred: String, clients: [GatewayClientIdentity]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyFile = root.appendingPathComponent("local.key")
        if key.isEmpty {
            if FileManager.default.fileExists(atPath: keyFile.path) {
                key = try String(contentsOf: keyFile, encoding: .utf8)
                guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw GatewayConfigurationError.unavailable }
            } else {
                key = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                try PrivateAtomicFile.write(Data(key.utf8), to: keyFile)
            }
        }
        let data = try JSONEncoder().encode(GatewayPool(key: key, preferred: preferred, accounts: accounts, clients: clients))
        try PrivateAtomicFile.write(data, to: root.appendingPathComponent("pool.json"))
    }
    func start() throws {
        guard !running else { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AccountsGateway")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw GatewayConfigurationError.unavailable }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = binary; p.arguments = ["--config", root.appendingPathComponent("pool.json").path, "--listen", "127.0.0.1:\(port)", "--desktop-auth", configuration.home.appendingPathComponent("auth.json").path]
        p.environment = RPCClient.isolatedEnvironment(home: root, inherited: ProcessInfo.processInfo.environment)
        p.standardOutput = out; p.standardError = err
        process = p; let token = UUID(); generation = token
        // The helper prints one fixed line before a fatal exit. Drain stderr so it can never block; keep only the tail.
        let failure = StderrTail()
        let port = port
        p.terminationHandler = { [weak self] _ in
            _ = failure.closed.wait(timeout: .now() + 1) // let the reader take the final line first
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil; self.onEvent?(.init(kind: "stopped", reason: Self.reason(failure.text, port: port)))
            }
        }
        try p.run()
        let errors = err.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true { let chunk = errors.availableData; if chunk.isEmpty { break }; failure.append(chunk) }
            failure.closed.signal()
        }
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData; if chunk.isEmpty { break }; buffer.append(chunk)
                while let range = buffer.firstRange(of: Data([10])) {
                    let line = buffer[..<range.lowerBound]; buffer.removeSubrange(...range.lowerBound)
                    guard let event = try? JSONDecoder().decode(GatewayActivityEvent.self, from: line) else { continue }
                    Task { @MainActor in guard self?.generation == token else { return }; self?.onEvent?(event) }
                }
            }
        }
    }
    nonisolated static func reason(_ stderr: String, port: Int) -> String {
        if stderr.contains("port is already occupied") { return "端口 \(port) 已被占用，可能另一版本的 Tibot 仍在运行" }
        if stderr.contains("local credential registry unavailable") { return "Codex 当前登录未连接到 Tibot，或桌面凭据已过期" }
        if stderr.contains("configuration unavailable") { return "网关账号池不可用" }
        return "网关进程意外退出"
    }
    func install() throws { try configuration.install(key: key, port: port) }
    func stop(restore: Bool) throws {
        if restore { try configuration.restore() }
        generation = UUID(); if process?.isRunning == true { process?.terminate() }; process = nil
        // An access-token snapshot is unnecessary while stopped.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("pool.json"))
    }
}

private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    let closed = DispatchSemaphore(value: 0)
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); if data.count > 1024 { data = data.suffix(1024) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
