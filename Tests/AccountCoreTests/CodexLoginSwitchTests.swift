import XCTest
@testable import AccountCore

final class CodexLoginSwitchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func rates(weekly: Double, short: Double = 0, resetHours: Double = 100) throws -> RateResponse {
        let t = Int(now.timeIntervalSince1970)
        let json = #"{"accountId":"acc","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":\#(weekly),"windowDurationMins":10080,"resetsAt":\#(t + Int(resetHours * 3600))},"secondary":{"usedPercent":\#(short),"windowDurationMins":300,"resetsAt":\#(t + 3600)}}}}"#
        return try JSONDecoder().decode(RateResponse.self, from: Data(json.utf8))
    }
    func testOnlyWhenCodexsOwnAccountIsOut() throws {
        let others = [("b", Optional(try rates(weekly: 70)))]
        XCTAssertEqual(CodexLoginSwitch.target(desktop: try rates(weekly: 100), others: others, now: now), "b")
        XCTAssertNil(CodexLoginSwitch.target(desktop: try rates(weekly: 99), others: others, now: now))
        XCTAssertNil(CodexLoginSwitch.target(desktop: nil, others: others, now: now))
        // A spent window that has already reset is not "out".
        XCTAssertNil(CodexLoginSwitch.target(desktop: try rates(weekly: 100, resetHours: -1), others: others, now: now))
        // The 5-hour window counts too: Codex is locked until it resets.
        XCTAssertEqual(CodexLoginSwitch.target(desktop: try rates(weekly: 20, short: 100), others: others, now: now), "b")
    }
    func testGoesToTheAccountThatLastsLongest() throws {
        let out = try rates(weekly: 100)
        // Routing spends b first (it resets soonest); Codex goes to the one with the most left.
        let others = [("b", Optional(try rates(weekly: 81, resetHours: 20))), ("c", Optional(try rates(weekly: 70))), ("d", Optional(try rates(weekly: 10)))]
        XCTAssertEqual(CodexLoginSwitch.target(desktop: out, others: others, now: now), "d")
        // As much left: the later reset.
        let tie = [("e", Optional(try rates(weekly: 0, resetHours: 100))), ("f", Optional(try rates(weekly: 0, resetHours: 160)))]
        XCTAssertEqual(CodexLoginSwitch.target(desktop: out, others: tie, now: now), "f")
    }
    func testNothingWhenNoOtherAccountHasQuota() throws {
        let out = try rates(weekly: 100)
        XCTAssertNil(CodexLoginSwitch.target(desktop: out, others: [("b", try rates(weekly: 100)), ("c", nil)], now: now))
        XCTAssertNil(CodexLoginSwitch.target(desktop: out, others: [], now: now))
    }
    /// The same used-up window, read again a few seconds later, gets no second notice.
    func testOneNoticePerUsedUpWindow() {
        XCTAssertEqual(CodexLoginSwitch.noticeKey(reset: 1_794_485_828, noticed: []), "codex-login-out-1794485828")
        XCTAssertNil(CodexLoginSwitch.noticeKey(reset: 1_794_485_832, noticed: ["soon-x", "codex-login-out-1794485828"]))
        // A later window that runs out is a new lock.
        XCTAssertEqual(CodexLoginSwitch.noticeKey(reset: 1_795_090_628, noticed: ["codex-login-out-1794485828"]), "codex-login-out-1795090628")
    }
    func testTheNoticeSaysWhatAClickDoes() {
        L10n.choice = .zh; defer { L10n.choice = .system }
        let notice = CodexLoginSwitch.notice(from: "Simon", to: "Annaer")
        XCTAssertEqual(notice.body, "Codex 登录的 Simon 没额度了，新消息发不出去。点这里换到 Annaer，Codex 会重开一次。")
        XCTAssertEqual(notice.button, "换到 Annaer")
    }
}
