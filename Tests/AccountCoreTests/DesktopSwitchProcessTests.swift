import XCTest
@testable import AccountCore

final class DesktopSwitchProcessTests: XCTestCase {
    func testOnlyOwnDesktopAndCollectorDescendantsAreAllowed() throws {
        let processes = try DesktopSwitchProcess.parse("""
          100 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
          101 100 /Applications/ChatGPT.app/Contents/Resources/codex
          102 101 /usr/bin/node
          103 102 /opt/bin/codex-app-server
          200 1 /Users/example/Applications/Codex 账号管家.app/Contents/MacOS/CodexAccountManager
          201 200 /opt/bin/codex
          300 1 /usr/bin/python3
          301 300 /Applications/ChatGPT.app/Contents/Resources/codex
          400 1 /usr/bin/unrelated
        """)
        XCTAssertEqual(DesktopSwitchProcess.blockers(in: processes, allowedRoots: [100, 200]), [301])
        // After collectors stop, any remaining collector is a blocker too.
        XCTAssertEqual(DesktopSwitchProcess.blockers(in: processes, allowedRoots: [100]), [201, 301])
        XCTAssertEqual(DesktopSwitchProcess.blockers(in: processes, allowedRoots: []), [101, 103, 201, 301])
        XCTAssertTrue(processes[4].executable.contains("Codex 账号管家.app"))
    }
    func testMissingParentsAndCyclesFailClosed() throws {
        let processes = try DesktopSwitchProcess.parse("""
        4 99 /bin/codex
        5 6 /bin/codex-app-server
        6 5 /bin/node
        """)
        XCTAssertEqual(DesktopSwitchProcess.blockers(in: processes, allowedRoots: [1]), [4, 5])
    }
    func testMalformedProcessSnapshotIsRejected() {
        for text in ["unexpected", "x 1 /bin/codex", "3 -1 /bin/codex", "0 1 /bin/codex", "2 1"] {
            XCTAssertThrowsError(try DesktopSwitchProcess.parse(text))
        }
    }
}
