import XCTest
@testable import AccountCore

final class DesktopLaunchPlanTests: XCTestCase {
    private var root: URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_ARTIFACTS_DIR"] ?? repo.appendingPathComponent(".build/test-artifacts").path)
            .appendingPathComponent(UUID().uuidString)
    }
    @MainActor func testOnlySelectedAccountHomeAndIsolatedUIStorageArePassed() throws {
        let root = root
        let first = try DesktopLaunchPlan(root: root, accountID: "account-1")
        let second = try DesktopLaunchPlan(root: root, accountID: "account-2")
        XCTAssertNotEqual(first.home, second.home)
        XCTAssertNotEqual(first.userData, second.userData)
        let env = first.environment(inherited: ["HOME": "/example/home", "CODEX_HOME": "/global", "OPENAI_API_KEY": "test-only", "CODEX_ACCESS_TOKEN": "test-only", "NODE_OPTIONS": "--require=unexpected.js", "CODEX_ELECTRON_USER_DATA_PATH": "/global-ui"])
        XCTAssertEqual(env["CODEX_HOME"], first.home.path)
        XCTAssertEqual(env["CODEX_ELECTRON_USER_DATA_PATH"], first.userData.path)
        XCTAssertNil(env["CODEX_ACCESS_TOKEN"]); XCTAssertNil(env["OPENAI_API_KEY"]); XCTAssertNil(env["NODE_OPTIONS"])
        XCTAssertEqual(first.arguments, ["--user-data-dir=\(first.userData.path)"])
    }
    func testTraversalAndSymlinkCannotSelectGlobalOrAnotherAccountHome() throws {
        let root = root
        for id in ["../.codex", "account-../x", "", "account-1/x"] {
            XCTAssertThrowsError(try DesktopLaunchPlan(root: root, accountID: id))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("accounts/account-1"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try DesktopLaunchPlan(root: root, accountID: "account-1"))
    }
    @MainActor func testCollectorDoesNotOverwriteDesktopConfiguration() async throws {
        let root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = "cli_auth_credentials_store = \"keyring\"\nmodel = \"example-model\"\n"
        let configURL = root.appendingPathComponent("config.toml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = RPCClient(home: root, executable: repo.appendingPathComponent("scripts/mock_rpc.py"))
        defer { client.stop() }
        _ = try await client.request("probe/fragment")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config)
    }
}
