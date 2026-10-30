import XCTest
@testable import AccountCore

final class PersonalXMonitorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_102_400)
    func post(_ id: String, _ text: String = "We reset Codex usage limits for everyone!", age: Double = -10, truncated: Bool = false) -> XVisiblePost {
        XVisiblePost(url: "https://x.com/thsottiaux/status/\(id)", text: text,
                     publishedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(age)), truncated: truncated)
    }
    func testLinksRequireTiboAndSortByIDNotPinnedPageOrder() {
        let older = "2000000000000000001", newer = "2001000000000000001"
        func url(_ id: String) -> String { "https://x.com/thsottiaux/status/\(id)" }
        let text = "[pinned](\("https://x.com/thsottiaux/status/2000000000000000001")) [other](https://x.com/other/status/\(newer)) [new](\("https://x.com/thsottiaux/status/2001000000000000001")?s=20) \("https://x.com/thsottiaux/status/2000000000000000001")"
        XCTAssertEqual(TiboPostLink.extract(from: text, now: Date()).map(\.id), [newer, older])
        for invalid in ["https://x.com.evil/thsottiaux/status/\(newer)", "https://evil@x.com/thsottiaux/status/\(newer)", "https://x.com:443/thsottiaux/status/\(newer)", "http://x.com/thsottiaux/status/\(newer)", "https://x.com/other/status/\(newer)", "https://x.com/thsottiaux/status/\(newer)/photo/1"] {
            XCTAssertNil(TiboPostLink.parse(invalid))
        }
        XCTAssertTrue(TiboPostLink.extract(from: url("18446744073709551615"), now: Date()).isEmpty)
    }
    func testStrictAuthorPageAndLoginValidation() throws {
        let p = post("2000000000000000001")
        XCTAssertEqual(try XTimelinePage(pageURL: "https://x.com/thsottiaux", loggedIn: true, posts: [p, p]).validated(at: now), [p])
        for page in ["https://x.com/other", "https://x.com/i/flow/login", "https://x.com.evil/thsottiaux", "http://x.com/thsottiaux"] {
            XCTAssertThrowsError(try XTimelinePage(pageURL: page, loggedIn: true, posts: [p]).validated(at: now))
        }
        XCTAssertThrowsError(try XTimelinePage(pageURL: "https://x.com/thsottiaux", loggedIn: false, posts: [p]).validated(at: now))
        XCTAssertThrowsError(try XTimelinePage(pageURL: "https://x.com/thsottiaux", loggedIn: true, posts: []).validated(at: now))
        let other = XVisiblePost(url: "https://x.com/other/status/2000000000000000001", text: p.text, publishedAt: p.publishedAt, truncated: false)
        XCTAssertFalse(other.isValid(at: now)); XCTAssertFalse(post("2000000000000000002", age: 600).isValid(at: now))
    }
    func testConservativeResetClassificationAndNoQuotedOrTruncatedActions() {
        XCTAssertEqual(post("2000000000000000001").resetKind, "reported_completed")
        XCTAssertEqual(post("2000000000000000001", "We will reset Codex limits for all users tonight.").resetKind, "planned")
        XCTAssertEqual(post("2000000000000000001", "Everyone receives an extra banked reset for Codex today.").resetKind, "banked")
        XCTAssertEqual(post("2000000000000000001", "Day 20/ Rest and reset").resetKind, "possible_reset")
        XCTAssertEqual(post("2000000000000000001", "Day 25/ We are doubling all usage limits for all Pro tiers, effective today.").resetKind, "limits")
        XCTAssertEqual(post("2000000000000000001", "Day 21/ Wonder what happens the remaining seven days. But today is a reset.").resetKind, "possible_reset")
        for text in ["Codex limits reset every week", "We haven't reset Codex limits for everyone.", "I hope they reset Codex limits for everyone.", "Could we reset Codex for everyone?", "No reset for all users.", "Codex launch for everyone"] {
            XCTAssertNil(post("2000000000000000001", text).resetKind, text)
        }
        XCTAssertNil(post("2000000000000000001", truncated: true).resetKind)
        // A cut-off post is not settled: it is looked at again, in full, on a later check.
        var x = PersonalXState(); x.start(with: [], now: now)
        let cut = post("2000000000000000003", age: 30, truncated: true)
        XCTAssertTrue(x.ingest([cut], now: now.addingTimeInterval(60)).items.isEmpty)
        XCTAssertFalse(x.seenIDs.contains(cut.id))
        let whole = XVisiblePost(url: cut.url, text: "Day 25/ We are doubling all usage limits for all Pro tiers, effective today.", publishedAt: cut.publishedAt, truncated: false)
        XCTAssertEqual(x.ingest([whole], now: now.addingTimeInterval(120)).items.map(\.kind), ["limits"])
    }
    func testFirstConnectionIsBaselineAndNextNewAnnouncementTriggersOneBatch() throws {
        var x = PersonalXState()
        let old = post("2000000000000000001")
        x.start(with: [old], now: now)
        let fresh = post("2000000000000000002", age: 30)
        var restored = try JSONDecoder().decode(PersonalXState.self, from: JSONEncoder().encode(x))
        let feed = restored.ingest([old, fresh], now: now.addingTimeInterval(40))
        XCTAssertEqual(feed.items.map(\.id), [fresh.id])
        var reset = ResetMonitorState(now: now)
        XCTAssertEqual(try reset.ingest(feed, accountIDs: ["a", "b"], now: now.addingTimeInterval(40)).count, 1)
        XCTAssertEqual(reset.pendingAccountIDs, ["a", "b"])
        XCTAssertTrue(restored.ingest([fresh, old], now: now.addingTimeInterval(60)).items.isEmpty)
        reset.acknowledge("a", syncStartedAt: now)
        XCTAssertEqual(reset.pendingAccountIDs.count, 2)
        reset.acknowledge("a", syncStartedAt: now.addingTimeInterval(50))
        XCTAssertEqual(reset.pendingAccountIDs, ["b"])
    }
    func testOldPinnedBackfillAndIdleResumeDoNotReplayHistoricalResets() {
        var x = PersonalXState()
        XCTAssertTrue(x.ingest([post("2000000000000000001")], now: now).items.isEmpty)
        let backfill = post("2000000000000000002", age: -60)
        XCTAssertTrue(x.ingest([backfill], now: now.addingTimeInterval(10)).items.isEmpty)
        let future = post("2000000000000000003", age: 100_000)
        XCTAssertTrue(x.ingest([future], now: now).items.isEmpty)
        let longGap = post("2000000000000000004", age: 20)
        XCTAssertTrue(x.ingest([longGap], now: now.addingTimeInterval(4 * 86400)).items.isEmpty)
    }
    func testPossibleTimelineGapIsVisibleInsteadOfClaimingFullCoverage() {
        var x = PersonalXState()
        x.start(with: [post("2000000000000000001")], now: now)
        let feed = x.ingest([post("2000000000000000002", age: 20)], now: now.addingTimeInterval(40))
        XCTAssertTrue(x.possibleGap); XCTAssertTrue(feed.stale)
    }
}
