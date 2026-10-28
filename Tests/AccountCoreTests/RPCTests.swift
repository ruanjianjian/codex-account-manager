import XCTest
@testable import AccountCore

final class RPCTests: XCTestCase {
    @MainActor private func makeClient() -> RPCClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_ARTIFACTS_DIR"] ?? root.appendingPathComponent(".test-artifacts").path).appendingPathComponent("rpc-tests/\(UUID().uuidString)")
        return RPCClient(home: home, executable: root.appendingPathComponent("scripts/mock_rpc.py"))
    }
    @MainActor func testFragmentedResponseAndNotificationDoNotLoseRequests() async throws {
        let client = makeClient(); defer { client.stop() }
        var notified = false
        client.onNotification = { method, params in if method == "account/rateLimits/updated" && params["fixture"] as? Bool == true { notified = true } }
        let result = try await client.request("probe/fragment")
        XCTAssertEqual(result["fragmented"] as? Bool, true)
        _ = try await client.request("probe/notify")
        XCTAssertTrue(notified)
    }
    @MainActor func testTimeoutDoesNotDestroyPersistentConnection() async throws {
        let client = makeClient(); defer { client.stop() }
        do { _ = try await client.request("probe/timeout", timeout: 0.05); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error.localizedDescription, ClientFailure.timeout.localizedDescription) }
        let result = try await client.request("probe/fragment")
        XCTAssertEqual(result["fragmented"] as? Bool, true)
    }
    @MainActor func testRawCredentialErrorsNeverEscape() async throws {
        let client = makeClient(); defer { client.stop() }
        do { _ = try await client.request("probe/error"); XCTFail("Expected auth failure") }
        catch { XCTAssertEqual(error.localizedDescription, ClientFailure.authentication.localizedDescription); XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
    @MainActor func testProcessExitFailsPendingRequestAndCanRestart() async throws {
        let client = makeClient(); defer { client.stop() }
        do { _ = try await client.request("probe/disconnect"); XCTFail("Expected disconnection") }
        catch { XCTAssertEqual(error.localizedDescription, ClientFailure.disconnected.localizedDescription) }
        let result = try await client.request("probe/fragment")
        XCTAssertEqual(result["fragmented"] as? Bool, true)
    }
}
