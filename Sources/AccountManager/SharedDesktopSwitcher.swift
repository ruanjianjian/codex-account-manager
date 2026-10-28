import AppKit
import Security
import AccountCore

/// Only called after an explicit account-name click and restart confirmation.
/// No migration/copy of sessions, projects, preferences, or Electron data occurs.
@MainActor final class SharedDesktopSwitcher {
    let root: URL
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    var fileStore: CredentialFileStore { CredentialFileStore(root: root) }
    private var directory: URL { root.appendingPathComponent("desktop-switch") }
    private var selectionURL: URL { directory.appendingPathComponent("selection.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending") }
    var pending: Bool { FileManager.default.fileExists(atPath: pendingURL.path) }
    var selection: DesktopSelection? {
        guard let data = try? Data(contentsOf: selectionURL) else { return nil }
        return try? JSONDecoder().decode(DesktopSelection.self, from: data)
    }
    init(root: URL) { self.root = root }

    private func keychainQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func readSecret(service: String, account: String) throws -> Data {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            throw DesktopSwitchFailure.persistence
        }
        return data
    }
    private func saveSecret(_ data: Data, service: String, account: String) throws {
        let query = keychainQuery(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new[kSecValueData as String] = data
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw DesktopSwitchFailure.persistence }
        } else if status != errSecSuccess { throw DesktopSwitchFailure.persistence }
    }
    private func sourceKey(_ id: String) throws -> String {
        SharedDesktopPlan.keyringAccount(home: try DesktopLaunchPlan(root: root, accountID: id).home)
    }
    private func source(_ id: String, expected: String) throws -> DesktopCredential {
        if fileStore.enabled { return try fileStore.read(id, expected: expected) }
        return try DesktopCredential(readSecret(service: "Codex Auth", account: sourceKey(id)), expected: expected)
    }
    /// Called only following a storage-tradeoff confirmation and collector shutdown.
    func migrateToFiles(accounts: [AccountSlot], legacy: AccountDesktopLauncher) throws {
        guard !pending, !fileStore.enabled,
              accounts.allSatisfy({ legacy.running(root: root, id: $0.id) == nil }) else { throw DesktopSwitchFailure.busy }
        var credentials: [(String, DesktopCredential)] = []
        for slot in accounts {
            guard let expected = slot.expectedAccountID else { continue }
            let credential: DesktopCredential
            if selection?.slotID == slot.id {
                credential = try DesktopCredential(Data(contentsOf: home.appendingPathComponent("auth.json")), expected: expected)
            } else { credential = try source(slot.id, expected: expected) }
            credentials.append((slot.id, credential))
        }
        try fileStore.activate(credentials)
    }
    private func saveSwitchBackup(_ data: Data, name: String) throws {
        if fileStore.enabled { try writePrivate(data, to: directory.appendingPathComponent(name + ".json")) }
        else { try saveSecret(data, service: "io.github.ruanjianjian.codex-accounts.DesktopSwitch", account: name) }
    }
    private func readSwitchBackup(_ name: String) throws -> Data {
        if fileStore.enabled { return try Data(contentsOf: directory.appendingPathComponent(name + ".json")) }
        return try readSecret(service: "io.github.ruanjianjian.codex-accounts.DesktopSwitch", account: name)
    }
    private func saveSelection(_ selection: DesktopSelection?) throws {
        if let selection { try writePrivate(try JSONEncoder().encode(selection), to: selectionURL) }
        else if FileManager.default.fileExists(atPath: selectionURL.path) { try FileManager.default.removeItem(at: selectionURL) }
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try PrivateAtomicFile.write(data, to: url)
    }

    private func codexApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
    }
    private func validateApp() throws -> URL {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.openai.codex",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ["26.1021.31345", "26.1023.50603"].contains(version) else {
            throw DesktopLaunchError.unsupportedApp
        }
        return app
    }
    private func stopped() -> Bool {
        guard codexApps().isEmpty else { return false }
        // Never replace shared credentials while another CLI/server might still be using them.
        // Collectors are drained by AppStore first. No force termination of unrelated processes.
        for name in ["codex", "codex-app-server"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]; process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() } catch { return false }
            guard process.terminationStatus == 1 else { return false }
        }
        return true
    }
    private func processSnapshot() throws -> [DesktopSwitchProcess] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DesktopSwitchFailure.processInspection }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw DesktopSwitchFailure.processInspection
        }
        return try DesktopSwitchProcess.parse(text)
    }
    /// Run before draining collectors or asking the desktop to quit.
    func preflight(accounts: [AccountSlot], legacy: AccountDesktopLauncher, allowCollectors: Bool = true) throws {
        _ = try validateApp()
        let apps = codexApps()
        guard accounts.allSatisfy({ legacy.running(root: root, id: $0.id) == nil }), apps.count <= 1 else {
            throw DesktopSwitchFailure.activeWindows
        }
        var allowed = Set(apps.map(\.processIdentifier))
        if allowCollectors { allowed.insert(ProcessInfo.processInfo.processIdentifier) }
        let blockers = DesktopSwitchProcess.blockers(in: try processSnapshot(), allowedRoots: allowed)
        guard blockers.isEmpty else { throw DesktopSwitchFailure.otherProcesses(blockers) }
    }
    func switchAccount(slot: AccountSlot, accounts: [AccountSlot], legacy: AccountDesktopLauncher) async throws {
        try preflight(accounts: accounts, legacy: legacy, allowCollectors: false)
        let appURL = try validateApp()
        let plan = try SharedDesktopPlan(home: home)
        let configURL = home.appendingPathComponent("config.toml")
        let config = FileManager.default.fileExists(atPath: configURL.path) ? try String(contentsOf: configURL, encoding: .utf8) : ""
        try plan.validateConfiguration(config)
        guard let expected = slot.expectedAccountID else { throw DesktopSwitchFailure.identity }
        // Old isolated windows stay intact; the user must close them before a shared-home switch.
        guard accounts.allSatisfy({ legacy.running(root: root, id: $0.id) == nil }), codexApps().count <= 1 else {
            throw DesktopSwitchFailure.activeWindows
        }
        // Read and validate everything we can before asking an application to exit.
        let target = pending ? nil : try source(slot.id, expected: expected)
        if !pending { _ = try DesktopCredential(Data(contentsOf: plan.auth)) }
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw DesktopSwitchFailure.persistence }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let beforeApps = codexApps()
        for app in beforeApps { guard app.terminate() else { throw DesktopSwitchFailure.desktopStillRunning } }
        for _ in 0..<60 {
            if stopped() { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard codexApps().isEmpty else { throw DesktopSwitchFailure.desktopStillRunning }
        let blockers = DesktopSwitchProcess.blockers(in: try processSnapshot(), allowedRoots: [])
        guard blockers.isEmpty else { throw DesktopSwitchFailure.otherProcesses(blockers) }
        guard stopped() else { throw DesktopSwitchFailure.busy }

        let lock = home.appendingPathComponent("auth.lock")
        guard lock.standardizedFileURL.path == lock.resolvingSymlinksInPath().path else { throw DesktopSwitchFailure.persistence }
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DesktopSwitchFailure.persistence }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DesktopSwitchFailure.authLocked }
        let ports = DesktopSwitchPorts(
            readDesktop: { try Data(contentsOf: plan.auth) },
            writeDesktop: { try self.writePrivate($0, to: plan.auth) },
            saveRollback: { try self.saveSwitchBackup($0, name: "rollback") },
            loadRollback: { try self.readSwitchBackup("rollback") },
            saveOutgoing: { outgoing in
                // Preserve the newest refresh state, but only in an already-matching known slot.
                if let match = accounts.first(where: { $0.expectedAccountID == outgoing.accountID }) {
                    if self.fileStore.enabled { try self.fileStore.write(outgoing, id: match.id) }
                    else {
                        let key = try self.sourceKey(match.id)
                        try self.saveSecret(outgoing.data, service: "Codex Auth", account: key)
                    }
                } else {
                    try self.saveSwitchBackup(outgoing.data, name: "unlisted-outgoing")
                }
            },
            saveSelection: { try self.saveSelection($0) },
            setPending: { pending in
                if pending { try self.writePrivate(Data("pending\n".utf8), to: self.pendingURL) }
                else if self.pending { try FileManager.default.removeItem(at: self.pendingURL) }
            },
            isDesktopStopped: { self.stopped() },
            launch: {
                // Use the existing default Electron profile. Never pass --user-data-dir here.
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.environment = RPCClient.isolatedEnvironment(home: self.home, inherited: ProcessInfo.processInfo.environment)
                do { _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) }
                catch { throw DesktopSwitchFailure.launch }
            })
        if pending {
            try DesktopSwitchTransaction.recover(ports: ports)
            // A recovery is a separate action; do not immediately overwrite the restored identity.
            throw DesktopSwitchFailure.recovery
        }
        let current = try DesktopCredential(Data(contentsOf: plan.auth))
        // When already on the requested identity, use the latest shared-home refresh state.
        guard let target else { throw DesktopSwitchFailure.identity }
        let actualTarget = current.accountID == expected ? current : target
        try await DesktopSwitchTransaction.run(target: actualTarget,
            selection: DesktopSelection(slotID: slot.id, accountID: expected), previous: selection, ports: ports)
    }
}
