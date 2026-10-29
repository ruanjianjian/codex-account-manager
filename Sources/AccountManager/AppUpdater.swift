import AppKit
import CryptoKit
import AccountCore

/// Keeps the app current the way the one-line installer does: the release it names, checked by
/// SHA-256, signature, bundle and version, then swapped in place of the running copy and reopened.
@MainActor final class AppUpdater {
    enum UpdateError: LocalizedError {
        case noRelease, download, checksum, unpack, signature, wrongBundle, notWritable, replace
        var errorDescription: String? {
            switch self {
            case .noRelease: return "没读到最新版本号"
            case .download: return "下载失败"
            case .checksum: return "SHA-256 校验不通过"
            case .unpack: return "安装包解压失败"
            case .signature: return "安装包签名校验不通过"
            case .wrongBundle: return "安装包不是这个 App 或版本不符"
            case .notWritable: return "App 所在文件夹不可写"
            case .replace: return "替换 App 失败，已保留原版本"
            }
        }
    }
    private let environment = ProcessInfo.processInfo.environment
    /// The installer from main names the newest release (CODEX_ACCOUNTS_UPDATE_SOURCE overrides it for testing).
    private var source: URL {
        environment["CODEX_ACCOUNTS_UPDATE_SOURCE"].flatMap(URL.init(string:))
            ?? URL(string: "https://raw.githubusercontent.com/ruanjianjian/codex-account-manager/main/scripts/get.sh")!
    }
    private func base(for tag: String) -> URL {
        environment["CODEX_ACCOUNTS_UPDATE_BASE"].flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/ruanjianjian/codex-account-manager/releases/download/\(tag)")!
    }
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// The newest release tag, when it is newer than this app.
    func newerRelease() async throws -> String? {
        let (data, _) = try await session.data(from: source)
        guard let tag = AppVersion.latestTag(inInstaller: String(decoding: data, as: UTF8.self)) else { throw UpdateError.noRelease }
        return AppVersion.isNewer(tag, than: current) ? tag : nil
    }

    /// Downloads and checks the release; returns the unpacked app, ready to swap in.
    func prepare(_ tag: String) async throws -> URL {
        let zip = "Codex-Accounts-\(tag)-macos-arm64.zip"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("codex-accounts-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = self.session
        defer { session.finishTasksAndInvalidate() }
        let archive = work.appendingPathComponent(zip)
        do {
            let (sums, _) = try await session.data(from: base(for: tag).appendingPathComponent("SHA256SUMS.txt"))
            guard let expected = AppVersion.checksum(for: zip, in: String(decoding: sums, as: UTF8.self)) else { throw UpdateError.download }
            let (download, _) = try await session.download(from: base(for: tag).appendingPathComponent(zip))
            try FileManager.default.moveItem(at: download, to: archive)
            let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError.checksum }
        } catch let error as UpdateError { throw error } catch { throw UpdateError.download }
        let out = work.appendingPathComponent("out")
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, out.path]) else { throw UpdateError.unpack }
        // Packages keep the pre-0.4.9 folder name for older updaters; find the app whatever it is called.
        guard let app = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unpack }
        guard await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw UpdateError.signature }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppVersion.numbers(version) == AppVersion.numbers(tag) else { throw UpdateError.wrongBundle }
        return app
    }

    /// Moves the running copy to the Trash, puts the new one in the same folder as Tibot.app, and reopens it
    /// once this process has quit. If the copy fails the old app goes back where it was.
    func install(_ newApp: URL) async throws {
        let fm = FileManager.default, installed = Bundle.main.bundleURL
        let target = installed.deletingLastPathComponent().appendingPathComponent(AppRename.name)
        guard fm.isWritableFile(atPath: installed.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
        var trashed: NSURL?
        do { try fm.trashItem(at: installed, resultingItemURL: &trashed) } catch { throw UpdateError.replace }
        if target != installed, fm.fileExists(atPath: target.path) { try? fm.trashItem(at: target, resultingItemURL: nil) }
        guard await Self.run("/usr/bin/ditto", [newApp.path, target.path]) else {
            try? fm.removeItem(at: target)
            if let old = trashed as URL? { try? fm.moveItem(at: old, to: installed) }
            throw UpdateError.replace
        }
        AppRename.reopen(target, after: ProcessInfo.processInfo.processIdentifier)
    }

    /// Runs a system tool off the main thread (unpacking and verifying take a few seconds).
    private nonisolated static func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
