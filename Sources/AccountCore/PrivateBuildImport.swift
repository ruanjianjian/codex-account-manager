import Foundation

/// Brings accounts over from the private build's data folder, so moving to this build needs no new sign-ins.
public enum PrivateBuildImport {
    public static let folderName = "CodexAccountManager"

    public struct Plan {
        public let accounts: [AccountSlot]
        /// Logins to store for this build, by account slot.
        public let credentials: [(String, DesktopCredential)]
        /// Accounts left behind because no login could be read for them.
        public let skipped: Int
    }

    /// Reads the private build's accounts and their logins: its login files, or the Keychain item the
    /// Codex CLI kept for that account's home (`keychain`). The account the desktop is signed in to
    /// takes the desktop's live login. Returns nil when there is no private build data.
    public static func plan(privateRoot: URL, desktop: DesktopCredential?,
                            keychain: (_ home: URL) -> Data?) throws -> Plan? {
        let stateURL = privateRoot.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL)).migrated()
        let files = CredentialFileStore(root: privateRoot)
        var accounts: [AccountSlot] = [], credentials: [(String, DesktopCredential)] = [], skipped = 0
        for slot in state.accounts {
            guard let expected = slot.expectedAccountID else { continue }
            let credential: DesktopCredential?
            if let desktop, desktop.accountID == expected {
                credential = desktop
            } else if let stored = try? files.read(slot.id, expected: expected) {
                credential = stored
            } else if let home = try? DesktopLaunchPlan(root: privateRoot, accountID: slot.id).home,
                      let data = keychain(home) {
                credential = try? DesktopCredential(data, expected: expected)
            } else {
                credential = nil
            }
            guard let credential else { skipped += 1; continue }
            accounts.append(slot); credentials.append((slot.id, credential))
        }
        return Plan(accounts: accounts, credentials: credentials, skipped: skipped)
    }
}
