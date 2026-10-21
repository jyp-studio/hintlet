import Foundation

/// Which model wrote a summary. Kept as text in the notes file, so a backend from a newer Hintlet still reads.
public struct SummaryBackend: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Apple's on-device model (Foundation Models): nothing leaves the Mac.
    public static let onDevice = SummaryBackend(rawValue: "onDevice")
    /// The Claude API with the user's own key (ticket 16): the conversation is uploaded.
    public static let claudeAPI = SummaryBackend(rawValue: "claudeAPI")
    /// The Claude Code CLI the user signed in to, on their Claude plan: the conversation is uploaded to Anthropic.
    public static let claudeAccount = SummaryBackend(rawValue: "claudeAccount")
    /// The Codex CLI the user signed in to, on their ChatGPT plan: the conversation is uploaded to OpenAI.
    public static let codexAccount = SummaryBackend(rawValue: "codexAccount")
    /// The OpenAI API with the user's own key: the conversation is uploaded.
    public static let openAIAPI = SummaryBackend(rawValue: "openAIAPI")

    /// Whether what it is given leaves the Mac: every backend but the on-device model.
    public var uploadsContent: Bool { self != .onDevice }
}

/// How much of the conversation a summary is based on.
public enum SummaryCoverage: Equatable, Codable, Sendable {
    /// The whole conversation could be read (Code and Cowork keep it on disk).
    case complete
    /// Only the messages the page had loaded (Chat, ticket 15).
    case partial(loadedMessages: Int)
    /// Too little to say anything; the summary says so instead of making something up.
    case insufficient
}

/// One message of a conversation, as far as a summary needs it.
public struct TranscriptMessage: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user, assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// What a summary may be based on: the messages the user allowed to be read, and how much of the
/// conversation they are.
public struct ConversationContent: Equatable, Sendable {
    public var messages: [TranscriptMessage]
    public var coverage: SummaryCoverage
    /// Changes whenever the conversation does; an automatic refresh is skipped while it stays the same.
    public var revision: String

    public init(messages: [TranscriptMessage], coverage: SummaryCoverage, revision: String? = nil) {
        self.messages = messages
        self.coverage = coverage
        self.revision = revision ?? "\(messages.count):\(Self.stableHash(messages.last?.text ?? ""))"
    }

    /// FNV-1a: the same across runs, unlike `hashValue`, since revisions are saved with the summary.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// An AI note's content: what the conversation is doing, where it stopped and what comes next.
public struct AISummary: Equatable, Codable, Sendable {
    public var doing: String
    public var stoppedAt: String
    public var next: String
    public var coverage: SummaryCoverage
    public var backend: SummaryBackend
    public var updatedAt: Date
    /// The `ConversationContent.revision` it was made from.
    public var sourceRevision: String?

    public init(doing: String, stoppedAt: String, next: String, coverage: SummaryCoverage,
                backend: SummaryBackend, updatedAt: Date, sourceRevision: String? = nil) {
        self.doing = doing
        self.stoppedAt = stoppedAt
        self.next = next
        self.coverage = coverage
        self.backend = backend
        self.updatedAt = updatedAt
        self.sourceRevision = sourceRevision
    }

    /// A summary as it is written now: the conversation's goal, the gist of where it has got to, and what
    /// the user is to look at or do next (none when nothing is waiting on them). Stored in the older three
    /// fields, so notes saved before read back as they were.
    public init(goal: String, point: String, next: String = "", coverage: SummaryCoverage, backend: SummaryBackend,
                updatedAt: Date, sourceRevision: String? = nil) {
        self.init(doing: goal, stoppedAt: point, next: next, coverage: coverage, backend: backend, updatedAt: updatedAt,
                  sourceRevision: sourceRevision)
    }

    /// What the conversation as a whole is for, in a few words.
    public var goal: String { doing }
    /// The gist of the latest progress: the conclusion, result, cause or decision itself.
    public var point: String { stoppedAt }

    /// What it says, line by line, or none when there was too little to go on.
    public var lines: [String] {
        coverage == .insufficient ? [] : [doing, stoppedAt, next].filter { !$0.isEmpty }
    }

    /// The state the next step starts with ("等你：在 Google Drive 排除 ~/dev"), and the rest of it.
    public var state: (SummaryState, String) { SummaryState.split(next) }
}

/// Where Claude is in the conversation, which the note shows at a glance.
public enum SummaryState: CaseIterable, Sendable {
    case working, waitingForYou, stuck
    /// An older summary, or one whose status doesn't say.
    case unknown

    /// The words a status may start with, in the languages summaries are written in.
    static let words: [SummaryState: [String]] = [
        .working: ["進行中", "In progress", "Working"],
        .waitingForYou: ["等你", "等待你", "Your turn", "Waiting for you"],
        .stuck: ["卡住", "Stuck", "Blocked"],
    ]

    /// "等你：要不要合併" → (.waitingForYou, "要不要合併").
    public static func split(_ status: String) -> (SummaryState, String) {
        let text = status.trimmingCharacters(in: .whitespaces)
        for state in Self.allCases {
            for word in words[state] ?? [] where text.lowercased().hasPrefix(word.lowercased()) {
                let rest = text.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                guard let mark = rest.first, ":：-—".contains(mark) else { continue }
                return (state, rest.dropFirst().trimmingCharacters(in: .whitespaces))
            }
        }
        return (.unknown, text)
    }
}
