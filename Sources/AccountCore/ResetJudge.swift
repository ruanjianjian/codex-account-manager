import Foundation

/// Optional model reading of a Tibo post, run through the user's own Codex. The keyword rules stay the fallback:
/// a post the model could not judge is read by the rules as before.
public enum ResetJudge {
    public struct Verdict: Codable, Equatable {
        public let kind: String
        public let reset_at: String?
        public let note: String
        public init(kind: String, reset_at: String?, note: String) { self.kind = kind; self.reset_at = reset_at; self.note = note }
    }
    static let kinds = ["planned", "reported_completed", "banked", "limits", "possible_reset", "none"]
    /// JSON Schema for `codex exec --output-schema`.
    public static let schema = #"{"type":"object","additionalProperties":false,"required":["kind","reset_at","note"],"properties":{"kind":{"type":"string","enum":["planned","reported_completed","banked","limits","possible_reset","none"]},"reset_at":{"type":["string","null"]},"note":{"type":"string"}}}"#

    /// Replies are conversation, never announcements: not worth a model call.
    public static func worthAsking(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@")
    }

    /// `earlier` are Tibo's previous posts, newest first: "Lands by midnight PST." only means something after
    /// "today is a reset".
    public static func prompt(text: String, postedAt: String, earlier: [String], now: Date) -> String {
        let context = earlier.prefix(3).map { "- " + String($0.replacingOccurrences(of: "\n", with: " ").prefix(280)) }
        return """
        Classify one post by Thibault Sottiaux (@thsottiaux, OpenAI Codex lead) for an app that alerts Codex users about usage-limit resets.
        Posted at: \(postedAt). Now: \(ISO8601DateFormatter().string(from: now)).
        \(context.isEmpty ? "" : "His previous posts, newest first (context only):\n" + context.joined(separator: "\n") + "\n")Post:
        <<<
        \(text)
        >>>
        kind:
        - planned: a reset of Codex usage limits is announced for a later time
        - reported_completed: limits have just been reset for users
        - banked: users get extra banked resets
        - limits: usage limits are raised, doubled or otherwise changed, effective now
        - possible_reset: mentions a reset, but it is unclear whether limits reset
        - none: anything else (jokes, product news, replies, hypotheticals, questions)
        reset_at: the reset time in ISO 8601 UTC when the post states or implies one, else null.
        note: one short Chinese sentence (at most 40 characters) telling a user what this means for their quota; empty for none.
        Do not run commands. Reply with the JSON only.
        """
    }

    /// A verdict from the model's last message, or nil when it is not one of the known kinds.
    public static func parse(_ data: Data) -> Verdict? {
        guard let value = try? JSONDecoder().decode(Verdict.self, from: data), kinds.contains(value.kind) else { return nil }
        let note = String(value.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return Verdict(kind: value.kind, reset_at: value.reset_at.flatMap { ResetFeed.date($0) == nil ? nil : $0 }, note: note)
    }
}

extension ResetFeed {
    /// The same feed with the model's reading in place of the source's own classification.
    public func applying(_ verdicts: [String: ResetJudge.Verdict]) -> ResetFeed {
        ResetFeed(available: available, stale: stale, handle: handle, updated_at: updated_at, items: items.map { post in
            guard let v = verdicts[post.id] else { return post }
            return ResetAnnouncement(id: post.id, text: post.text, published_at: post.published_at, url: post.url, kind: v.kind, reset_at: v.reset_at, note: v.note)
        })
    }
}
