import XCTest
@testable import AccountCore

final class MascotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func account(_ id: String, _ remaining: Double?, backIn hours: Double? = nil) -> Mascot.Account {
        .init(id: id, name: id == "w" ? "工作号" : "个人号", remaining: remaining, backAt: hours.map { now.addingTimeInterval($0 * 3600) })
    }
    private func line(_ accounts: [Mascot.Account], _ change: (inout Mascot.Input) -> Void = { _ in }) -> Mascot.Line {
        var input = Mascot.Input(accounts: accounts); input.now = now; input.routing = true; input.gatewayReady = true
        change(&input)
        return Mascot.line(input)
    }

    func testSaysWhichAccountCodexIsOn() {
        let accounts = [account("w", 40), account("p", 80)]
        XCTAssertEqual(line(accounts) { $0.current = "p" }, .init(.open, "正在用 个人号"))
        XCTAssertEqual(line(accounts) { $0.current = "p"; $0.cacheHit = true }, .init(.open, "正在用 个人号 · 缓存命中"))
        XCTAssertEqual(line(accounts) { $0.current = "p"; $0.cacheHit = true; $0.routing = false }, .init(.open, "正在用 个人号"),
                       "the cache line is about routed requests only")
        XCTAssertEqual(line(accounts) { $0.gatewayReady = false }, .init(.puzzled, "等待网关…"))
        XCTAssertEqual(line(accounts), .init(.open, "等待请求"))
    }
    func testHopsWhenRoutingMovesOn() {
        let accounts = [account("w", 0, backIn: 3), account("p", 62)]
        XCTAssertEqual(line(accounts) { $0.current = "p"; $0.switched = .init(from: "w", to: "p") }, .init(.hop, "工作号 用完，换到 个人号"))
        let both = [account("w", 30), account("p", 62)]
        XCTAssertEqual(line(both) { $0.current = "p"; $0.switched = .init(from: "w", to: "p") }, .init(.hop, "换到 个人号"))
    }
    func testWelcomesBeforeAnyAccount() {
        XCTAssertEqual(line([]), .init(.hello, "嗨，我是 Tibot"))
        XCTAssertEqual(line([account("w", nil)]), .init(.hello, "先连上账号吧"))
    }
    func testResetAlertOutranksTheUsualLine() {
        let accounts = [account("w", 40), account("p", 80)]
        XCTAssertEqual(line(accounts) { $0.current = "p"; $0.resetAlert = "Tibo 预告约 5 小时后重置 · 抓紧用" },
                       .init(.star, "Tibo 预告约 5 小时后重置 · 抓紧用"))
    }
    func testAllSpentSaysWhenTheFirstOneComesBack() {
        let accounts = [account("w", 0, backIn: 3.5), account("p", 0, backIn: 30), account("x", nil)]
        XCTAssertTrue(Mascot.allSpent(accounts), "an account without data does not count as usable")
        XCTAssertEqual(Mascot.nextBack(accounts)?.id, "w")
        XCTAssertEqual(line(accounts) { $0.resetAlert = "Tibo 预告约 5 小时后重置 · 抓紧用" }, .init(.sad, "额度都用完了，工作号 3 小时后恢复"))
        XCTAssertFalse(Mascot.allSpent([account("w", 0), account("p", 5)]))
        XCTAssertFalse(Mascot.allSpent([account("w", nil)]), "no data is not the same as spent")
    }
    func testComesBackWording() {
        XCTAssertEqual(Mascot.comesBack(now.addingTimeInterval(2 * 86_400 + 10), now: now), "2 天后恢复")
        XCTAssertEqual(Mascot.comesBack(now.addingTimeInterval(20 * 60), now: now), "20 分钟后恢复")
        XCTAssertEqual(Mascot.comesBack(now.addingTimeInterval(-5), now: now), "即将恢复")
        XCTAssertEqual(Mascot.comesBack(nil, now: now), "等待重置")
    }
    func testASpentAccountComesBackWhenItsLastSpentWindowResets() {
        let hourly = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970 + 3600)
        let weekly = QuotaWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970 + 86_400)
        XCTAssertEqual([hourly, weekly].comesBackAt, now.addingTimeInterval(86_400), "the 5-hour reset does not help while the week is spent")
        let weeklyLeft = QuotaWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970 + 86_400)
        XCTAssertEqual([hourly, weeklyLeft].comesBackAt, now.addingTimeInterval(3600))
    }
}
