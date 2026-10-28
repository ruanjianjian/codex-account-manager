import AppKit
import AccountCore

@MainActor final class GatewayController {
    let root: URL
    let port: Int
    private var process: Process?
    private var key = ""
    private var generation = UUID()
    var onEvent: ((String, String?, Int?) -> Void)?
    var running: Bool { process?.isRunning == true }
    var configuration: GatewayConfiguration { GatewayConfiguration(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), root: root) }
    init(root: URL) { self.root = root.appendingPathComponent("gateway"); port = Bundle.main.bundleIdentifier?.contains("Public") == true || Bundle.main.bundleIdentifier?.contains("io.github") == true ? 18456 : 18455 }
    func save(accounts: [GatewayAccount], preferred: String) throws {
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
        let data = try JSONEncoder().encode(GatewayPool(key: key, preferred: preferred, accounts: accounts))
        try PrivateAtomicFile.write(data, to: root.appendingPathComponent("pool.json"))
    }
    func start() throws {
        guard !running else { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AccountsGateway")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw GatewayConfigurationError.unavailable }
        let p = Process(), out = Pipe()
        p.executableURL = binary; p.arguments = ["--config", root.appendingPathComponent("pool.json").path, "--listen", "127.0.0.1:\(port)"]
        p.environment = RPCClient.isolatedEnvironment(home: root, inherited: ProcessInfo.processInfo.environment)
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        process = p; let token = UUID(); generation = token
        p.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.process = nil; self.onEvent?("stopped", nil, nil)
        } }
        try p.run()
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData; if chunk.isEmpty { break }; buffer.append(chunk)
                while let range = buffer.firstRange(of: Data([10])) {
                    let line = buffer[..<range.lowerBound]; buffer.removeSubrange(...range.lowerBound)
                    guard let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let kind = e["kind"] as? String else { continue }
                    let id = e["account"] as? String, status = e["status"] as? Int
                    Task { @MainActor in guard self?.generation == token else { return }; self?.onEvent?(kind, id, status) }
                }
            }
        }
    }
    func install() throws { try configuration.install(key: key, port: port) }
    func stop(restore: Bool) throws {
        if restore { try configuration.restore() }
        generation = UUID(); if process?.isRunning == true { process?.terminate() }; process = nil
        // An access-token snapshot is unnecessary while stopped.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("pool.json"))
    }
}
