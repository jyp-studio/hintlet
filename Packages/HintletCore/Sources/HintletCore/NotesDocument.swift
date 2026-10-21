import CoreGraphics
import Foundation

/// Everything Hintlet keeps between runs, as written to disk. The engine hands one out and takes one in;
/// what is inside stays the core's business.
public struct NotesDocument: Codable, Equatable, Sendable {
    /// Bump with a migration in `NoteStore.migrations` whenever the shape below changes, so an older
    /// Hintlet sets a newer file aside instead of misreading it.
    /// 2: notes bound to a folder or file (`StoredBinding.document`).
    /// 3: notes bound to a Claude conversation (`StoredBinding.conversation`).
    /// 4: notes bound to a web page (`StoredBinding.webPage`).
    /// 5: conversations of Claude Code in a terminal (`ConversationKind.cli`).
    /// 6: AI notes (`StoredNote.ai`).
    /// 7: conversations in the Codex app (`ConversationKind.codex`).
    public static let currentVersion = 7

    var formatVersion = NotesDocument.currentVersion
    var notes: [StoredNote]

    /// Including those in the trash.
    public var noteCount: Int { notes.count }
}

struct StoredNote: Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var binding: StoredBinding
    /// Optional, so files written before notes had colours or could collapse still read.
    /// Kept as text: a colour from a newer Hintlet reads as yellow instead of making the file unreadable.
    var color: String?
    var isCollapsed: Bool?
    /// Set while the note is in the trash.
    var deletedAt: Date?
    /// The user turned down "might it be here?" for it; written only when true.
    var declinedSuggestions: Bool? = nil
    /// Set for an AI note: its last summary, if it has had one.
    var ai: StoredAINote? = nil
}

struct StoredAINote: Codable, Equatable, Sendable {
    var summary: AISummary?
    /// What the user had written before the note became an AI note.
    var keptText: String? = nil
}

enum StoredBinding: Codable, Equatable, Sendable {
    /// `frame` in AppKit global coordinates.
    case floating(frame: CGRect)
    /// A window's identity doesn't outlive a run, so a window note always loads waiting to be found;
    /// `unmatchedReason` keeps why it was already waiting when saved.
    case window(fingerprint: WindowFingerprint, anchor: WindowAnchor, unmatchedReason: UnmatchedReason?)
    /// A path is the same place across runs, so these notes come back by themselves.
    case document(path: String, anchor: WindowAnchor)
    /// A conversation ID is the same across runs too. `title` is the last one seen, for the list.
    case conversation(ref: ConversationRef, title: String, anchor: WindowAnchor)
    /// A normalized web address is the same page across runs too. `title` is the last one seen.
    case webPage(address: String, title: String, anchor: WindowAnchor)
}

/// What is remembered about a note's window, only ever used to suggest "might it be here?", never to
/// bind a note by itself: titles repeat and change, and frames move.
struct WindowFingerprint: Codable, Equatable, Sendable {
    var bundleID: String?
    var appName: String
    var title: String
    var frame: CGRect
    /// The note went to the window only because the page couldn't be told; the label says so.
    /// Optional so files written before it existed still read.
    var isFallback: Bool?
    /// The window itself, while its app keeps running: found again at once when Hintlet restarts.
    var serverKey: ServerWindowKey?

    init(_ window: ObservedWindow) {
        bundleID = window.bundleID
        appName = window.appName
        // A private browser window's title is its page's: kept out of the file, like its address.
        title = window.browserPage == .privateWindow ? "" : window.title
        frame = window.frame
        serverKey = window.serverKey
    }
}

/// Why a note is waiting to be found again.
public enum UnmatchedReason: String, Codable, Sendable {
    /// Hintlet or the window's app restarted, and a window can't be recognised across runs.
    case relaunched
    /// The window was closed (or its app quit) while Hintlet was running.
    case windowClosed
    /// The folder or file it belongs to isn't there any more (renamed, moved or deleted).
    case documentMissing
}
