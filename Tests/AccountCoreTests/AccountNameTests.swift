import XCTest
@testable import AccountCore

final class AccountNameTests: XCTestCase {
    func testNamePresentationUsesProfileThenMaskedIdentityAndOptionalOverride() {
        var slot = AccountSlot(id:"account-5", name:"账号 5", chromeProfile:"Profile 1")
        slot.expectedEmail = "one@example.com"
        XCTAssertEqual(slot.displayName, "on•••@example.com")
        slot.codexName = "Celine"
        XCTAssertEqual(slot.displayName, "Celine")
        slot.nameOverride = "Work"
        XCTAssertEqual(slot.displayName, "Work")
        slot.nameOverride = nil
        XCTAssertEqual(slot.displayName, "Celine")
    }
}
