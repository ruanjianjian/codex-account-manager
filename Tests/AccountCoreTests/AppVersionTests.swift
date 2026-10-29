import XCTest
@testable import AccountCore

final class AppVersionTests: XCTestCase {
    func testComparesReleaseTagsWithTheAppVersion() {
        XCTAssertTrue(AppVersion.isNewer("v0.4.7-beta.1", than: "0.4.6"))
        XCTAssertTrue(AppVersion.isNewer("v0.10.0-beta.1", than: "0.9.9"))
        XCTAssertFalse(AppVersion.isNewer("v0.4.6-beta.1", than: "0.4.6"), "same version is not an update")
        XCTAssertFalse(AppVersion.isNewer("v0.4.5-beta.1", than: "0.4.6"), "never downgrade")
    }
    func testReadsTheInstallersLatestTagAndChecksums() {
        let script = "#!/bin/bash\nset -e\nLATEST=\"v0.4.7-beta.1\"\nREPO=x\n"
        XCTAssertEqual(AppVersion.latestTag(inInstaller: script), "v0.4.7-beta.1")
        XCTAssertNil(AppVersion.latestTag(inInstaller: "LATEST=\"$(rm -rf /)\"\n"))
        let sums = "\(String(repeating: "a", count: 64))  Codex-Accounts-v0.4.7-beta.1-macos-arm64.zip\n"
        XCTAssertEqual(AppVersion.checksum(for: "Codex-Accounts-v0.4.7-beta.1-macos-arm64.zip", in: sums), String(repeating: "a", count: 64))
        XCTAssertNil(AppVersion.checksum(for: "other.zip", in: sums))
    }
}
