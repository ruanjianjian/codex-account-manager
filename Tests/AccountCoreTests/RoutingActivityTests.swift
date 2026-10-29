import XCTest
@testable import AccountCore

final class RoutingActivityTests: XCTestCase {
    func testConcurrentRequestsAndFailoverRemainIndependent() {
        var activity = RoutingActivity()
        activity.receive(.init(kind: "routing", account: "a", request: "one"))
        activity.receive(.init(kind: "routing", account: "a", request: "two"))
        XCTAssertEqual(activity.count(for: "a"), 2)
        activity.receive(.init(kind: "refused", account: "a", request: "one", status: 429))
        XCTAssertEqual(activity.count(for: "a"), 1)
        XCTAssertEqual(activity.reroutes, 0)
        activity.receive(.init(kind: "routing", account: "b", request: "one"))
        XCTAssertEqual(activity.reroutes, 1)
        activity.receive(.init(kind: "completed", account: "b", request: "one"))
        activity.receive(.init(kind: "completed", account: "b", request: "one"))
        activity.receive(.init(kind: "finished", request: "one"))
        XCTAssertEqual(activity.completed, 1)
        XCTAssertEqual(activity.count(for: "a"), 1)
        activity.receive(.init(kind: "finished", request: "two"))
        XCTAssertTrue(activity.active.isEmpty)
        XCTAssertEqual(activity.completed, 1)
    }
    func testInterruptedAndStoppedDoNotLeavePhantomTraffic() {
        var activity = RoutingActivity()
        activity.receive(.init(kind: "routing", account: "a", request: "one"))
        activity.receive(.init(kind: "interrupted", account: "a", request: "one"))
        activity.receive(.init(kind: "finished", request: "one"))
        XCTAssertTrue(activity.active.isEmpty)
        XCTAssertEqual(activity.lastKind, "interrupted")
        activity.receive(.init(kind: "routing", account: "b", request: "two"))
        activity.receive(.init(kind: "stopped"))
        XCTAssertTrue(activity.active.isEmpty)
        XCTAssertEqual(activity.completed, 0)
    }
    func testGatewayRejectionDecodesReasonAndClearsTraffic() throws {
        let line = #"{"request":"r1","kind":"rejected","status":409,"reason":"sealed_owner_unavailable","account":"a","time":"2026-10-29T00:00:00Z"}"#
        let event = try JSONDecoder().decode(GatewayActivityEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.reason, "sealed_owner_unavailable"); XCTAssertEqual(event.status, 409)
        var activity = RoutingActivity()
        activity.receive(.init(kind: "routing", account: "a", request: "r1"))
        activity.receive(event)
        XCTAssertTrue(activity.active.isEmpty); XCTAssertEqual(activity.lastKind, "rejected")
    }
}
