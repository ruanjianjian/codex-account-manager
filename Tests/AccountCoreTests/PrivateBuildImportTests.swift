import XCTest
@testable import AccountCore

final class PrivateBuildImportTests: XCTestCase {
    func auth(_ id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tokens": ["account_id": id, "access_token": "x-\(id)", "refresh_token": "y-\(id)"]])
    }
    func slot(_ id: String, _ accountID: String?, name: String? = nil) -> AccountSlot {
        var slot = AccountSlot(id: id, name: "新账号", chromeProfile: "dedicated")
        slot.expectedAccountID = accountID; slot.nameOverride = name
        return slot
    }
    func privateRoot(_ accounts: [AccountSlot], files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(SavedState(accounts: accounts)).write(to: root.appendingPathComponent("state.json"))
        let store = CredentialFileStore(root: root)
        for (id, data) in files { try store.write(DesktopCredential(data), id: id) }
        return root
    }

    func testImportsAccountsWithTheirLoginsAndSkipsOnlyThoseWithout() throws {
        let root = try privateRoot([slot("account-desk", "d", name: "工作"), slot("account-file", "f"), slot("account-keychain", "k"),
                                    slot("account-none", "n"), slot("account-pending", nil)],
                                   files: ["account-file": auth("f")])
        defer { try? FileManager.default.removeItem(at: root) }
        let keychainHome = try DesktopLaunchPlan(root: root, accountID: "account-keychain").home
        let plan = try XCTUnwrap(PrivateBuildImport.plan(privateRoot: root, desktop: DesktopCredential(auth("d")),
                                                         keychain: { $0 == keychainHome ? self.auth("k") : nil }))
        XCTAssertEqual(plan.accounts.map(\.id), ["account-desk", "account-file", "account-keychain"])
        XCTAssertEqual(plan.accounts.first?.nameOverride, "工作", "names and settings come over as they were")
        XCTAssertEqual(plan.credentials.map(\.1.accountID), ["d", "f", "k"])
        XCTAssertEqual(plan.skipped, 1, "only the account with no readable login is left to sign in again")
    }

    func testWrongAccountLoginIsNotImportedAndNoDataMeansNoPlan() throws {
        let root = try privateRoot([slot("account-a", "a")], files: ["account-a": auth("someone-else")])
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try XCTUnwrap(PrivateBuildImport.plan(privateRoot: root, desktop: nil, keychain: { _ in nil }))
        XCTAssertTrue(plan.accounts.isEmpty); XCTAssertEqual(plan.skipped, 1)
        XCTAssertNil(try PrivateBuildImport.plan(privateRoot: root.appendingPathComponent("missing"), desktop: nil, keychain: { _ in nil }))
    }
}
