import XCTest
@testable import AccountCore

final class DesktopLoginTests: XCTestCase {
    func auth(_ id: String, revision: Int = 1) -> Data {
        // Synthetic credentials only. Never invoke Security or a real Codex process in these tests.
        try! JSONSerialization.data(withJSONObject: ["tokens": ["account_id": id,
            "access_token": "test-access-\(revision)", "refresh_token": "test-refresh-\(revision)"]], options: .sortedKeys)
    }
    func slots(_ ids: [String: String]) -> [AccountSlot] {
        ids.sorted { $0.key < $1.key }.map { var slot = AccountSlot(id: $0.key, name: $0.key, chromeProfile: "dedicated"); slot.expectedAccountID = $0.value; return slot }
    }
    func testLiveDesktopLoginOverridesStaleReceipt() {
        let accounts = slots(["account-a": "a", "account-b": "b", "account-c": "c"])
        let stale = DesktopSelection(slotID: "account-a", accountID: "a")
        XCTAssertEqual(DesktopSelection.live(desktopAccountID: "c", receipt: stale, accounts: accounts), .init(slotID: "account-c", accountID: "c"))
        XCTAssertEqual(DesktopSelection.live(desktopAccountID: "a", receipt: stale, accounts: accounts), stale)
        XCTAssertNil(DesktopSelection.live(desktopAccountID: "unlisted", receipt: stale, accounts: accounts))
        XCTAssertNil(DesktopSelection.live(desktopAccountID: nil, receipt: stale, accounts: accounts))
        let twins = slots(["account-a": "a", "account-z": "a"])
        XCTAssertEqual(DesktopSelection.live(desktopAccountID: "a", receipt: .init(slotID: "account-z", accountID: "a"), accounts: twins)?.slotID, "account-z")
    }
    func testWrongTargetAndNonChatGPTCredentialsAreRejected() throws {
        XCTAssertThrowsError(try DesktopCredential(auth("a"), expected: "b"))
        XCTAssertThrowsError(try DesktopCredential(Data("{\"OPENAI_API_KEY\":\"test\"}".utf8)))
        XCTAssertThrowsError(try DesktopCredential(Data("{}".utf8)))
    }
    func testSharedHomeRejectsUnsupportedCredentialModesAndLeavesConfigurationUnchanged() throws {
        let p = try SharedDesktopPlan(home: URL(fileURLWithPath: "/example/.codex"))
        try p.validateConfiguration("model = \"test\"\n[projects.\"/example/project\"]\ntrust_level = \"trusted\"")
        try p.validateConfiguration("cli_auth_credentials_store = 'file' # default\n")
        for mode in ["keyring", "auto", "ephemeral"] {
            XCTAssertThrowsError(try p.validateConfiguration("cli_auth_credentials_store = \"\(mode)\""))
        }
        XCTAssertThrowsError(try p.validateConfiguration("forced_login_method = \"api\""))
        XCTAssertEqual(p.auth.path, "/example/.codex/auth.json")
    }
    func testRealAtomicReplacementPreservesSessionProjectAndConfigurationFiles() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_ARTIFACTS_DIR"] ?? repo.appendingPathComponent(".build/test-artifacts").path)
            .appendingPathComponent("shared-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinels = ["config.toml", "sessions.jsonl", "state.sqlite", "projects.json"]
        for name in sentinels { try Data("original-\(name)".utf8).write(to: root.appendingPathComponent(name)) }
        try PrivateAtomicFile.write(auth("a"), to: root.appendingPathComponent("auth.json"))
        try PrivateAtomicFile.write(auth("b"), to: root.appendingPathComponent("auth.json"))
        for name in sentinels {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("original-\(name)".utf8))
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("auth.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("auth.json")), auth("b"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".account-switch-") }))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("projects.json"))
        XCTAssertThrowsError(try PrivateAtomicFile.write(auth("c"), to: link))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("projects.json")), Data("original-projects.json".utf8))
    }
}
