import XCTest
@testable import AccountCore

final class ModelsTests: XCTestCase {
    override func setUp() { L10n.choice = .zh } // these check the Chinese wording
    func testArbitraryAccountCountAndEmptyStateSurviveMigration() throws {
        XCTAssertTrue(try SavedState().migrated().accounts.isEmpty)
        let slots = (1...30).map { AccountSlot(id: "account-test-\($0)", name: "Slot \($0)", chromeProfile: "Default") }
        let state = try SavedState(accounts: slots).migrated()
        XCTAssertEqual(state.accounts.map(\.id), slots.map(\.id))
        XCTAssertFalse(AccountSlot.validID("account-../../escape"))
        XCTAssertFalse(AccountSlot.validID("../account-other"))
    }
    func testFourAccountMigrationPreservesIdentityAndPreferences() throws {
        var state = SavedState(accounts: AccountSlot.defaults)
        state.version = 1; state.accounts = Array(AccountSlot.defaults.prefix(4))
        state.accounts[0].name = "Custom"
        state.accounts[0].expectedAccountID = "bound-id"
        state.accounts[0].chromeProfile = "Profile 9"
        state.notificationsEnabled = true
        let result = try state.migrated()
        XCTAssertEqual(result.version, 3)
        XCTAssertEqual(result.accounts.count, 4)
        XCTAssertEqual(result.accounts[0].name, "Custom")
        XCTAssertEqual(result.accounts[0].expectedAccountID, "bound-id")
        XCTAssertEqual(result.accounts[0].chromeProfile, "Profile 9")
        XCTAssertTrue(result.notificationsEnabled)
        XCTAssertEqual(try result.migrated().accounts.map(\.id), result.accounts.map(\.id))
    }
    func testMigrationRejectsUnknownOrDuplicateSlotsWithoutOverwritingState() {
        var state = SavedState(accounts: AccountSlot.defaults)
        state.accounts[5] = state.accounts[0]
        XCTAssertThrowsError(try state.migrated())
        state = SavedState(accounts: AccountSlot.defaults); state.version = 99
        XCTAssertThrowsError(try state.migrated())
        state = SavedState(accounts: AccountSlot.defaults); state.accounts[0].id = "../another-home"
        XCTAssertThrowsError(try state.migrated())
    }
    private func rates(_ json: String) throws -> RateResponse { try JSONDecoder().decode(RateResponse.self, from: Data(json.utf8)) }
    func testServerPercentageIsUsedAndClampsOnlyKnownValues() {
        XCTAssertEqual(QuotaWindow(usedPercent: 2).remaining, 98)
        XCTAssertEqual(QuotaWindow(usedPercent: 101).remaining, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -3).remaining, 100)
        XCTAssertNil(QuotaWindow().remaining)
    }
    func testMissingBankIsUnknownAndCountIsNotDetailLength() throws {
        XCTAssertNil(try rates(#"{"rateLimitResetCredits":null}"#).rateLimitResetCredits)
        let response = try rates(#"{"rateLimitResetCredits":{"availableCount":5,"credits":[{"id":"one","status":"available","expiresAt":123}]}}"#)
        XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 5)
        XCTAssertEqual(response.rateLimitResetCredits?.nearestExpiry?.timeIntervalSince1970, 123)
        XCTAssertEqual(try rates(#"{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#).rateLimitResetCredits?.availableCount, 0)
    }
    func testMultiBucketAuthoritativeAndAllWindowsPreserved() throws {
        let result = try rates(#"{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":90}},"rateLimitsByLimitId":{"a":{"primary":{"usedPercent":2},"secondary":{"usedPercent":5}},"b":{"primary":{"usedPercent":50}}}}"#)
        XCTAssertEqual(result.buckets.map(\.0), ["a", "b"])
        XCTAssertEqual(result.windows.count, 3)
        XCTAssertTrue(result.canRecommend)
        XCTAssertEqual(try rates(#"{"rateLimits":{"primary":{"usedPercent":2}},"rateLimitsByLimitId":{}}"#).windows.count, 0)
    }
    func testStaleAndLimitedAccountsNotRecommended() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let identity = AccountIdentity(type: "chatgpt", email: "a@example.com", planType: "pro")
        let data = try rates(#"{"rateLimits":{"primary":{"usedPercent":10,"resetsAt":20000}}}"#)
        var slot = AccountSlot(id: "a", name: "A", chromeProfile: "Default")
        slot.snapshot = Snapshot(fetchedAt: now.addingTimeInterval(-601), identity: identity, rates: data)
        XCTAssertNil(Presentation.recommendation([slot], healthy: ["a"], now: now))
        slot.snapshot?.fetchedAt = now
        XCTAssertNotNil(Presentation.recommendation([slot], healthy: ["a"], now: now))
        XCTAssertNil(Presentation.recommendation([slot], healthy: [], now: now))
        slot.snapshot?.rates.ordinaryUsageAllowed = false
        XCTAssertNil(Presentation.recommendation([slot], healthy: ["a"], now: now))
        slot.snapshot?.rates.ordinaryUsageAllowed = true
        slot.snapshot?.rates.rateLimits?.primary?.resetsAt = 9000
        XCTAssertFalse(slot.snapshot!.isFresh(at: now))
    }
    func testNoRecommendationWhenAnotherWindowExhausted() throws {
        let data = try rates(#"{"rateLimits":{"primary":{"usedPercent":10},"secondary":{"usedPercent":100}}}"#)
        XCTAssertFalse(data.canRecommend)
        XCTAssertFalse(try rates(#"{"rateLimits":{"primary":{"usedPercent":10},"rateLimitReachedType":"workspace_owner_credits_depleted"}}"#).canRecommend)
    }
    func testDuplicateAndWrongAccountGuard() {
        let identity = AccountIdentity(type: "chatgpt", email: "A@EXAMPLE.COM", planType: "pro")
        var a = AccountSlot(id: "a", name: "A", chromeProfile: "Default")
        var b = AccountSlot(id: "b", name: "B", chromeProfile: "Profile 1")
        a.expectedEmail = "a@example.com"; a.expectedAccountID = "id-a"
        XCTAssertEqual(IdentityCheck.evaluate(slot: b, identity: identity, accountID: "id-a", others: [a]), .duplicate("a•••@example.com"))
        b.expectedEmail = "b@example.com"
        XCTAssertEqual(IdentityCheck.evaluate(slot: b, identity: identity, accountID: "id-a", others: []), .changed)
        XCTAssertEqual(IdentityCheck.evaluate(slot: a, identity: identity, accountID: "another-workspace", others: []), .changed)
        XCTAssertEqual(IdentityCheck.evaluate(slot: a, identity: identity, accountID: "id-a", others: []), .valid)
    }
    func testDistinctCodexAccountsCanShareChromeProfile() {
        var first = AccountSlot(id: "first", name: "First", chromeProfile: "Default")
        first.expectedEmail = "one@example.com"; first.expectedAccountID = "account-one"
        let second = AccountSlot(id: "second", name: "Second", chromeProfile: "Default")
        let identity = AccountIdentity(type: "chatgpt", email: "two@example.com", planType: "pro")
        XCTAssertEqual(IdentityCheck.evaluate(slot: second, identity: identity, accountID: "account-two", others: [first]), .valid)
    }
    func testCountdownNeverPretendsPastResetIsFresh() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(Presentation.countdown(Date(timeIntervalSince1970: 999), now: now), "已到重置时间 · 待同步")
        XCTAssertEqual(Presentation.countdown(nil, now: now), "重置时间未知")
        XCTAssertEqual(Presentation.countdown(now.addingTimeInterval(61), now: now), "2 分钟后")
    }
    @MainActor func testProcessEnvironmentCannotInheritOtherCredentials() {
        let home = URL(fileURLWithPath: "/isolated/account-a")
        let env = RPCClient.isolatedEnvironment(home: home, inherited: ["HOME":"/user", "CODEX_HOME":"/old", "OPENAI_API_KEY":"secret", "CODEX_ACCESS_TOKEN":"secret", "CODEX_AUTH_JSON":"secret", "HTTPS_PROXY":"http://proxy"])
        XCTAssertEqual(env["HOME"], "/user")
        XCTAssertEqual(env["CODEX_HOME"], "/isolated/account-a")
        XCTAssertNil(env["OPENAI_API_KEY"]); XCTAssertNil(env["CODEX_ACCESS_TOKEN"]); XCTAssertNil(env["CODEX_AUTH_JSON"])
        XCTAssertEqual(env["HTTPS_PROXY"], "http://proxy")
    }
}
