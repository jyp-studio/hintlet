import Foundation

/// What the central list shows: every note, grouped by app and context, the notes waiting to be found
/// again, and the trash.
public struct NoteList: Equatable, Sendable {
    /// Notes bound to something (or floating), the group with the most recently changed note first.
    public var groups: [NoteListGroup]
    /// Notes waiting to be found again, most recently changed first.
    public var waiting: [ListedNote]
    /// Notes in the trash, most recently deleted first.
    public var trash: [ListedNote]

    public var isEmpty: Bool { groups.isEmpty && waiting.isEmpty && trash.isEmpty }
    public static let empty = NoteList(groups: [], waiting: [], trash: [])
}

/// Which app a group of notes belongs to in the list.
public enum ListedApp: Hashable, Sendable {
    case app(String)
    /// Notes on a folder or file, which any app's window showing it brings back.
    case documents
    /// Notes on a web page, which any browser tab showing it brings back.
    case webPages
    /// Claude Code sessions in Terminal or iTerm.
    case claudeCodeTerminal
    case floating
}

/// The notes on one context: a conversation, a window, a folder or file, or floating.
public struct NoteListGroup: Equatable, Sendable {
    public let app: ListedApp
    /// What the notes say they are bound to, as on the notes themselves.
    public let context: ScopeLabel
    /// For a Claude conversation: which one (to go to it).
    public let conversation: ConversationRef?
    /// The conversation was archived in Claude; its notes stay bound to it.
    public let isArchived: Bool
    /// Most recently changed first.
    public let notes: [ListedNote]
}

public struct ListedNote: Equatable, Sendable {
    public let id: NoteID
    public let text: String
    public let color: NoteColor
    public let updatedAt: Date
    /// What it is (or was) bound to.
    public let context: ScopeLabel
    /// Set for a note waiting to be found again.
    public let waitingReason: UnmatchedReason?
    /// Set for a note in the trash.
    public let deletedAt: Date?
    /// Set for an AI note: its summary's lines (none yet before the first one).
    public let aiLines: [String]?
}

extension ConversationRef {
    /// Opens the conversation in the Claude app (spike 04). A deleted one lands on a new conversation.
    /// nil for Claude Code in a terminal, which Claude can't open.
    public var deepLink: URL? {
        let path: String
        switch kind {
        case .chat: path = "chat"
        case .cowork: path = "cowork"
        case .code: path = "epitaxy"
        case .cli: return nil
        }
        return URL(string: "claude://claude.ai/\(path)/\(id)")
    }
}

extension ScopeLabel {
    /// The context's own name, which a search finds a note by too.
    var searchableName: String {
        switch self {
        case .floating: ""
        case .window(let appName, let title), .windowFallback(let appName, let title), .webPageFallback(let appName, let title):
            appName + " " + title
        case .webPage(let title, let address): title + " " + address
        case .document(_, let name, _): name
        case .conversation(let title): title
        }
    }
}
