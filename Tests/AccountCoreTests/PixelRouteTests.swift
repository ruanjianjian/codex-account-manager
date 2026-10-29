import XCTest
@testable import AccountCore

final class PixelRouteTests: XCTestCase {
    typealias C = PixelRoute.Cell
    func testPathStepsOneCellAtATimeThroughEveryCorner() {
        let corners = [C(2, 10), C(9, 10), C(9, 3), C(15, 3)]
        let path = PixelRoute.path(corners)
        XCTAssertEqual(path.first, corners.first); XCTAssertEqual(path.last, corners.last)
        for corner in corners { XCTAssertTrue(path.contains(corner)) }
        for (a, b) in zip(path, path.dropFirst()) { XCTAssertEqual(abs(a.x - b.x) + abs(a.y - b.y), 1) }
        XCTAssertEqual(Set(path).count, path.count)
        XCTAssertEqual(PixelRoute.path([C(4, 4), C(4, 4)]), [C(4, 4)])
        XCTAssertTrue(PixelRoute.path([]).isEmpty)
    }
    func testRocketStaysOnRouteAndAdvancesOverTime() {
        let count = 40
        var previous = -1
        for step in 0..<10 {
            let head = PixelRoute.head(time: Double(step) * 0.1, offset: 0, count: count)
            XCTAssertTrue((0..<count).contains(head)); XCTAssertGreaterThan(head, previous); previous = head
        }
        XCTAssertEqual(PixelRoute.head(time: 1.6, offset: 0, count: count), 0, "one flight per period")
        XCTAssertEqual(PixelRoute.head(time: -0.4, offset: 0, count: count), PixelRoute.head(time: 1.2, offset: 0, count: count))
        XCTAssertEqual(PixelRoute.head(time: 3, offset: 0.5, count: 1), 0)
    }
    func testOffsetIsStableAndSpreadsRequests() {
        XCTAssertEqual(PixelRoute.offset(for: "1793-1"), PixelRoute.offset(for: "1793-1"))
        XCTAssertNotEqual(PixelRoute.offset(for: "1793-1"), PixelRoute.offset(for: "1793-2"))
        XCTAssertTrue((0..<1).contains(PixelRoute.offset(for: String(repeating: "z", count: 200))))
    }
    func testBurstGrowsFadesAndEnds() {
        let start = PixelRoute.burst(age: 0), late = PixelRoute.burst(age: 0.4)
        XCTAssertEqual(start?.alpha, 1); XCTAssertGreaterThan(late!.radius, start!.radius); XCTAssertLessThan(late!.alpha, start!.alpha)
        XCTAssertNil(PixelRoute.burst(age: 0.5)); XCTAssertNil(PixelRoute.burst(age: -0.1))
    }
}
