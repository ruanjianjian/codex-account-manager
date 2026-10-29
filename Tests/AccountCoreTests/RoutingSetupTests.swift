import XCTest
@testable import AccountCore

final class RoutingSetupTests: XCTestCase {
    func testStepsComeInOrderAndRoutingTurnsItselfOn() {
        XCTAssertEqual(RoutingSetup.next(fileStorage: false, desktopAccountID: "a", desktopEnrolled: true, desktopEmail: nil), .fileStorage)
        XCTAssertEqual(RoutingSetup.next(fileStorage: true, desktopAccountID: nil, desktopEnrolled: false, desktopEmail: nil), .desktopLogin)
        XCTAssertEqual(RoutingSetup.next(fileStorage: true, desktopAccountID: "a", desktopEnrolled: false, desktopEmail: "me@example.com"),
                       .desktopAccount(email: "me@example.com"))
        let ready = RoutingSetup.next(fileStorage: true, desktopAccountID: "a", desktopEnrolled: true, desktopEmail: nil)
        XCTAssertEqual(ready, .ready)
        XCTAssertTrue(RoutingSetup.shouldEnable(ready, enabled: false, userChoice: nil))
        XCTAssertTrue(RoutingSetup.shouldEnable(ready, enabled: false, userChoice: true))
        XCTAssertFalse(RoutingSetup.shouldEnable(ready, enabled: false, userChoice: false), "a user who turned routing off keeps it off")
        XCTAssertFalse(RoutingSetup.shouldEnable(.fileStorage, enabled: false, userChoice: nil))
        XCTAssertFalse(RoutingSetup.shouldEnable(ready, enabled: true, userChoice: nil))
    }
    func testDesktopEmailAndNameComeFromTheIDToken() throws {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let idToken = [part(["alg": "none"]), part(["email": "me@example.com", "name": " Ada Lovelace "]), "sig"].joined(separator: ".")
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": "a", "access_token": "x", "refresh_token": "y", "id_token": idToken]])
        XCTAssertEqual(try DesktopCredential(auth).email, "me@example.com")
        XCTAssertEqual(try DesktopCredential(auth).name, "Ada Lovelace", "the name Codex shows becomes the card title")
        let noToken = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": "a", "access_token": "x", "refresh_token": "y"]])
        XCTAssertNil(try DesktopCredential(noToken).email)
    }
}
