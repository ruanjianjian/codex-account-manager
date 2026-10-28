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
}
