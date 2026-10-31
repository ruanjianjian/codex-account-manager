import XCTest
@testable import AccountCore

final class LocalizationTests: XCTestCase {
    override func tearDown() { L10n.choice = .system }

    func testFollowsAnyChineseInTheMacLanguageList() {
        XCTAssertTrue(L10n.chinese(.system, preferred: ["en-MF", "zh-Hans-MF"]), "English first with Chinese further down stays Chinese")
        XCTAssertTrue(L10n.chinese(.system, preferred: ["zh-Hant-TW"]))
        XCTAssertFalse(L10n.chinese(.system, preferred: ["en-US", "ja-JP"]))
        XCTAssertFalse(L10n.chinese(.system, preferred: []))
        XCTAssertTrue(L10n.chinese(.zh, preferred: ["en-US"]), "a choice in Settings wins")
        XCTAssertFalse(L10n.chinese(.en, preferred: ["zh-Hans"]))
    }
    func testEnglishWording() {
        L10n.choice = .en
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Presentation.countdown(now.addingTimeInterval(2 * 86_400 + 3 * 3600), now: now), "in 2d 3h")
        XCTAssertEqual(Presentation.resetCountdown(now.addingTimeInterval(61), now: now), "resets in 2 min")
        XCTAssertEqual(Presentation.resetCountdown(nil, now: now), "Reset time unknown")
        XCTAssertEqual(QuotaWindow(windowDurationMins: 10080).label, "Weekly limit")
        XCTAssertEqual(QuotaWindow(windowDurationMins: 300).label, "5-hour limit")
        XCTAssertEqual(Mascot.comesBack(now.addingTimeInterval(3 * 3600 + 5), now: now), "back in 3 hours")
        XCTAssertEqual(Mascot.comesBack(now.addingTimeInterval(86_400 + 5), now: now), "back in 1 day")
        let spent = [Mascot.Account(id: "w", name: "Work", remaining: 0, backAt: now.addingTimeInterval(3.5 * 3600))]
        var input = Mascot.Input(accounts: spent); input.now = now
        XCTAssertEqual(Mascot.line(input).text, "Every account is out; Work back in 3 hours")
        XCTAssertEqual(TokenActivity.compact(1_250_000), "1.25M")
        XCTAssertEqual(TokenActivity.compact(468_253), "468.25K")
        XCTAssertEqual(TokenActivity.compact(999), "999")
    }
    func testChineseWordingUnchanged() {
        L10n.choice = .zh
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Presentation.resetCountdown(now.addingTimeInterval(2 * 86_400 + 3 * 3600), now: now), "2 天 3 小时后重置")
        XCTAssertEqual(Presentation.countdown(now.addingTimeInterval(61), now: now), "2 分钟后")
        XCTAssertEqual(TokenActivity.compact(1_250_000), "1.25 百万")
    }
}
