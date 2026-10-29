import AppKit
import ServiceManagement

/// Versions before 0.4.9 were "Codex Accounts Beta.app". The bundle ID never changed, so accounts,
/// permissions and settings carry over; only the folder is renamed, once, on the first launch.
enum AppRename {
    static let name = "Tibot.app"

    /// Moves an old-named copy to Tibot.app next to it and reopens from there. Returns true when this
    /// process is about to exit for that reopen; nothing else has started yet at that point.
    @MainActor static func moveToCurrentName() -> Bool {
        let fm = FileManager.default, current = Bundle.main.bundleURL, folder = current.deletingLastPathComponent()
        let target = folder.appendingPathComponent(name)
        guard current.lastPathComponent != name, current.pathExtension == "app",
              fm.isWritableFile(atPath: folder.path), !fm.fileExists(atPath: target.path) else { return false }
        let wasLoginItem = SMAppService.mainApp.status == .enabled
        do { try fm.moveItem(at: current, to: target) } catch { return false }
        // Launch at login is recorded by path; register the new one once it is running from there.
        if wasLoginItem { UserDefaults.standard.set(true, forKey: "login.reregister") }
        reopen(target, after: ProcessInfo.processInfo.processIdentifier, arguments: Array(CommandLine.arguments.dropFirst()))
        return true
    }

    /// Opens `app` once the process `pid` has quit (only one copy of the app may run at a time).
    static func reopen(_ app: URL, after pid: Int32, arguments: [String] = []) {
        let script = "pid=$1; app=$2; shift 2; while kill -0 \"$pid\" 2>/dev/null; do sleep 0.2; done; " +
            "if [ $# -gt 0 ]; then /usr/bin/open \"$app\" --args \"$@\"; else /usr/bin/open \"$app\"; fi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), app.path] + arguments
        try? process.run()
    }
}
