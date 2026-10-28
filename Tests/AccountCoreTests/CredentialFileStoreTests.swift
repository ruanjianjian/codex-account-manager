import XCTest
@testable import AccountCore

final class CredentialFileStoreTests: XCTestCase {
    private func fixture(_ id: String, revision: Int = 1) throws -> DesktopCredential {
        try DesktopCredential(JSONSerialization.data(withJSONObject: ["tokens": ["account_id":id,"access_token":"synthetic-access-\(revision)","refresh_token":"synthetic-refresh-\(revision)"]]))
    }
    private func makeStore() throws -> CredentialFileStore {
        let base = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/test-artifacts/file-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return CredentialFileStore(root:base)
    }
    func testOptInIsRequiredAndAllPreparedCredentialsAreVerified() throws {
        let store = try makeStore()
        XCTAssertFalse(store.enabled)
        let a = try fixture("a"), b = try fixture("b")
        try store.activate([("account-a",a),("account-b",b)])
        XCTAssertTrue(CredentialFileStore(root:store.root).enabled)
        XCTAssertEqual(try store.read("account-a",expected:"a").data,a.data)
        XCTAssertEqual(try store.read("account-b",expected:"b").data,b.data)
        for id in ["account-a","account-b"] {
            let url = try store.auth(id)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int,0o600)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.deletingLastPathComponent().path)[.posixPermissions] as? Int,0o700)
        }
    }
    func testWrongIdentityOrSymlinkCannotActivateBackend() throws {
        let store = try makeStore()
        try store.write(fixture("unrelated"),id:"account-a")
        XCTAssertThrowsError(try store.activate([("account-a",fixture("a"))]))
        XCTAssertFalse(store.enabled)
        let target=store.root.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to:target)
        let path=try store.auth("account-b")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:path,withDestinationURL:target)
        XCTAssertThrowsError(try store.write(fixture("b"),id:"account-b"))
        XCTAssertEqual(try Data(contentsOf:target),Data("preserve".utf8))
    }
    func testExistingFileIsBackedUpAndRepeatedWritesPreservePrivateMode() throws {
        let store=try makeStore(), before=try fixture("a"), after=try fixture("a",revision:2)
        try store.write(before,id:"account-a")
        try store.activate([("account-a",after)])
        XCTAssertEqual(try Data(contentsOf:store.auth("account-a").appendingPathExtension("before-file-mode")),before.data)
        try store.write(fixture("a",revision:3),id:"account-a")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:store.auth("account-a").path)[.posixPermissions] as? Int,0o600)
    }
}
