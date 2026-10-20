import Foundation

/// A process on a terminal tab's tty, as the system lists it.
public struct TTYProcess: Equatable, Sendable {
    public var pid: Int32
    public var processGroup: Int32
    public var startedAt: Date
    public var name: String

    public init(pid: Int32, processGroup: Int32, startedAt: Date, name: String) {
        self.pid = pid
        self.processGroup = processGroup
        self.startedAt = startedAt
        self.name = name
    }
}

/// What Claude Code writes to `~/.claude/sessions/<pid>.json` while it runs (spike 06). It removes the file
/// when it quits normally; one left behind by a crash names a process that is gone or another one now.
public struct ClaudeCodeSessionRecord: Equatable, Sendable {
    public var pid: Int32
    /// Changes in place on `/clear` or `/resume`; the same again when the session is resumed later.
    public var sessionID: String
    public var startedAt: Date
    /// "cli" in a terminal, "claude-desktop" for the Claude app's own Code sessions.
    public var entrypoint: String?
    public var name: String?

    public init(pid: Int32, sessionID: String, startedAt: Date, entrypoint: String?, name: String?) {
        self.pid = pid
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.entrypoint = entrypoint
        self.name = name
    }

    public init(json: Data) throws {
        struct File: Decodable {
            var pid: Int32
            var sessionId: String
            /// Milliseconds since 1970.
            var startedAt: Double
            var entrypoint: String?
            var name: String?
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        self.init(pid: file.pid, sessionID: file.sessionId, startedAt: Date(timeIntervalSince1970: file.startedAt / 1000),
                  entrypoint: file.entrypoint, name: file.name)
    }
}

/// Tells which Claude Code conversation a terminal tab shows. Never guesses: anything unclear is nil, and
/// notes stay on the window.
public enum ClaudeCodeTerminal {
    public static func page(foregroundGroup: Int32, processes: [TTYProcess],
                            records: [ClaudeCodeSessionRecord]) -> ClaudePage? {
        let candidates = processes.filter { $0.processGroup == foregroundGroup }.compactMap { process in
            records.first { $0.pid == process.pid && belongs($0, to: process) }
        }
        guard candidates.count == 1, let record = candidates.first else { return nil }
        return .conversation(ConversationRef(kind: .cli, id: record.sessionID), title: record.name ?? "")
    }

    /// Clocks are read to the second, and Claude Code writes the file a moment after it starts.
    static let clockSlack: TimeInterval = 2

    /// The file was written by this very process, from the terminal, about a session ID that can be told.
    private static func belongs(_ record: ClaudeCodeSessionRecord, to process: TTYProcess) -> Bool {
        // A process started after the file was written only reuses a crashed run's PID.
        record.entrypoint == "cli" && process.startedAt <= record.startedAt.addingTimeInterval(clockSlack)
            && UUID(uuidString: record.sessionID) != nil
    }
}
