import AppKit
import AccountCore

/// Keeps the gateway installed as a launchd agent and watches it over its event stream. The gateway does not
/// depend on Tibot: quitting, updating or a crash of Tibot leave Codex's requests served.
@MainActor final class GatewayController {
    let root: URL
    let port: Int
    let agent: GatewayAgent
    private var key = ""
    private var watcher: Task<Void, Never>?
    private var killedChildren = false
    var onEvent: ((GatewayActivityEvent) -> Void)?
    /// The event stream is up: the gateway answers.
    private(set) var running = false
    var configuration: GatewayConfiguration { GatewayConfiguration(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), root: root) }
    init(root: URL) {
        self.root = root.appendingPathComponent("gateway")
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.ruanjianjian.codex-accounts"
        port = bundleID.contains("Public") || bundleID.contains("io.github") ? 18456 : 18455
        let home = FileManager.default.homeDirectoryForCurrentUser
        agent = GatewayAgent(bundleID: bundleID, directory: self.root, port: port,
                             desktopAuth: home.appendingPathComponent(".codex/auth.json"),
                             launchAgents: home.appendingPathComponent("Library/LaunchAgents"))
    }
    func save(accounts: [GatewayAccount], preferred: String, clients: [GatewayClientIdentity], off: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try loadKey()
        let data = try JSONEncoder().encode(GatewayPool(key: key, preferred: preferred, accounts: accounts, clients: clients, off: off))
        try PrivateAtomicFile.write(data, to: agent.pool)
    }
    /// Routing off: no account tokens on disk, and Codex's own login goes straight through. The connected
    /// identities stay, so the gateway keeps recognizing those logins for when routing is back.
    func saveOff(clients: [GatewayClientIdentity]) throws { try save(accounts: [], preferred: "", clients: clients, off: true) }
    private func loadKey() throws {
        guard key.isEmpty else { return }
        let keyFile = root.appendingPathComponent("local.key")
        if FileManager.default.fileExists(atPath: keyFile.path) {
            key = try String(contentsOf: keyFile, encoding: .utf8)
            guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw GatewayConfigurationError.unavailable }
        } else {
            key = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try PrivateAtomicFile.write(Data(key.utf8), to: keyFile)
        }
    }
    /// Installs or updates the agent and starts watching it. A new binary takes over once no reply is in flight.
    func start() throws {
        try loadKey()
        // Watch first: a gateway already running keeps being seen even if updating its agent fails.
        watch()
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AccountsGateway")
        guard let binary = try? Data(contentsOf: bundled) else { throw GatewayConfigurationError.unavailable }
        let fm = FileManager.default
        var newBinary = false
        if (try? Data(contentsOf: agent.binary)) != binary {
            let temp = root.appendingPathComponent(".AccountsGateway-\(UUID().uuidString)")
            try binary.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            // A rename: the running gateway keeps its own file until it restarts on this one.
            guard rename(temp.path, agent.binary.path) == 0 else { try? fm.removeItem(at: temp); throw GatewayConfigurationError.unavailable }
            newBinary = true
        }
        let plist = try agent.plist()
        let newPlist = (try? Data(contentsOf: agent.plistURL)) != plist
        if newPlist {
            try fm.createDirectory(at: agent.launchAgents, withIntermediateDirectories: true)
            try plist.write(to: agent.plistURL, options: .atomic)
        }
        if !killedChildren {
            // A gateway an older Tibot started as its child keeps the port until it exits.
            killedChildren = true
            _ = Self.run("/usr/bin/pkill", ["-f", agent.childPattern])
        }
        let service = "gui/\(getuid())/\(agent.label)"
        let loaded = Self.run("/bin/launchctl", ["print", service]).status == 0
        if newPlist || !loaded {
            if loaded { _ = Self.run("/bin/launchctl", ["bootout", service]) }
            let boot = Self.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agent.plistURL.path])
            if boot.status != 0 && Self.run("/bin/launchctl", ["print", service]).status != 0 {
                let disabled = Self.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]).output
                    .contains("\"\(agent.label)\" => disabled")
                throw disabled ? GatewayConfigurationError.disabled : GatewayConfigurationError.unavailable
            }
        } else if newBinary {
            restartWhenIdle(service)
        }
    }
    /// The program other than the gateway listening on its port, if any: the gateway cannot start while it does.
    func portHolder() -> String? {
        let pids = Self.run("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]).output.split(separator: "\n")
        for pid in pids {
            let name = URL(fileURLWithPath: Self.run("/bin/ps", ["-o", "comm=", "-p", String(pid)]).output.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
            if !name.isEmpty && name != "AccountsGateway" { return name }
        }
        return nil
    }
    /// Brings back a gateway that stays away: loads the agent again if something unloaded it, otherwise restarts
    /// it (a hang launchd cannot see).
    func revive() {
        let service = "gui/\(getuid())/\(agent.label)"
        if Self.run("/bin/launchctl", ["print", service]).status == 0 { _ = Self.run("/bin/launchctl", ["kickstart", "-k", service]) }
        else { try? start() }
    }
    private func restartWhenIdle(_ service: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tibot/restart")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        Task {
            let accepted = (try? await Self.session.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 202 } ?? false
            if !accepted { _ = Self.run("/bin/launchctl", ["kickstart", "-k", service]) }
        }
    }
    func install() throws { try loadKey(); try configuration.install(key: key, port: port) }
    func stopWatching() { watcher?.cancel(); watcher = nil; running = false }

    /// Loopback only, never through a proxy; a stream silent for 40 s (the gateway pings every 15 s) is a gateway
    /// that stopped answering.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: false, kCFNetworkProxiesHTTPSEnable: false, kCFNetworkProxiesSOCKSEnable: false]
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 365 * 24 * 3600
        return URLSession(configuration: config)
    }()
    private func watch() {
        guard watcher == nil else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tibot/events")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        watcher = Task { [weak self] in
            var delay = 0.5
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    for try await line in bytes.lines {
                        guard let event = GatewayActivityEvent.streamLine(line) else { continue }
                        if event.kind == "ready" { delay = 0.5 }
                        self?.deliver(event)
                    }
                } catch {}
                if Task.isCancelled { break }
                self?.lost()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); delay = min(delay * 2, 5)
            }
        }
    }
    private func deliver(_ event: GatewayActivityEvent) {
        if event.kind == "ready" { running = true }
        onEvent?(event)
    }
    private func lost() {
        guard running else { return }
        running = false
        onEvent?(.init(kind: "stopped", reason: L("网关没有响应", "the gateway is not answering")))
    }
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        p.standardOutput = out; p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
