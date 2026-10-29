import XCTest
import CoreGraphics
@testable import AccountCore

final class WidgetPlacementTests: XCTestCase {
    func testResizingFitsSmallDisplayWithoutLosingPreferredSize() {
        let preferred = CGSize(width: 900, height: 1200)
        let small = CGRect(x: -800, y: 100, width: 800, height: 600)
        XCTAssertEqual(WidgetPlacement.fittedSize(preferred, visibleFrame: small), CGSize(width: 784, height: 584))
        XCTAssertEqual(WidgetPlacement.fittedSize(preferred, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1400)), preferred)
        XCTAssertEqual(WidgetPlacement.fittedSize(CGSize(width: 100, height: 100), visibleFrame: small), CGSize(width: 400, height: 480))
        let tiny = CGRect(x: 0, y: 0, width: 360, height: 400)
        XCTAssertEqual(WidgetPlacement.fittedSize(preferred, visibleFrame: tiny), CGSize(width: 344, height: 384))
    }

    func testFindsClickedDisplayForLeftAndAboveArrangements() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                      CGRect(x: 0, y: 900, width: 1920, height: 1080)]
        XCTAssertEqual(WidgetPlacement.screenIndex(containing: CGPoint(x: -200, y: 1060), frames: frames), 1)
        XCTAssertEqual(WidgetPlacement.screenIndex(containing: CGPoint(x: 1800, y: 1950), frames: frames), 2)
        XCTAssertNil(WidgetPlacement.screenIndex(containing: CGPoint(x: -3000, y: 0), frames: frames))
    }

    func testPanelStaysInsideTargetDisplayNearEitherEdge() {
        let area = CGRect(x: -1920, y: 30, width: 1920, height: 1025)
        let size = CGSize(width: 448, height: 766)
        for point in [CGPoint(x: -1918, y: 1070), CGPoint(x: -2, y: 1070)] {
            let origin = WidgetPlacement.origin(near: point, panelSize: size, visibleFrame: area)
            XCTAssertTrue(area.contains(CGRect(origin: origin, size: size)))
            XCTAssertEqual(origin.y + size.height, area.maxY - 8)
        }
    }
    func testEmbeddedComponentSitsBesideNativeWidgetsAndStaysOnScreen() {
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1056)
        let size = CGSize(width: 549, height: 335)
        let origin = WidgetPlacement.embeddedOrigin(panelSize: size, visibleFrame: area)
        XCTAssertEqual(origin, CGPoint(x: 378, y: 1056 - 335 - 10))
        let narrow = CGRect(x: -800, y: 0, width: 800, height: 600)
        let fitted = WidgetPlacement.embeddedOrigin(panelSize: size, visibleFrame: narrow)
        XCTAssertTrue(narrow.contains(CGRect(origin: fitted, size: size)))
    }
    func testSettingsOpenBesideDashboardWithTopsAligned() {
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1056)
        let size = CGSize(width: 400, height: 640)
        let dashboard = CGRect(x: 915, y: 1056 - 38 - 733, width: 439, height: 733)
        let left = WidgetPlacement.besideOrigin(windowSize: size, anchor: dashboard, visibleFrame: area)
        XCTAssertEqual(left.x + size.width, dashboard.minX - 10)
        XCTAssertEqual(left.y + size.height, dashboard.maxY)
        let atLeftEdge = CGRect(x: 8, y: 300, width: 439, height: 733)
        XCTAssertEqual(WidgetPlacement.besideOrigin(windowSize: size, anchor: atLeftEdge, visibleFrame: area).x, atLeftEdge.maxX + 10)
        XCTAssertEqual(WidgetPlacement.besideOrigin(windowSize: size, anchor: nil, visibleFrame: area), CGPoint(x: 760, y: 208))
    }
}
