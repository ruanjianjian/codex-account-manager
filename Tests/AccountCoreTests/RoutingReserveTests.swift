import XCTest
@testable import AccountCore

final class RoutingReserveTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func slot(_ id: String, weekly: Double, short: Double = 0, resetHours: Double = 100) throws -> AccountSlot {
        let t = Int(now.timeIntervalSince1970)
        let json = #"{"accountId":"acc","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":\#(weekly),"windowDurationMins":10080,"resetsAt":\#(t + Int(resetHours * 3600))},"secondary":{"usedPercent":\#(short),"windowDurationMins":300,"resetsAt":\#(t + 3600)}}}}"#
        var slot = AccountSlot(id: id, name: id, chromeProfile: "Default")
        slot.snapshot = Snapshot(fetchedAt: now, identity: AccountIdentity(type: "chatgpt", email: "\(id)@example.com", planType: "pro"),
                                 rates: try JSONDecoder().decode(RateResponse.self, from: Data(json.utf8)))
        return slot
    }
    private func low(_ slot: AccountSlot) -> Bool { RoutingReserve.low(slot.snapshot!.rates.windows, now: now) }
    func testUnderTenPercentInAnyWindowIsLow() throws {
        XCTAssertTrue(low(try slot("a", weekly: 96)))
        XCTAssertFalse(low(try slot("a", weekly: 84)))
        XCTAssertFalse(low(try slot("a", weekly: 90)))
        XCTAssertTrue(low(try slot("a", weekly: 20, short: 95)))
        // A window that has already reset is full again.
        XCTAssertFalse(low(try slot("a", weekly: 96, resetHours: -1)))
        XCTAssertFalse(RoutingReserve.low([], now: now))
    }
    func testAccountsNearlyOutComeOnlyWhenNoneHasMore() throws {
        let nearlyOut = try slot("j", weekly: 96), some = try slot("an", weekly: 84), full = try slot("b", weekly: 0)
        XCTAssertEqual(RoutingReserve.ample([nearlyOut, some, full], now: now).map(\.id), ["an", "b"])
        XCTAssertEqual(RoutingReserve.ample([nearlyOut, try slot("s", weekly: 100)], now: now).map(\.id), ["j", "s"])
    }
}
