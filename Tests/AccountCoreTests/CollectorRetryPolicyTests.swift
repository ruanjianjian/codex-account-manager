import XCTest
@testable import AccountCore

final class CollectorRetryPolicyTests: XCTestCase {
    func testKeychainFailureAndTimeoutRemainPausedAcrossReloadUntilAccountRetry() {
        var policy = CollectorRetryPolicy()
        XCTAssertTrue(policy.record(ClientFailure.keychainAccess, account: "a", usesKeyring: true))
        XCTAssertTrue(policy.record(ClientFailure.timeout, account: "b", usesKeyring: true))
        var restored = CollectorRetryPolicy(paused: policy.paused)
        XCTAssertEqual(restored.paused, ["a", "b"])
        restored.resume("a")
        XCTAssertEqual(restored.paused, ["b"])
    }
    func testFileStoreAndOrdinaryServiceErrorsKeepNormalRetry() {
        var policy = CollectorRetryPolicy()
        XCTAssertFalse(policy.record(ClientFailure.timeout, account: "file", usesKeyring: false))
        XCTAssertFalse(policy.record(ClientFailure.service(503), account: "network", usesKeyring: true))
        XCTAssertFalse(policy.record(ClientFailure.disconnected, account: "stopped", usesKeyring: true))
        XCTAssertTrue(policy.paused.isEmpty)
    }
}
