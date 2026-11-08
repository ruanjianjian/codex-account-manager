import XCTest
@testable import AccountCore

final class GatewayAgentTests: XCTestCase {
    let agent = GatewayAgent(bundleID: "io.github.ruanjianjian.codex-accounts",
                             directory: URL(fileURLWithPath: "/Users/me/Library/Application Support/CodexAccountsPublic/gateway"), port: 18456,
                             desktopAuth: URL(fileURLWithPath: "/Users/me/.codex/auth.json"),
                             launchAgents: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents"))

    func testTheAgentRunsItsOwnCopyAndLaunchdKeepsItUp() throws {
        let job = try XCTUnwrap(PropertyListSerialization.propertyList(from: agent.plist(), format: nil) as? [String: Any])
        XCTAssertEqual(job["Label"] as? String, "io.github.ruanjianjian.codex-accounts.gateway")
        XCTAssertEqual(agent.plistURL.path, "/Users/me/Library/LaunchAgents/io.github.ruanjianjian.codex-accounts.gateway.plist")
        // Not the binary inside Tibot.app: moving, updating or deleting the app never takes the gateway down.
        XCTAssertEqual(job["ProgramArguments"] as? [String], [
            "/Users/me/Library/Application Support/CodexAccountsPublic/gateway/AccountsGateway",
            "--config", "/Users/me/Library/Application Support/CodexAccountsPublic/gateway/pool.json",
            "--listen", "127.0.0.1:18456", "--desktop-auth", "/Users/me/.codex/auth.json"])
        XCTAssertEqual(job["KeepAlive"] as? Bool, true)
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["AssociatedBundleIdentifiers"] as? [String], ["io.github.ruanjianjian.codex-accounts"])
        XCTAssertEqual(try agent.plist(), try agent.plist(), "the same agent writes the same file, so nothing reloads it")
    }

    func testOnlyAnOlderTibotsChildOnThisPortIsStopped() throws {
        let child = try NSRegularExpression(pattern: agent.childPattern)
        func matches(_ line: String) -> Bool { child.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        XCTAssertTrue(matches("/Users/me/Applications/Tibot.app/Contents/Helpers/AccountsGateway --config /x/gateway/pool.json --listen 127.0.0.1:18456 --desktop-auth /Users/me/.codex/auth.json"))
        XCTAssertFalse(matches("/Applications/Codex Accounts.app/Contents/Helpers/AccountsGateway --config /y/pool.json --listen 127.0.0.1:18455 --desktop-auth /a"), "the private build's gateway")
        XCTAssertFalse(matches("/x/gateway/AccountsGateway --config /x/gateway/pool.json --listen 127.0.0.1:18456 --desktop-auth /a"), "the agent itself")
        XCTAssertFalse(matches("/x/Contents/Helpers/AccountsGateway --config /x/pool.json --listen 127.0.0.1:184567"))
    }

    func testEventStreamLines() {
        let event = GatewayActivityEvent.streamLine(#"data: {"kind":"direct","reason":"unknown_login","status":200}"#)
        XCTAssertEqual(event?.kind, "direct"); XCTAssertEqual(event?.reason, "unknown_login"); XCTAssertEqual(event?.status, 200)
        XCTAssertNil(GatewayActivityEvent.streamLine(": ping"))
        XCTAssertNil(GatewayActivityEvent.streamLine(""))
        XCTAssertNil(GatewayActivityEvent.streamLine("data: {broken"))
    }

    func testRoutingOffReachesTheGateway() throws {
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayPool(key: "k", preferred: "", accounts: [], off: true))) as? [String: Any]
        XCTAssertEqual(off?["off"] as? Bool, true)
        let on = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayPool(key: "k", preferred: "", accounts: []))) as? [String: Any]
        XCTAssertEqual(on?["off"] as? Bool, false)
    }

    /// The gateway tries a spent account again once every spent window has reset, even with Tibot not running.
    func testBackIsWhenEverySpentWindowHasReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fiveHours = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: 1_003_600)
        let weekly = QuotaWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: 1_500_000)
        XCTAssertEqual(GatewayAccount.back([fiveHours, weekly], now: now), 1_003_600, "the five-hour window, not the weekly reset")
        let weeklySpent = QuotaWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: 1_500_000)
        XCTAssertEqual(GatewayAccount.back([fiveHours, weeklySpent], now: now), 1_500_000, "both must have reset")
        XCTAssertEqual(GatewayAccount.back([weekly], now: now), 0, "nothing spent")
        XCTAssertEqual(GatewayAccount.back([QuotaWindow(usedPercent: 100, windowDurationMins: 300)], now: now), 0, "reset time unknown")
    }
}
