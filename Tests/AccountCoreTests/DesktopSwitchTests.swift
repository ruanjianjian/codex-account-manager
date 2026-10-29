import XCTest
@testable import AccountCore

@MainActor final class DesktopSwitchTests: XCTestCase {
    enum Failure: Error { case injected }
    func auth(_ id: String, revision: Int = 1) -> Data {
        // Synthetic credentials only. Never invoke Security or a real Codex process in these tests.
        try! JSONSerialization.data(withJSONObject: ["tokens": ["account_id": id,
            "access_token": "test-access-\(revision)", "refresh_token": "test-refresh-\(revision)"]], options: .sortedKeys)
    }
    @MainActor final class Harness {
        var desktop: Data
        var rollback = Data()
        var outgoing: Data?
        var selected: DesktopSelection? = .init(slotID: "account-a", accountID: "a")
        var pending = false
        var stopped = true
        var launched = 0
        var failBackup = false
        var failLaunch = false
        var failClearPending = false
        var changeAfterBackup: Data?
        init(_ data: Data) { desktop = data }
        var ports: DesktopSwitchPorts {
            .init(readDesktop: { self.desktop }, writeDesktop: { self.desktop = $0 },
                  saveRollback: { if self.failBackup { throw Failure.injected }; self.rollback = $0 },
                  loadRollback: { self.rollback }, saveOutgoing: { self.outgoing = $0.data },
                  saveSelection: { self.selected = $0 }, setPending: {
                      if !$0 && self.failClearPending { throw Failure.injected }
                      self.pending = $0
                      if $0, let change = self.changeAfterBackup { self.desktop = change }
                  }, isDesktopStopped: { self.stopped }, launch: {
                      if self.failLaunch { throw Failure.injected }
                      self.launched += 1; self.stopped = false
                  })
        }
    }
    func switchToB(_ h: Harness) async throws {
        try await DesktopSwitchTransaction.run(target: DesktopCredential(auth("b")),
            selection: .init(slotID: "account-b", accountID: "b"), previous: h.selected, ports: h.ports)
    }
    func testPreservesLatestOutgoingAndChangesOnlySelectedIdentity() async throws {
        let h = Harness(auth("a", revision: 4))
        try await switchToB(h)
        XCTAssertEqual(h.outgoing, auth("a", revision: 4))
        XCTAssertEqual(h.desktop, auth("b")); XCTAssertEqual(h.selected?.accountID, "b")
        XCTAssertFalse(h.pending); XCTAssertEqual(h.launched, 1)
        let backup = try JSONDecoder().decode(DesktopRollback.self, from: h.rollback)
        XCTAssertEqual(backup.auth, auth("a", revision: 4))
    }
    func testLaunchFailureRestoresOriginalIdentityAndSelection() async throws {
        let h = Harness(auth("a")); h.failLaunch = true
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertEqual(h.desktop, auth("a")); XCTAssertEqual(h.selected?.accountID, "a")
        XCTAssertFalse(h.pending); XCTAssertEqual(h.launched, 0)
    }
    func testBackupFailureNeverWritesDesktopOrLaunches() async throws {
        let h = Harness(auth("a")); h.failBackup = true
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertEqual(h.desktop, auth("a")); XCTAssertEqual(h.launched, 0); XCTAssertFalse(h.pending)
    }
    func testConcurrentCredentialChangeIsNotOverwrittenByRollback() async throws {
        let h = Harness(auth("a")); h.changeAfterBackup = auth("c")
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertEqual(h.desktop, auth("c")); XCTAssertEqual(h.launched, 0); XCTAssertFalse(h.pending)
    }
    func testRunningDesktopBlocksCredentialWrites() async throws {
        let h = Harness(auth("a")); h.stopped = false
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertEqual(h.desktop, auth("a")); XCTAssertTrue(h.rollback.isEmpty)
    }
    func testManualAccountChangeIsNotSavedIntoPreviousAccount() async throws {
        let h = Harness(auth("c"))
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertNil(h.outgoing); XCTAssertTrue(h.rollback.isEmpty)
        XCTAssertEqual(h.desktop, auth("c"))
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
    func testSwitchAfterLoginInsideCodexUsesLiveDesktopAsPrevious() async throws {
        // The faulty machine: receipt says A, Codex itself is logged in to C. Switching to B must
        // save C's latest login into C, not refuse after Codex was already closed.
        let h = Harness(auth("c", revision: 7))
        let previous = DesktopSelection.live(desktopAccountID: "c", receipt: h.selected, accounts: slots(["account-a": "a", "account-b": "b", "account-c": "c"]))
        try await DesktopSwitchTransaction.run(target: DesktopCredential(auth("b")),
            selection: .init(slotID: "account-b", accountID: "b"), previous: previous, ports: h.ports)
        XCTAssertEqual(h.outgoing, auth("c", revision: 7))
        XCTAssertEqual(h.desktop, auth("b")); XCTAssertEqual(h.selected?.slotID, "account-b"); XCTAssertEqual(h.launched, 1)
        let backup = try JSONDecoder().decode(DesktopRollback.self, from: h.rollback)
        XCTAssertEqual(backup.selection?.slotID, "account-c")
    }
    func testCrashAfterLaunchRequiresStoppedProcessBeforeRecovery() async throws {
        let h = Harness(auth("a")); h.failClearPending = true
        do { try await switchToB(h); XCTFail("must fail") } catch {}
        XCTAssertTrue(h.pending); XCTAssertEqual(h.desktop, auth("b"))
        XCTAssertThrowsError(try DesktopSwitchTransaction.recover(ports: h.ports))
        XCTAssertEqual(h.desktop, auth("b"))
        h.stopped = true; h.failClearPending = false
        try DesktopSwitchTransaction.recover(ports: h.ports)
        XCTAssertEqual(h.desktop, auth("a")); XCTAssertEqual(h.selected?.accountID, "a"); XCTAssertFalse(h.pending)
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
