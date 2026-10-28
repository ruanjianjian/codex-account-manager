import XCTest
import CoreGraphics
@testable import AccountCore

final class PanelHoverTests: XCTestCase {
    private func tick(_ hover: inout PanelHover, _ time: Double, trigger: Bool = false,
                      panel: Bool = false, visible: Bool = false, needsShow: Bool = true,
                      pinned: Bool = false, interacting: Bool = false) -> PanelHover.Action? {
        hover.sample(now: time, overTrigger: trigger, overPanel: panel, visible: visible,
                     needsShow: needsShow, pinned: pinned, interacting: interacting)
    }
    func testDwellOpensWithoutAnyEnterCallbackAndDoesNotRepeatedlyRefresh() {
        var hover = PanelHover()
        XCTAssertNil(tick(&hover, 0, trigger: true))
        XCTAssertNil(tick(&hover, 0.12, trigger: true))
        XCTAssertEqual(tick(&hover, 0.24, trigger: true), .show)
        XCTAssertNil(tick(&hover, 0.5, trigger: true, visible: true, needsShow: false))
        XCTAssertNil(tick(&hover, 1, trigger: true, visible: true, needsShow: false))
    }
    func testPinnedHiddenPanelCanOpenButDoesNotAutoClose() {
        var hover = PanelHover()
        XCTAssertNil(tick(&hover, 0, trigger: true, pinned: true))
        XCTAssertEqual(tick(&hover, 0.24, trigger: true, pinned: true), .show)
        XCTAssertNil(tick(&hover, 0.5, visible: true, pinned: true))
        XCTAssertNil(tick(&hover, 2, visible: true, pinned: true))
    }
    func testClickDismissalDoesNotReopenUntilPointerLeavesAndReturns() {
        var hover = PanelHover()
        _ = tick(&hover, 0, trigger: true)
        hover.suppressUntilExit()
        XCTAssertNil(tick(&hover, 1, trigger: true))
        XCTAssertNil(tick(&hover, 2))
        XCTAssertNil(tick(&hover, 3, trigger: true))
        XCTAssertEqual(tick(&hover, 3.24, trigger: true), .show)
    }
    func testCrossingGapIntoPanelCancelsCloseAndLeavingLaterCloses() {
        var hover = PanelHover()
        XCTAssertNil(tick(&hover, 0, visible: true))
        XCTAssertNil(tick(&hover, 0.2, panel: true, visible: true))
        XCTAssertNil(tick(&hover, 1, panel: true, visible: true))
        XCTAssertNil(tick(&hover, 2, visible: true))
        XCTAssertNil(tick(&hover, 2.3, visible: true))
        XCTAssertEqual(tick(&hover, 2.4, visible: true), .hide)
    }
    func testMenusDraggingAndUtilityWindowsSuspendHoverTransitions() {
        var hover = PanelHover()
        XCTAssertNil(tick(&hover, 0, trigger: true, interacting: true))
        XCTAssertNil(tick(&hover, 1, trigger: true, interacting: true))
        XCTAssertNil(tick(&hover, 2, visible: true, interacting: true))
        XCTAssertNil(tick(&hover, 3, visible: true, interacting: true))
        XCTAssertNil(tick(&hover, 4, trigger: true))
        XCTAssertEqual(tick(&hover, 4.24, trigger: true), .show)
    }
    func testFastPassDoesNotOpenAndDifferentDisplayCanRequestShow() {
        var hover = PanelHover()
        XCTAssertNil(tick(&hover, 0, trigger: true))
        XCTAssertNil(tick(&hover, 0.12))
        XCTAssertNil(tick(&hover, 1, trigger: true, visible: true, needsShow: true))
        XCTAssertEqual(tick(&hover, 1.24, trigger: true, visible: true, needsShow: true), .show)
    }
    func testQuartzBoundsConvertForPrimaryLeftAndUpperDisplays() {
        XCTAssertEqual(PanelHover.appKitRect(fromQuartz: CGRect(x: 1200, y: 0, width: 90, height: 24), primaryTop: 900), CGRect(x: 1200, y: 876, width: 90, height: 24))
        XCTAssertEqual(PanelHover.appKitRect(fromQuartz: CGRect(x: -200, y: -180, width: 90, height: 24), primaryTop: 900), CGRect(x: -200, y: 1056, width: 90, height: 24))
    }
}
