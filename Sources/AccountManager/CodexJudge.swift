import Foundation
import AccountCore

/// Asks the user's own Codex what a Tibo post means. Ephemeral (no session saved), read-only, without the user's
/// config or MCP servers; through the local gateway when routing is on, so a spent desktop account does not block it.
enum CodexJudge {
    static func verdict(text: String, postedAt: String, earlier: [String], binary: URL, gateway: String?) async -> ResetJudge.Verdict? {
        let prompt = ResetJudge.prompt(text: text, postedAt: postedAt, earlier: earlier, now: Date())
        return await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("tibot-judge-" + UUID().uuidString, isDirectory: true)
            guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil else { return nil }
            defer { try? fm.removeItem(at: work) }
            let schema = work.appendingPathComponent("schema.json"), out = work.appendingPathComponent("verdict.json")
            guard (try? ResetJudge.schema.write(to: schema, atomically: true, encoding: .utf8)) != nil else { return nil }
            var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                             "--sandbox", "read-only", "-c", #"model_reasoning_effort="low""#,
                             "--output-schema", schema.path, "-o", out.path, "-C", work.path]
            if let gateway { arguments += ["-c", "openai_base_url=\"\(gateway)\""] }
            let process = Process()
            process.executableURL = binary; process.arguments = arguments + [prompt]; process.currentDirectoryURL = work
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(120)
            while process.isRunning {
                if Date() > deadline { process.terminate(); return nil }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard process.terminationStatus == 0, let data = try? Data(contentsOf: out) else { return nil }
            return ResetJudge.parse(data)
        }.value
    }
}
