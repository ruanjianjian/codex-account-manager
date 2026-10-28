import AppKit
import AccountCore

@MainActor final class AccountDesktopLauncher {
    private struct Instance: Codable {
        let pid: Int32
        let launchedAt: Date
        let appPath: String
    }
    private var instances: [String: NSRunningApplication] = [:]

    private func appURL() throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.openai.codex" else { throw DesktopLaunchError.missingApp }
        // This adapter is intentionally restricted to the desktop build inspected locally.
        // Do not silently apply undocumented startup flags to arbitrary future versions.
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "26.1021.31345" else {
            throw DesktopLaunchError.unsupportedApp
        }
        return url.resolvingSymlinksInPath()
    }

    func running(root: URL, id: String) -> NSRunningApplication? {
        if let app = instances[id], !app.isTerminated { return app }
        guard let plan = try? DesktopLaunchPlan(root: root, accountID: id),
              let data = try? Data(contentsOf: plan.record), let record = try? JSONDecoder().decode(Instance.self, from: data),
              let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
              app.bundleIdentifier == "com.openai.codex", let date = app.launchDate,
              abs(date.timeIntervalSince(record.launchedAt)) < 0.01,
              app.bundleURL?.resolvingSymlinksInPath().path == record.appPath else { return nil }
        instances[id] = app
        return app
    }

    /// Returning an application means the window was launched, not that desktop sign-in is verified.
    func open(root: URL, id: String) async throws {
        if let app = running(root: root, id: id) {
            guard app.activate(options: [.activateAllWindows]) else { throw DesktopLaunchError.failed }
            return
        }
        let app = try appURL()
        let plan = try DesktopLaunchPlan(root: root, accountID: id)
        try FileManager.default.createDirectory(at: plan.userData, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = plan.arguments
        configuration.environment = plan.environment(inherited: ProcessInfo.processInfo.environment)
        let existingPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let instance: NSRunningApplication
        do { instance = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration) }
        catch { throw DesktopLaunchError.failed }
        guard !existingPIDs.contains(instance.processIdentifier) else { throw DesktopLaunchError.failed }
        instances[id] = instance
        guard let date = instance.launchDate else { throw DesktopLaunchError.persistence }
        let record = Instance(pid: instance.processIdentifier, launchedAt: date, appPath: app.path)
        do {
            try JSONEncoder().encode(record).write(to: plan.record, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.record.path)
        } catch { throw DesktopLaunchError.persistence }
    }
}
