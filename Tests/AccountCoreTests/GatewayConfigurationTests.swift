import XCTest
@testable import AccountCore

final class GatewayConfigurationTests: XCTestCase {
    func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }; return d
    }
    func testRestoreExactAndProtectConcurrentEdits() throws {
        let home = try directory(), root = try directory()
        let path = home.appendingPathComponent("config.toml")
        let before = Data("model = \"gpt-5\"\nmodel_provider = \"original\"\n[projects.\"/work\"]\ntrust_level = \"trusted\"\n".utf8)
        try before.write(to: path)
        let plan = GatewayConfiguration(home: home, root: root)
        try plan.install(key: String(repeating: "a", count: 64), port: 18455)
        let applied = try Data(contentsOf: path)
        XCTAssertTrue(String(decoding: applied, as: UTF8.self).contains("[projects.\"/work\"]"))
        try Data("user edited".utf8).write(to: path)
        XCTAssertThrowsError(try plan.restore())
        XCTAssertEqual(try String(contentsOf: path), "user edited")
        try applied.write(to: path); try plan.restore()
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    func testUnrelatedSettingsSurviveRestartAndRestore() throws {
        let home = try directory(), root = try directory(), path = home.appendingPathComponent("config.toml")
        try Data("service_tier = \"fast\"\nmodel_provider = \"openai\"\n".utf8).write(to: path)
        let plan = GatewayConfiguration(home: home, root: root), key = String(repeating: "a", count: 64)
        try plan.install(key: key, port: 18455)
        let changed = try String(contentsOf: path).replacingOccurrences(of: "service_tier = \"fast\"", with: "service_tier = \"flex\"")
        try Data(changed.utf8).write(to: path)
        try plan.install(key: key, port: 18455)
        try plan.restore()
        let restored = try String(contentsOf: path)
        XCTAssertTrue(restored.contains("service_tier = \"flex\""))
        XCTAssertTrue(restored.contains("model_provider = \"openai\""))
        XCTAssertFalse(restored.contains("codex_accounts_gateway"))
    }
    func testModifiedGatewayTableIsNotOverwritten() throws {
        let home = try directory(), root = try directory(), path = home.appendingPathComponent("config.toml")
        let plan = GatewayConfiguration(home: home, root: root)
        try plan.install(key: String(repeating: "a", count: 64), port: 18455)
        let changed = try String(contentsOf: path).replacingOccurrences(of: "18455", with: "18458")
        try Data(changed.utf8).write(to: path)
        XCTAssertThrowsError(try plan.restore())
        XCTAssertEqual(try String(contentsOf: path), changed)
    }
    func testNativeModePreservesFastAndLegacyProviderTable() throws {
        let home = try directory(), root = try directory(), path = home.appendingPathComponent("config.toml")
        try Data("service_tier = \"fast\"\nmodel_provider = \"openai\"\nopenai_base_url = \"https://example.test/v1\"\n".utf8).write(to: path)
        let original = try Data(contentsOf: path)
        let plan = GatewayConfiguration(home: home, root: root)
        try plan.install(key: String(repeating: "a", count: 64), port: 18455)
        let installed = try String(contentsOf: path)
        XCTAssertTrue(installed.hasPrefix("model_provider = \"openai\""))
        XCTAssertTrue(installed.contains("openai_base_url = \"http://127.0.0.1:18455/backend-api/codex\""))
        XCTAssertTrue(installed.contains("service_tier = \"fast\""))
        XCTAssertTrue(installed.contains("[model_providers.codex_accounts_gateway]"))
        try plan.restore(); XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testUpgradeFirstBetaKeepsOriginalRollbackAndConcurrentSettings() throws {
        let home = try directory(), root = try directory(), path = home.appendingPathComponent("config.toml")
        let plan = GatewayConfiguration(home: home, root: root), key = String(repeating: "a", count: 64)
        let original = Data("service_tier = \"fast\"\n".utf8); try original.write(to: path)
        try plan.install(key: key, port: 18455)
        let legacy = try String(contentsOf: path).replacingOccurrences(of: "model_provider = \"openai\"\nopenai_base_url = \"http://127.0.0.1:18455/backend-api/codex\"\n", with: "model_provider = \"codex_accounts_gateway\"\n")
        try Data(legacy.utf8).write(to: root.appendingPathComponent("config.gateway-applied"))
        try Data((legacy.replacingOccurrences(of: "service_tier = \"fast\"", with: "service_tier = \"flex\"")).utf8).write(to: path)
        try plan.install(key: key, port: 18455)
        XCTAssertTrue(try String(contentsOf: path).hasPrefix("model_provider = \"openai\""))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("config.before-gateway")).contains("service_tier = \"flex\""))
        try plan.restore()
        XCTAssertTrue(try String(contentsOf: path).contains("service_tier = \"flex\""))
        XCTAssertFalse(try String(contentsOf: path).contains("codex_accounts_gateway"))
    }
    func testProviderCollisionAndSymlinkRejected() throws {
        let home = try directory(), root = try directory(), target = try directory().appendingPathComponent("config")
        let path = home.appendingPathComponent("config.toml")
        try Data("model_provider = \"codex_accounts_gateway\"".utf8).write(to: path)
        let plan = GatewayConfiguration(home: home, root: root)
        XCTAssertThrowsError(try plan.install(key: String(repeating: "a", count: 64), port: 18455))
        try FileManager.default.removeItem(at: path);try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        XCTAssertThrowsError(try plan.install(key: String(repeating: "a", count: 64), port: 18455))
    }
}
