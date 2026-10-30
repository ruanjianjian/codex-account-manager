import XCTest
@testable import AccountCore

final class ResetJudgeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_340_000)
    func post(_ id: String, _ text: String, age: Double = 30) -> XVisiblePost {
        XVisiblePost(url: "https://x.com/thsottiaux/status/\(id)", text: text, publishedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(age)), truncated: false)
    }
    func testParseKeepsKnownKindsAndValidTimesOnly() {
        let ok = ResetJudge.parse(Data(#"{"kind":"planned","reset_at":"2026-10-30T06:00:00Z","note":"预计约2小时后重置。"}"#.utf8))
        XCTAssertEqual(ok, .init(kind: "planned", reset_at: "2026-10-30T06:00:00Z", note: "预计约2小时后重置。"))
        XCTAssertNil(ResetJudge.parse(Data(#"{"kind":"maybe","reset_at":null,"note":""}"#.utf8)))
        XCTAssertNil(ResetJudge.parse(Data("not json".utf8)))
        XCTAssertNil(ResetJudge.parse(Data(#"{"kind":"planned","reset_at":"soon","note":"x"}"#.utf8))?.reset_at)
    }
    func testPromptCarriesThePostItsTimeAndEarlierContext() {
        let p = ResetJudge.prompt(text: "Lands by midnight PST.", postedAt: "2026-10-28T02:43:38Z", earlier: ["Day 23/ Just kidding, today is a reset."], now: now)
        XCTAssertTrue(p.contains("Lands by midnight PST.")); XCTAssertTrue(p.contains("2026-10-28T02:43:38Z")); XCTAssertTrue(p.contains("today is a reset"))
        XCTAssertFalse(ResetJudge.worthAsking("@StefanoGPT Yes")); XCTAssertTrue(ResetJudge.worthAsking("Day 25/ We are doubling all usage limits"))
    }
    // The model overrules the rules both ways: a joke with "reset" in it is ignored, a limit change the keywords miss is caught.
    func testVerdictsReplaceTheRulesAndCarryTimeAndNote() throws {
        var x = PersonalXState(); x.start(with: [], now: now)
        let joke = post("2115851621137784832", "Everyone: we reset Codex limits for all users!")
        let boost = post("2115850175868727621", "Pro limits are now 3x higher.")
        let planned = post("2115000000000000003", "Reset lands in a bit.")
        let feed = x.ingest([joke, boost, planned], now: now.addingTimeInterval(60), verdicts: [
            joke.id: .init(kind: "none", reset_at: nil, note: ""),
            boost.id: .init(kind: "limits", reset_at: nil, note: "Pro 额度提高到 3 倍。"),
            planned.id: .init(kind: "planned", reset_at: "2026-10-30T06:00:00Z", note: "约 2 小时后重置。"),
        ])
        XCTAssertEqual(feed.items.map(\.kind).sorted(), ["limits", "planned"])
        let limits = try XCTUnwrap(feed.items.first { $0.kind == "limits" }), soon = try XCTUnwrap(feed.items.first { $0.kind == "planned" })
        XCTAssertTrue(limits.eligible)
        XCTAssertEqual(ResetNotice.message(for: limits, accounts: [], now: now)?.body, "Pro 额度提高到 3 倍。 正在刷新全部账号额度。")
        XCTAssertEqual(soon.timing?.expectedAt, ResetFeed.date("2026-10-30T06:00:00Z"))
        // A post the model did not judge is still read by the rules.
        XCTAssertEqual(x.ingest([post("2115000000000000004", "We reset Codex usage limits for everyone!", age: 90)], now: now.addingTimeInterval(120)).items.map(\.kind), ["reported_completed"])
    }
    func testPublicFeedTakesTheModelsReading() {
        let feed = ResetFeed(available: true, stale: false, handle: "thsottiaux", updated_at: nil, items: [
            ResetAnnouncement(id: "2115000000000000005", text: "Terra gives 2X more usage", published_at: "2026-10-26T19:24:11Z", url: "https://x.com/thsottiaux/status/2115000000000000005", kind: "limits")])
        let judged = feed.applying(["2115000000000000005": .init(kind: "none", reset_at: nil, note: "")])
        XCTAssertEqual(judged.items.first?.kind, "none"); XCTAssertFalse(judged.items.first!.eligible)
    }
}
