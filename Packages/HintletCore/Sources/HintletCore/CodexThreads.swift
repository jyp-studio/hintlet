import Foundation

/// Codex threads as `~/.codex/session_index.jsonl` lists them: one line per thread, appended again when it
/// is renamed, so the last line for an ID has its current name.
///
/// The Codex app's address never names the thread it shows (`app://-/index.html`); its page title is the
/// thread's name. A name is only trusted when no other thread has it (ADR-0003).
public struct CodexThreadIndex: Equatable, Sendable {
    /// Current name by thread ID.
    public private(set) var names: [String: String] = [:]

    public init(jsonl: Data) {
        for line in jsonl.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty, let name = entry["thread_name"] as? String else { continue }
            names[id] = name
        }
    }

    /// The thread named exactly `title`, only if no other thread has that name.
    public func thread(titled title: String) -> String? {
        let named = names.filter { $0.value == title }
        return named.count == 1 ? named.first?.key : nil
    }
}

/// Tells which Codex thread a window shows. Never guesses: a title no thread has is a plain window (a new
/// thread, settings), and a title more than one thread has can't be told apart, so its notes go on the window.
public enum CodexThreads {
    public static let bundleID = "com.openai.codex"

    public static func page(title: String?, index: CodexThreadIndex) -> ClaudePage? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let id = index.thread(titled: title) {
            return .conversation(ConversationRef(kind: .codex, id: id), title: title)
        }
        return index.names.values.contains(title) ? .unrecognized : nil
    }
}

/// Reads what was said in a Codex thread from its rollout files under `~/.codex/sessions`, only ever reading
/// them. Only the user's and Codex's own words are kept: no developer or system context, reasoning, tool calls
/// or subagents.
///
/// Editing an earlier message starts another file for the same thread (`rollout-…-<thread>_<branch>.jsonl`)
/// that carries on from the edit; its lines are numbered (`ordinal`) on from the first file's.
public enum CodexTranscript {
    public static func messages(jsonl: Data) -> [TranscriptMessage] {
        entries(jsonl).compactMap(\.message)
    }

    /// The thread as it stands: the first file up to where the latest branch starts, then that branch.
    public static func messages(files: [Data]) -> [TranscriptMessage] {
        guard let first = files.first else { return [] }
        guard files.count > 1, let branch = files.last else { return messages(jsonl: first) }
        let branchEntries = entries(branch)
        let start = branchEntries.compactMap(\.ordinal).min() ?? .max
        let earlier = entries(first).filter { ($0.ordinal ?? .max) < start }
        return (earlier + branchEntries).compactMap(\.message)
    }

    private struct Entry {
        var ordinal: Int?
        var message: TranscriptMessage?
    }

    private static func entries(_ jsonl: Data) -> [Entry] {
        jsonl.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
            return Entry(ordinal: entry["ordinal"] as? Int, message: message(in: entry))
        }
    }

    private static func message(in entry: [String: Any]) -> TranscriptMessage? {
        guard entry["type"] as? String == "response_item", let payload = entry["payload"] as? [String: Any],
              payload["type"] as? String == "message", let parts = payload["content"] as? [[String: Any]] else { return nil }
        let role: TranscriptMessage.Role
        switch payload["role"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let text = parts.filter { ["input_text", "output_text"].contains($0["type"] as? String) }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        // Context Codex adds to the user's turn comes wrapped in tags of its own.
        let said = text.replacing(/<([a-z][a-z0-9_-]*)(\s[^>]*)?>[\s\S]*?<\/\1>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : TranscriptMessage(role: role, text: said)
    }
}

/// Where Codex keeps a thread's rollout files: `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread>[_<branch>].jsonl`.
public struct CodexRolloutFiles: Sendable {
    /// `~/.codex`.
    public let codexHome: URL

    public init(codexHome: URL) {
        self.codexHome = codexHome
    }

    public var sessionIndex: URL { codexHome.appendingPathComponent("session_index.jsonl") }

    /// The thread's files, the first one first and the latest branch last.
    public func files(for thread: String) -> [URL] {
        guard UUID(uuidString: thread) != nil,
              let walker = FileManager.default.enumerator(at: codexHome.appendingPathComponent("sessions"),
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let found = walker.compactMap { $0 as? URL }.filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            return url.pathExtension == "jsonl" && (name.hasSuffix("-\(thread)") || name.contains("-\(thread)_"))
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let first = found.filter { $0.deletingPathExtension().lastPathComponent.hasSuffix("-\(thread)") }
        let branches = found.filter { !first.contains($0) }.sorted { modified($0) < modified($1) }
        return first + branches.suffix(1)
    }

    /// The whole thread, as far as it was said.
    public func content(of thread: String) throws -> ConversationContent {
        let files = files(for: thread)
        guard !files.isEmpty else { throw ClaudeTranscriptFiles.ReadError.notFound }
        let data = try files.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
        return ConversationContent(messages: CodexTranscript.messages(files: data), coverage: .complete)
    }
}
