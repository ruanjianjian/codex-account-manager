import AppKit
import Security
import AccountCore

/// Reads which account the shared Codex desktop is signed in to, and migrates stored logins
/// to files. Never rewrites the desktop login: switching is the gateway's job.
@MainActor final class SharedDesktopLogin {
    let root: URL
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    var fileStore: CredentialFileStore { CredentialFileStore(root: root) }
    private var directory: URL { root.appendingPathComponent("desktop-switch") }
    private var selectionURL: URL { directory.appendingPathComponent("selection.json") }
    /// Marker an older build left when a desktop switch stopped halfway. Only reported, never acted on.
    var interruptedSwitch: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending").path) }
    private var receipt: DesktopSelection? {
        guard let data = try? Data(contentsOf: selectionURL) else { return nil }
        return try? JSONDecoder().decode(DesktopSelection.self, from: data)
    }
    /// The slot whose account is logged in to the shared desktop right now, if it is a known slot.
    func selection(accounts: [AccountSlot]) -> DesktopSelection? {
        DesktopSelection.live(desktopAccountID: desktopAccountID(), receipt: receipt, accounts: accounts)
    }
    private var cachedDesktop: (stamp: [String], accountID: String?, email: String?)?
    func desktopAccountID() -> String? { desktopLogin().accountID }
    /// Views ask for this on every render: re-parse auth.json only after it changes on disk.
    func desktopLogin() -> (accountID: String?, email: String?) {
        let url = home.appendingPathComponent("auth.json")
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { cachedDesktop = nil; return (nil, nil) }
        let stamp = [attributes[.systemFileNumber], attributes[.size], (attributes[.modificationDate] as? Date)?.timeIntervalSince1970].map { "\($0 ?? "-")" }
        if let cachedDesktop, cachedDesktop.stamp == stamp { return (cachedDesktop.accountID, cachedDesktop.email) }
        let credential = (try? Data(contentsOf: url)).flatMap { try? DesktopCredential($0) }
        cachedDesktop = (stamp, credential?.accountID, credential?.email)
        return (credential?.accountID, credential?.email)
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
    private func sourceKey(_ id: String) throws -> String {
        SharedDesktopPlan.keyringAccount(home: try DesktopLaunchPlan(root: root, accountID: id).home)
    }
    private func source(_ id: String, expected: String) throws -> DesktopCredential {
        if fileStore.enabled { return try fileStore.read(id, expected: expected) }
        return try DesktopCredential(readSecret(service: "Codex Auth", account: sourceKey(id)), expected: expected)
    }
    /// Called only following a storage-tradeoff confirmation and collector shutdown.
    func migrateToFiles(accounts: [AccountSlot], legacy: AccountDesktopLauncher) throws {
        guard !fileStore.enabled,
              accounts.allSatisfy({ legacy.running(root: root, id: $0.id) == nil }) else { throw DesktopSwitchFailure.busy }
        var credentials: [(String, DesktopCredential)] = []
        for slot in accounts {
            guard let expected = slot.expectedAccountID else { continue }
            let credential: DesktopCredential
            if selection(accounts: accounts)?.slotID == slot.id {
                credential = try DesktopCredential(Data(contentsOf: home.appendingPathComponent("auth.json")), expected: expected)
            } else { credential = try source(slot.id, expected: expected) }
            credentials.append((slot.id, credential))
        }
        try fileStore.activate(credentials)
    }
}
