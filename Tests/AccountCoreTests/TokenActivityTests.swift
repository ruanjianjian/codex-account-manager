import XCTest
@testable import AccountCore

final class TokenActivityTests: XCTestCase {
    func testSumsAccountsWithoutTurningMissingBucketsIntoZero() throws {
        let a = TokenUsageResponse(buckets: [.init(startDate: "2026-10-26", tokens: 100), .init(startDate: "2026-10-27", tokens: 0)])
        let b = TokenUsageResponse(buckets: [.init(startDate: "2026-10-26", tokens: 200)])
        let days = TokenActivity.aggregate([a, b], dates: ["2026-10-26", "2026-10-27", "2026-10-28"])
        XCTAssertEqual(days[0].tokens, 300); XCTAssertTrue(days[0].isComplete)
        XCTAssertEqual(days[1].tokens, 0); XCTAssertFalse(days[1].isComplete)
        XCTAssertNil(days[2].tokens)
        XCTAssertNil(TokenActivity.aggregate([nil, TokenUsageResponse(buckets: nil)], dates: ["2026-10-27"])[0].tokens)
    }
    func testDuplicateRefreshAndNegativeValuesDoNotInflateTotals() {
        let a = TokenUsageResponse(buckets: [.init(startDate: "2026-10-26", tokens: 100), .init(startDate: "2026-10-26", tokens: 150), .init(startDate: "2026-10-27", tokens: -2)])
        let dates = ["2026-10-26", "2026-10-27"]
        XCTAssertEqual(TokenActivity.aggregate([a], dates: dates)[0].tokens, 150)
        XCTAssertEqual(TokenActivity.aggregate([a], dates: dates), TokenActivity.aggregate([a], dates: dates))
        XCTAssertNil(TokenActivity.aggregate([a], dates: dates)[1].tokens)
    }
    func testUTCDayRangeAndOptionalProtocolFields() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00Z")!
        XCTAssertEqual(TokenActivity.recentDates(count: 7, now: now), ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
        let response = try JSONDecoder().decode(TokenUsageResponse.self, from: Data("{\"summary\":{\"lifetimeTokens\":null},\"dailyUsageBuckets\":null}".utf8))
        XCTAssertNil(response.summary.lifetimeTokens); XCTAssertNil(response.dailyUsageBuckets)
    }
    func testChineseCompactUnits() {
        XCTAssertEqual(TokenActivity.compact(735_678_103), "7.36 亿")
        XCTAssertEqual(TokenActivity.compact(12_500_000), "1.25 千万")
        XCTAssertEqual(TokenActivity.compact(2_500_000), "2.5 百万")
        XCTAssertEqual(TokenActivity.compact(468_253), "46.83 万")
        XCTAssertEqual(TokenActivity.compact(10_000), "1 万")
        XCTAssertEqual(TokenActivity.compact(0), "0")
    }
    func testDismissalPreservesPinMenusTransitAndDragging() {
        XCTAssertTrue(PanelDismissal.allowed(pinned: false, pointerInside: false, menuOpen: false, dragging: false))
        XCTAssertFalse(PanelDismissal.allowed(pinned: true, pointerInside: false, menuOpen: false, dragging: false))
        XCTAssertFalse(PanelDismissal.allowed(pinned: false, pointerInside: true, menuOpen: false, dragging: false))
        XCTAssertFalse(PanelDismissal.allowed(pinned: false, pointerInside: false, menuOpen: true, dragging: false))
        XCTAssertFalse(PanelDismissal.allowed(pinned: false, pointerInside: false, menuOpen: false, dragging: true))
    }
}
