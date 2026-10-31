import XCTest
@testable import AccountCore

final class TokenActivityTests: XCTestCase {
    override func setUp() { L10n.choice = .zh } // these check the Chinese wording
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
    func testWeeksReachBackToTheEarliestReturnedDay() {
        let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!
        let a = TokenUsageResponse(buckets: [.init(startDate: "2026-10-21", tokens: 5), .init(startDate: "2026-10-30", tokens: 7)])
        let b = TokenUsageResponse(buckets: [.init(startDate: "2026-10-24", tokens: 1)])
        let weeks = TokenActivity.weeks([a, b], now: now)
        XCTAssertEqual(weeks.map { $0.map(\.id) }, [
            ["2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"],
            ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"],
        ], "whole weeks that end today, oldest first")
        XCTAssertEqual(weeks[0][4].tokens, 5); XCTAssertEqual(weeks[1][0].tokens, 1); XCTAssertEqual(weeks[1][6].tokens, 7)
        let exact = TokenUsageResponse(buckets: [.init(startDate: "2026-10-24", tokens: 1)])
        XCTAssertEqual(TokenActivity.weeks([exact], now: now).count, 1, "a day exactly 7 days back fits in this week")
        XCTAssertEqual(TokenActivity.weeks([nil, TokenUsageResponse(buckets: nil)], now: now).map(\.count), [7],
                       "without data there is still this week")
        XCTAssertEqual(TokenActivity.weekTitle(weeks[1], weeksAgo: 0), "近 7 天")
        XCTAssertEqual(TokenActivity.weekTitle(weeks[0], weeksAgo: 1), "上周")
        XCTAssertEqual(TokenActivity.weekTitle(weeks[0], weeksAgo: 2), "10-17 – 10-23")
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
