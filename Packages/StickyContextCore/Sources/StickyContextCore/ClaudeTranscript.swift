import Foundation

/// Reads what was said in a Claude Code or Cowork conversation from its local transcript: one JSON object
/// a line, in the format Claude Code writes. Only the user's and Claude's own words are kept; internal
/// messages, thinking, tool calls and results, subagents and system reminders are left out.
public enum ClaudeTranscript {
    public static func messages(jsonl: Data) -> [TranscriptMessage] {
        jsonl.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
            return message(in: entry)
        }
    }

    private static func message(in entry: [String: Any]) -> TranscriptMessage? {
        guard entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return nil }
        let role: TranscriptMessage.Role
        switch entry["type"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return nil
        }
        let said = spoken(text)
        return said.isEmpty ? nil : TranscriptMessage(role: role, text: said)
    }

    /// Without the tags Claude Code wraps around its own additions. A slash command keeps its name and
    /// what the user typed after it.
    private static func spoken(_ text: String) -> String {
        if let name = inner("command-name", of: text) {
            return [name, inner("command-args", of: text) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let untagged = text.replacing(/<([a-z][a-z0-9-]*)(\s[^>]*)?>[\s\S]*?<\/\1>/, with: "")
        return untagged.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inner(_ tag: String, of text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where Code and Cowork keep a session's transcript: its session file (in Claude's folder) names the
/// Claude Code session behind it, whose transcript is `<cliSessionId>.jsonl` under a `projects` folder —
/// `~/.claude/projects/<project>/` for Code, the session's own folder for Cowork. Only ever read.
public struct ClaudeTranscriptFiles: Sendable {
    public enum ReadError: Error, Equatable {
        /// No session file, or no transcript for it (also Chat and terminal sessions, which aren't read here).
        case notFound
    }

    public let sessionFolder: ClaudeSessionFolder
    /// `~/.claude`.
    public let claudeHome: URL

    public init(sessionFolder: ClaudeSessionFolder, claudeHome: URL) {
        self.sessionFolder = sessionFolder
        self.claudeHome = claudeHome
    }

    /// The whole conversation, as far as it was said.
    public func content(of ref: ConversationRef) throws -> ConversationContent {
        guard let url = transcript(for: ref) else { throw ReadError.notFound }
        return try Self.content(at: url)
    }

    /// The transcript file's conversation.
    public static func content(at url: URL) throws -> ConversationContent {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return ConversationContent(messages: ClaudeTranscript.messages(jsonl: data), coverage: .complete)
    }

    public func transcript(for ref: ConversationRef) -> URL? {
        guard [.code, .cowork].contains(ref.kind), let session = sessionFolder.file(for: ref),
              let data = try? Data(contentsOf: session),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cliSessionID = object["cliSessionId"] as? String, !cliSessionID.isEmpty,
              !cliSessionID.contains("/") else { return nil }
        let projects = ref.kind == .code
            ? claudeHome.appendingPathComponent("projects")
            : session.deletingPathExtension().appendingPathComponent(".claude/projects")
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent("\(cliSessionID).jsonl") }
            .first { manager.fileExists(atPath: $0.path) }
    }
}
