import XCTest
@testable import AccountCore

final class ResetAnnouncementTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    func post(_ id: String = "2115000000000000001", kind: String = "reported_completed", offset: Double = 10, url: String? = nil) -> ResetAnnouncement {
        ResetAnnouncement(id: id, text: "Test announcement", published_at: ISO8601DateFormatter().string(from: start.addingTimeInterval(offset)), url: url ?? "https://x.com/thsottiaux/status/\(id)", kind: kind)
    }
    func feed(_ items: [ResetAnnouncement], stale: Bool = false, available: Bool = true, handle: String = "thsottiaux") -> ResetFeed {
        ResetFeed(available: available, stale: stale, handle: handle, updated_at: ISO8601DateFormatter().string(from: start.addingTimeInterval(20)), items: items)
    }
    func testOnlyNewExplicitSignalsTriggerOnePersistedAccountBatch() throws {
        var state = ResetMonitorState(now: start)
        let old = post("2114000000000000001", offset: -20)
        let completed = post(), planned = post("2115000000000000002", kind: "planned")
        let hint = post("2115000000000000003", kind: "hint")
        let got = try state.ingest(feed([old, completed, completed, planned, hint]), accountIDs: ["a", "b", "b"], now: start.addingTimeInterval(30))
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(state.pendingAccountIDs, ["a", "b"])
        XCTAssertEqual(state.targetCount, 2)
        var restored = try JSONDecoder().decode(ResetMonitorState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(try restored.ingest(feed([planned, completed, old]), accountIDs: ["a", "b"], now: start.addingTimeInterval(40)).isEmpty)
        XCTAssertEqual(restored.pendingAccountIDs, ["a", "b"])
    }
    // Day 25 (2026-10-29): limits doubled "effective today". No "reset" in it, yet it refills quota like one.
    func testLimitChangesThatApplyNowNotifyOnceAcrossSources() throws {
        let day25 = "Day 25/\n\nWe are doubling all usage limits for all Pro 100/200/500 tiers and Business Premium, effective today.\n\nWe heard your kind feedback and won't be reducing usage limits for Pro 200, so your Work and Codex usage will stay the same."
        XCTAssertTrue(LimitsAnnouncement.matches(day25))
        for text in ["Day 22/ Terra is back! Very good at computer use, and gives 2X more usage than 6.1 Sol",
                     "We are not doubling limits today.", "Should we double usage limits today?", "Usage limits are the same as before."] {
            XCTAssertFalse(LimitsAnnouncement.matches(text), text)
        }
        XCTAssertEqual(LimitsAnnouncement.headline(day25), "We are doubling all usage limits for all Pro 100/200/500 tiers and Business Premium, effective today.")
        let at = ISO8601DateFormatter().string(from: start.addingTimeInterval(10))
        let make = { (id: String, text: String, kind: String) in
            ResetAnnouncement(id: id, text: text, published_at: at, url: "https://x.com/thsottiaux/status/\(id)", kind: kind)
        }
        let limits = make("2115850175868727621", day25, "limits")
        XCTAssertEqual(ResetNotice.message(for: limits, accounts: [], now: start)?.title, "Tibo 宣布额度调整")
        // The public source also files model launches under "limits"; those are not limit changes.
        let launch = make("2115000000000000009", "Terra is back! It gives 2X more usage than 6.1 Sol", "limits")
        XCTAssertFalse(launch.eligible)
        var state = ResetMonitorState(now: start)
        XCTAssertEqual(try state.ingest(feed([limits, launch]), accountIDs: ["a"], now: start.addingTimeInterval(30)).count, 1)
        // The other source classifying the same post differently does not signal it again...
        XCTAssertTrue(try state.ingest(feed([make(limits.id, day25, "reported_completed")]), accountIDs: ["a"], now: start.addingTimeInterval(40)).isEmpty)
        // ...but a post first seen only as a possible reset may still be confirmed.
        let hint = make("2115000000000000010", "Day 20/ Rest and reset", "possible_reset")
        XCTAssertEqual(try state.ingest(feed([hint]), accountIDs: ["a"], now: start.addingTimeInterval(50)).count, 1)
        XCTAssertEqual(try state.ingest(feed([make(hint.id, hint.text, "reported_completed")]), accountIDs: ["a"], now: start.addingTimeInterval(60)).count, 1)
    }
    func testBankedSignalQueriesWithoutConsumingAndRejectsUntrustedLinks() throws {
        var state = ResetMonitorState(now: start)
        let banked = post(kind: "banked")
        let spoofed = post("2115000000000000002", url: "https://x.com.evil.test/thsottiaux/status/2115000000000000002")
        let other = post("2115000000000000003", url: "https://x.com/other/status/2115000000000000003")
        let wrongID = post("2115000000000000004", url: "https://x.com/thsottiaux/status/2115000000000000005")
        XCTAssertEqual(try state.ingest(feed([banked, spoofed, other, wrongID]), accountIDs: ["a"], now: start.addingTimeInterval(30)).map(\.kind), ["banked"])
    }
    func testNoFalseSuccessFromUnavailableFeedOrWrongAuthor() throws {
        var state = ResetMonitorState(now: start)
        XCTAssertThrowsError(try state.ingest(feed([post()], available: false), accountIDs: ["a"], now: start))
        XCTAssertThrowsError(try state.ingest(feed([post()], handle: "other"), accountIDs: ["a"], now: start))
        XCTAssertNil(state.lastCheckedAt); XCTAssertTrue(state.seenKeys.isEmpty)
    }
    func testStaleSourceIsExplicitButNewCachedSignalsCanStillRequestOfficialRead() throws {
        var state = ResetMonitorState(now: start)
        XCTAssertEqual(try state.ingest(feed([post()], stale: true), accountIDs: ["a"], now: start.addingTimeInterval(30)).count, 1)
        XCTAssertTrue(state.sourceStale)
        XCTAssertTrue(state.refreshedAccountIDs.isEmpty)
    }
    func testFreshSyncAcknowledgementAndPendingQueueSurviveRestart() throws {
        var state = ResetMonitorState(now: start)
        _ = try state.ingest(feed([post()]), accountIDs: ["a", "b"], now: start.addingTimeInterval(30))
        state.acknowledge("a", syncStartedAt: start.addingTimeInterval(29))
        XCTAssertEqual(state.pendingAccountIDs.count, 2)
        state.acknowledge("a", syncStartedAt: start.addingTimeInterval(31))
        state = try JSONDecoder().decode(ResetMonitorState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.pendingAccountIDs, ["b"])
        XCTAssertEqual(state.refreshedAccountIDs, ["a"])
        XCTAssertTrue(state.canRetry(at: start.addingTimeInterval(90)))
        XCTAssertFalse(state.canRetry(at: start.addingTimeInterval(1000)))
        state.acknowledge("b", syncStartedAt: start.addingTimeInterval(70))
        XCTAssertFalse(state.canRetry(at: start.addingTimeInterval(90)))
    }
    func testDisabledFutureAndLateBackfillDoNotTrigger() throws {
        var state = ResetMonitorState(now: start)
        state.enabled = false
        XCTAssertTrue(try state.ingest(feed([post()]), accountIDs: ["a"], now: start.addingTimeInterval(30)).isEmpty)
        state.enabled = true
        XCTAssertTrue(try state.ingest(feed([post(offset: 4000)]), accountIDs: ["a"], now: start.addingTimeInterval(30)).isEmpty)
        XCTAssertTrue(try state.ingest(feed([post()]), accountIDs: ["a"], now: start.addingTimeInterval(4 * 86400)).isEmpty)
    }
    func testLivePublicResponseDecodesAndDoesNotReplayHistoricalPosts() throws {
        guard let path = ProcessInfo.processInfo.environment["RESET_FEED_FIXTURE"] else { throw XCTSkip("Live response fixture is opt-in") }
        let feed = try JSONDecoder().decode(ResetFeed.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try feed.validate(); XCTAssertFalse(feed.items.isEmpty)
        let now = Date(); var state = ResetMonitorState(now: now)
        XCTAssertTrue(try state.ingest(feed, accountIDs: ["a", "b"], now: now).isEmpty)
        XCTAssertNotNil(state.lastCheckedAt)
    }
    func testTimingComesOnlyFromTheAnnouncementWording() {
        let at = start
        XCTAssertEqual(ResetTiming.read("Resetting Codex limits for everyone in about 5 hours", postedAt: at).expectedAt, at.addingTimeInterval(5 * 3600))
        XCTAssertEqual(ResetTiming.read("We will reset all limits in two hours", postedAt: at).expectedAt, at.addingTimeInterval(7200))
        XCTAssertEqual(ResetTiming.read("reset coming in 30 mins", postedAt: at).expectedAt, at.addingTimeInterval(1800))
        XCTAssertEqual(ResetTiming.read("resetting usage 12h from now", postedAt: at).expectedAt, nil)
        XCTAssertEqual(ResetTiming.read("resetting usage 12 hours from now", postedAt: at).expectedAt, at.addingTimeInterval(12 * 3600))
        XCTAssertEqual(ResetTiming.read("We'll reset limits for everyone tomorrow", postedAt: at), ResetTiming(expectedAt: nil, hint: "明天"))
        XCTAssertEqual(ResetTiming.read("Resetting limits for all Codex users later today", postedAt: at).hint, "今天晚些时候")
        XCTAssertEqual(ResetTiming.read("Will reset limits for everyone", postedAt: at).describe(now: at), "重置时间未说明")
        XCTAssertEqual(ResetTiming.read("in 5 hours", postedAt: at).describe(now: at.addingTimeInterval(3600)), "约 4 小时 0 分后重置")
    }
    func testPlannedNoticeNamesAccountsWithQuotaLeftAndExpires() {
        var planned = post(kind: "planned")
        planned = ResetAnnouncement(id: planned.id, text: "Resetting Codex limits for everyone in 3 hours", published_at: planned.published_at, url: planned.url, kind: "planned")
        let now = start.addingTimeInterval(60)
        let notice = ResetNotice.message(for: planned, accounts: [.init(name: "A", remaining: 0), .init(name: "B", remaining: 86), .init(name: "C", remaining: 71)], now: now)
        XCTAssertEqual(notice?.title, "Tibo 预告重置额度")
        XCTAssertEqual(notice?.body, "约 3 小时 0 分后重置。还有余量：B 86%、C 71%，抓紧用。")
        XCTAssertTrue(planned.isUpcoming(at: now))
        XCTAssertFalse(planned.isUpcoming(at: start.addingTimeInterval(3 * 3600 + 20)))
        XCTAssertNil(ResetNotice.message(for: post(kind: "possible_reset"), accounts: [], now: now))
        XCTAssertFalse(post().isUpcoming(at: now))
    }
}
