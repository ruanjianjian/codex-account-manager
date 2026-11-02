import XCTest
@testable import AccountCore

final class BankedResetTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func rates(used: Double, hoursLeft: Double, credits: String = #"[{"id":"late","status":"available","expiresAt":EXP2},{"id":"soon","status":"available","expiresAt":EXP1}]"#) throws -> RateResponse {
        let t = now.timeIntervalSince1970
        let json = #"{"accountId":"acc","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":USED,"windowDurationMins":10080,"resetsAt":RESET},"secondary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":SHORT}}},"rateLimitResetCredits":{"availableCount":2,"credits":CREDITS}}"#
            .replacingOccurrences(of: "CREDITS", with: credits)
            .replacingOccurrences(of: "USED", with: "\(used)")
            .replacingOccurrences(of: "RESET", with: "\(Int(t + hoursLeft * 3600))")
            .replacingOccurrences(of: "SHORT", with: "\(Int(t + 3600))")
            .replacingOccurrences(of: "EXP1", with: "\(Int(t + 4 * 86400))")
            .replacingOccurrences(of: "EXP2", with: "\(Int(t + 29 * 86400))")
        return try JSONDecoder().decode(RateResponse.self, from: Data(json.utf8))
    }
    func testSpentWithTwoDaysToGoUsesTheCreditThatExpiresFirst() throws {
        let plan = try XCTUnwrap(BankedResetRule.plan(accountID: "a", rates: rates(used: 100, hoursLeft: 51), now: now))
        XCTAssertEqual(plan.creditID, "soon")
        XCTAssertEqual(plan.window.windowDurationMins, 10080)
        XCTAssertEqual(plan.creditsLeft, 1)
    }
    func testWaitsWhenTheResetIsUnderTwoDaysOrQuotaIsLeft() throws {
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 100, hoursLeft: 47.9), now: now))
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 99, hoursLeft: 100), now: now))
        // The 5-hour window is spent too, but it comes back within the hour.
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 20, hoursLeft: 100), now: now))
    }
    func testNeedsAnUnexpiredCreditAndNothingMidRedeem() throws {
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 100, hoursLeft: 60, credits: "[]"), now: now))
        let expired = #"[{"id":"old","status":"available","expiresAt":1}]"#
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 100, hoursLeft: 60, credits: expired), now: now))
        let redeeming = #"[{"id":"x","status":"redeeming"},{"id":"y","status":"available"}]"#
        XCTAssertNil(BankedResetRule.plan(accountID: "a", rates: try rates(used: 100, hoursLeft: 60, credits: redeeming), now: now))
        let used = #"[{"id":"x","status":"redeemed"},{"id":"y","status":"available"}]"#
        XCTAssertEqual(BankedResetRule.plan(accountID: "a", rates: try rates(used: 100, hoursLeft: 60, credits: used), now: now)?.creditID, "y")
    }
    func testACountWithoutDetailsLetsTheServicePick() throws {
        let plan = try XCTUnwrap(BankedResetRule.plan(accountID: "a", rates: rates(used: 100, hoursLeft: 60, credits: "null"), now: now))
        XCTAssertNil(plan.creditID)
        XCTAssertEqual(plan.creditsLeft, 1)
    }
    func testTheSameWindowAlwaysGivesTheSameKey() throws {
        let first = try XCTUnwrap(BankedResetRule.plan(accountID: "a", rates: rates(used: 100, hoursLeft: 60), now: now))
        let again = try XCTUnwrap(BankedResetRule.plan(accountID: "a", rates: rates(used: 100, hoursLeft: 60), now: now.addingTimeInterval(1800)))
        XCTAssertEqual(first.idempotencyKey, BankedResetRule.key("a", first.window.resetsAt!))
        XCTAssertEqual(again.idempotencyKey, BankedResetRule.key("a", first.window.resetsAt!))
        XCTAssertNotEqual(BankedResetRule.key("a", 1), BankedResetRule.key("b", 1))
        XCTAssertNotEqual(BankedResetRule.key("a", 1), BankedResetRule.key("a", 2))
        XCTAssertNotNil(UUID(uuidString: first.idempotencyKey))
    }
}
