import Foundation

/// Explicit opt-in only. Matches Codex's file credential mode, with private paths.
/// Existing Keychain items are never changed or deleted by migration.
public struct CredentialFileStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var marker: URL { root.appendingPathComponent("file-credentials.enabled") }
    public var enabled: Bool { (try? Data(contentsOf: marker)) == Data("v1\n".utf8) }
    public func auth(_ id: String) throws -> URL {
        try DesktopLaunchPlan(root: root, accountID: id).home.appendingPathComponent("auth.json")
    }
    public func read(_ id: String, expected: String) throws -> DesktopCredential {
        try DesktopCredential(Data(contentsOf: auth(id)), expected: expected)
    }
    public func write(_ credential: DesktopCredential, id: String) throws {
        let url = try auth(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try PrivateAtomicFile.write(credential.data, to: url)
    }
    public func activate(_ credentials: [(String, DesktopCredential)]) throws {
        // An empty list is a fresh install opting in before its first login (some Codex builds cannot write the Keychain).
        guard !enabled, Set(credentials.map { $0.0 }).count == credentials.count else { throw DesktopSwitchFailure.persistence }
        // Retain any previous file verbatim before replacing it. The original Keychain is retained too.
        for (id, credential) in credentials {
            let url = try auth(id), backup = url.appendingPathExtension("before-file-mode")
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                _ = try DesktopCredential(existing, expected: credential.accountID)
                if existing != credential.data {
                    guard !FileManager.default.fileExists(atPath: backup.path) else { throw DesktopSwitchFailure.persistence }
                    try PrivateAtomicFile.write(existing, to: backup)
                }
            }
        }
        for (id, credential) in credentials { try write(credential, id: id) }
        for (id, credential) in credentials {
            guard try read(id, expected: credential.accountID).data == credential.data else { throw DesktopSwitchFailure.persistence }
        }
        // Only this last atomic operation enables the new backend. Partial preparation remains inactive.
        try PrivateAtomicFile.write(Data("v1\n".utf8), to: marker)
    }
}
