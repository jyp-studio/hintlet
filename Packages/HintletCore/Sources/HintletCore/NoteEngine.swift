import CoreGraphics
import Foundation

public typealias NoteID = UUID

/// What the overlay layer should draw right now.
public struct DisplayedNote: Equatable, Sendable {
    public let id: NoteID
    public let frame: CGRect
    public let text: String
    public let scopeLabel: ScopeLabel
    /// The window the note is bound to; nil for a floating note.
    public let windowID: WindowID?
    public let color: NoteColor
    /// Shown as a small tag at the note's top-left corner instead of the whole note.
    public let isCollapsed: Bool
    /// Set for an AI note: its summary (nil until the first one) and whether one is being written.
    public let ai: DisplayedAI?
    /// A note just placed on a conversation that can still get its AI note, not typed in yet:
    /// "✨ 讓 AI 記錄脈絡？".
    public let offersAI: Bool
    /// An empty note the menu can turn into the conversation's AI note ("轉成 AI 便利貼"), new or not.
    public let canBecomeAI: Bool
    /// An AI note whose text just changed: the overlay measures it and hands the height back
    /// (`NoteEngine.fitHeight(of:to:)`), so the whole summary shows without scrolling.
    public let fitsTextHeight: Bool

    public init(id: NoteID, frame: CGRect, text: String, scopeLabel: ScopeLabel, windowID: WindowID? = nil,
                color: NoteColor = .yellow, isCollapsed: Bool = false, ai: DisplayedAI? = nil, offersAI: Bool = false,
                canBecomeAI: Bool = false, fitsTextHeight: Bool = false) {
        self.id = id
        self.frame = frame
        self.text = text
        self.scopeLabel = scopeLabel
        self.windowID = windowID
        self.color = color
        self.isCollapsed = isCollapsed
        self.ai = ai
        self.offersAI = offersAI
        self.canBecomeAI = canBecomeAI
        self.fitsTextHeight = fitsTextHeight
    }
}

/// A note's colour: the paper colours a handwritten note can have, and the ones only AI notes come in
/// (pastel mist, sunset and frosted glass).
public enum NoteColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple, mist, sunset, glow

    /// What an ordinary note can be.
    public static let paperColors: [NoteColor] = [.yellow, .green, .blue, .pink, .purple]
    /// What AI notes can be: none of the ordinary colours, so an AI note always looks like one, and a note
    /// turning into one changes how it looks.
    public static let aiColors: [NoteColor] = [.mist, .sunset, .glow]
}

/// A display: `frame` is the whole screen, `visibleFrame` excludes the menu bar and Dock.
public struct Screen: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// Where a note may be put: anywhere on the display, over the Dock too, but not over the menu bar.
    var placeableFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visibleFrame.maxY - frame.minY)
    }
}

/// A note waiting to be found again: its window couldn't be recognised any more.
public struct UnmatchedNote: Equatable, Sendable {
    public let id: NoteID
    public let text: String
    public let reason: UnmatchedReason
    /// The window it was last on, for the user to recognise.
    public let appName: String
    public let title: String

    public init(id: NoteID, text: String, reason: UnmatchedReason, appName: String, title: String) {
        self.id = id
        self.text = text
        self.reason = reason
        self.appName = appName
        self.title = title
    }
}

/// A note in the trash.
public struct TrashedNote: Equatable, Sendable {
    public let id: NoteID
    public let text: String
    public let deletedAt: Date
}

/// "Might it be here?": a waiting note that may belong to the focused window. Only the user's
/// confirmation binds it again.
public struct RecoveryCandidate: Equatable, Sendable {
    public let noteID: NoteID
    public let windowID: WindowID
    /// The note's first line.
    public let preview: String
    /// Where the note would go on this window once confirmed.
    public let noteFrame: CGRect

    public init(noteID: NoteID, windowID: WindowID, preview: String, noteFrame: CGRect) {
        self.noteID = noteID
        self.windowID = windowID
        self.preview = preview
        self.noteFrame = noteFrame
    }
}

/// What importing a backup did.
public struct ImportSummary: Equatable, Sendable {
    public var added: Int
    /// Notes that were here already and came in newer.
    public var updated: Int

    public init(added: Int, updated: Int) {
        self.added = added
        self.updated = updated
    }
}

/// The core of Hintlet: takes user commands and observations, and decides which notes to display.
/// Coordinates are AppKit global coordinates (origin at the bottom-left of the primary screen).
public final class NoteEngine {
    public static let defaultNoteSize = CGSize(width: 240, height: 180)
    /// Small enough to tuck away, big enough to still read a few words.
    public static let minimumNoteSize = CGSize(width: 160, height: 100)
    /// Where a note goes when the cursor is outside the window: clear of the title bar, near the right edge.
    static let topRightInset = CGSize(width: 16, height: 40)
    /// How far each further note at the default spot is nudged down and to the left.
    static let staggerStep: CGFloat = 24
    /// How long a deleted note stays in the trash before it is gone for good.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    private enum Placement {
        case floating(CGRect)
        case window(WindowFingerprint, WindowAnchor, WindowState)
        /// On whichever window shows this file or folder.
        case document(path: String, WindowAnchor)
        /// On the Claude window while it shows this conversation. `title` is the last one seen.
        case conversation(ConversationRef, title: String, WindowAnchor)
        /// On whichever window shows this web page (a normalized address). `title` is the last one seen.
        case webPage(address: String, title: String, WindowAnchor)
    }

    private enum WindowState: Equatable {
        case matched(WindowID)
        case unmatched(UnmatchedReason)
    }

    private struct Note {
        let id: NoteID
        var placement: Placement
        var text: String
        let createdAt: Date
        var updatedAt: Date
        var color: NoteColor = .yellow
        var isCollapsed = false
        /// Set while the note is in the trash.
        var deletedAt: Date?
        /// The user said "not here" to "might it be here?": windows like its old one aren't suggested again,
        /// and it waits in the list until it is bound again.
        var declinedSuggestions = false
        /// Set for an AI note, which only the summary service writes.
        var ai: AINoteState?
    }

    private struct AINoteState: Equatable {
        var summary: AISummary?
        /// What the user had written before the note became an AI note; it comes back with it.
        var keptText: String?
    }

    private var screens: [Screen]
    private var notes: [Note] = []
    /// The window the user is working in, or nil when it cannot be identified.
    private var focusedWindow: ObservedWindow?
    private let now: () -> Date
    /// Whether a folder or file is still there; a note whose place is gone waits to be found again.
    private let pathExists: (String) -> Bool

    /// `document` is what was saved last run; its window notes wait to be found again.
    public init(screens: [Screen], document: NotesDocument? = nil, now: @escaping () -> Date = Date.init,
                pathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.screens = screens
        self.now = now
        self.pathExists = pathExists
        notes = document?.notes.map(note(from:)) ?? []
        purgeExpiredTrash()
    }

    /// A saved or imported note as this run knows it: its window waits to be found again.
    private func note(from stored: StoredNote) -> Note {
        let placement: Placement = switch stored.binding {
        // The display it was on may be gone.
        case .floating(let frame): .floating(keptOnScreen(frame))
        case .window(let fingerprint, let anchor, let reason): .window(fingerprint, anchor, .unmatched(reason ?? .relaunched))
        case .document(let path, let anchor): .document(path: path, anchor)
        case .conversation(let ref, let title, let anchor): .conversation(ref, title: title, anchor)
        case .webPage(let address, let title, let anchor): .webPage(address: address, title: title, anchor)
        }
        return Note(id: stored.id, placement: placement, text: stored.text,
                    createdAt: stored.createdAt, updatedAt: stored.updatedAt,
                    color: stored.color.flatMap(NoteColor.init(rawValue:)) ?? .yellow, isCollapsed: stored.isCollapsed ?? false,
                    deletedAt: stored.deletedAt, declinedSuggestions: stored.declinedSuggestions ?? false,
                    ai: stored.ai.map { AINoteState(summary: $0.summary, keptText: $0.keptText) })
    }

    /// Takes in the notes of a backup file. A note that isn't here yet is added; one that is here already
    /// is replaced only by a newer version of itself, so importing the same backup twice changes nothing.
    @discardableResult
    public func importNotes(_ document: NotesDocument) -> ImportSummary {
        var summary = ImportSummary(added: 0, updated: 0)
        for stored in document.notes {
            if let index = notes.firstIndex(where: { $0.id == stored.id }) {
                guard stored.updatedAt > notes[index].updatedAt else { continue }
                notes[index] = note(from: stored)
                summary.updated += 1
            } else {
                notes.append(note(from: stored))
                summary.added += 1
            }
            keepOneAINote(stored.id)
        }
        // A backup may hold notes that have been in the trash long enough to go.
        purgeExpiredTrash()
        return summary
    }

    /// Everything to save. A note matched to a window is saved without the window's identity, which
    /// doesn't outlive the run.
    public var document: NotesDocument {
        NotesDocument(notes: notes.map { note in
            let binding: StoredBinding = switch note.placement {
            case .floating(let frame): .floating(frame: frame)
            case .window(let fingerprint, let anchor, .matched):
                .window(fingerprint: fingerprint, anchor: anchor, unmatchedReason: nil)
            case .window(let fingerprint, let anchor, .unmatched(let reason)):
                .window(fingerprint: fingerprint, anchor: anchor, unmatchedReason: reason)
            case .document(let path, let anchor): .document(path: path, anchor: anchor)
            case .conversation(let ref, let title, let anchor): .conversation(ref: ref, title: title, anchor: anchor)
            case .webPage(let address, let title, let anchor): .webPage(address: address, title: title, anchor: anchor)
            }
            return StoredNote(id: note.id, text: note.text, createdAt: note.createdAt, updatedAt: note.updatedAt,
                              binding: binding, color: note.color.rawValue, isCollapsed: note.isCollapsed,
                              deletedAt: note.deletedAt, declinedSuggestions: note.declinedSuggestions ? true : nil,
                              ai: note.ai.map { StoredAINote(summary: $0.summary, keptText: $0.keptText) })
        })
    }

    /// Refreshed whenever the display arrangement may have changed.
    public func updateScreens(_ screens: [Screen]) {
        self.screens = screens
    }

    /// Takes in what the user is focused on now. Notes that no longer certainly match are hidden at once.
    public func observe(_ observation: ContextObservation) {
        if observation != .ownApp { leaving(for: observation) }
        switch observation {
        case .window(let window):
            focusedWindow = window
            findAgainAfterRelaunch(window)
            rememberDetails(of: window)
        case .unidentified: focusedWindow = nil
        case .ownApp: break
        }
    }

    /// The windows closed (or their app quit): their notes wait to be found again.
    public func windowsClosed(_ ids: [WindowID]) {
        let closed = Set(ids)
        for index in notes.indices {
            guard case .window(let fingerprint, let anchor, .matched(let id)) = notes[index].placement,
                  closed.contains(id) else { continue }
            notes[index].placement = .window(fingerprint, anchor, .unmatched(.windowClosed))
        }
        if let focused = focusedWindow, closed.contains(focused.id) { focusedWindow = nil }
    }

    /// "Hide all" from the menu bar, e.g. while sharing the screen: nothing shows, floating notes included,
    /// until it is turned off or a new note is made. Lasts only for the run; it isn't saved.
    public var hidesAll = false

    /// The kinds of conversation AI notes are offered on; empty where the system has no model, which
    /// hides AI notes' offer altogether. Not saved: the app sets it each run.
    public var aiConversationKinds: Set<ConversationKind> = []
    /// The colour every AI note shows in, from the settings; changing it recolours them all at once.
    /// Not saved in the notes file: the app sets it each run.
    public var aiNoteColor: NoteColor = .mist
    /// The size and colour new notes are made with, from the settings. Not saved: the app sets it each run.
    public var newNoteSize = NoteEngine.defaultNoteSize
    public var newNoteColor: NoteColor = .yellow
    /// What the summary service has been asked to do, oldest first; one request per note.
    private var summaryRequests: [SummaryRequest] = []
    /// AI notes whose summary is being written or failed last time; not saved.
    private var aiStatus: [NoteID: AIStatus] = [:]
    /// Notes made this run, which offer to become AI notes while they are empty; not saved.
    private var justPlaced: Set<NoteID> = []
    /// AI notes whose text changed since their height last fitted it; not saved. A height the user drags
    /// the note to stays until the summary changes again.
    private var heightsToFit: Set<NoteID> = []
    /// An AI note grows to fit its text up to this share of its screen's visible height, then scrolls.
    public static let fittedHeightShare: CGFloat = 0.6

    /// Notes the user hid on one window for a while ("隱藏這個視窗的便利貼"); they come back when asked, or
    /// when a new note is made there. Lasts only for the run; it isn't saved.
    private var hiddenNotes: Set<NoteID> = []

    /// The notes on the focused window (or its page, document or conversation), hidden ones included;
    /// floating notes aren't on any window.
    public var notesOnFocusedWindow: [NoteID] {
        guard let window = focusedWindow else { return [] }
        return notes.filter { $0.deletedAt == nil && displayed($0)?.windowID == window.id }.map(\.id)
    }

    /// Whether the focused window has notes and all of them are hidden.
    public var hidesFocusedWindowNotes: Bool {
        let ids = notesOnFocusedWindow
        return !ids.isEmpty && hiddenNotes.isSuperset(of: ids)
    }

    /// Whether some window's notes are hidden right now.
    public var hidesSomeNotes: Bool {
        notes.contains { $0.deletedAt == nil && hiddenNotes.contains($0.id) }
    }

    public func setFocusedWindowNotesHidden(_ hidden: Bool) {
        let ids = notesOnFocusedWindow
        if hidden { hiddenNotes.formUnion(ids) } else { hiddenNotes.subtract(ids) }
    }

    /// Puts these notes in the trash at once, e.g. all of one window's.
    public func deleteNotes(_ ids: [NoteID]) {
        ids.forEach(deleteNote)
    }

    public var displayedNotes: [DisplayedNote] {
        guard !hidesAll else { return [] }
        return notes.filter { $0.deletedAt == nil && !hiddenNotes.contains($0.id) }.compactMap { note in
            displayed(note).map {
                DisplayedNote(id: $0.id, frame: $0.frame, text: $0.text, scopeLabel: $0.scopeLabel, windowID: $0.windowID,
                              color: shownColor(of: note), isCollapsed: note.isCollapsed,
                              ai: note.ai.map { DisplayedAI(summary: $0.summary, status: aiStatus[note.id] ?? .idle) },
                              offersAI: justPlaced.contains(note.id) && note.text.allSatisfy(\.isWhitespace) && canMakeAINote(note.id),
                              canBecomeAI: canMakeAINote(note.id),
                              fitsTextHeight: heightsToFit.contains(note.id))
            }
        }
    }

    /// AI notes show in the colour the settings give them, whatever they were saved with.
    private func shownColor(of note: Note) -> NoteColor {
        note.ai != nil ? aiNoteColor : note.color
    }

    /// Where and how the note shows right now, if it does.
    private func displayed(_ note: Note) -> DisplayedNote? {
        switch note.placement {
        case .floating(let frame):
            return DisplayedNote(id: note.id, frame: frame, text: note.text, scopeLabel: .floating)
        case .window(let fingerprint, let anchor, .matched(let id)):
            guard let window = visibleWindow(id) else { return nil }
            let label: ScopeLabel = switch fingerprint.isFallback == true {
            case false: .window(appName: window.appName, title: window.title)
            case true where window.browserPage != nil: .webPageFallback(appName: window.appName, title: window.title)
            case true: .windowFallback(appName: window.appName, title: window.title)
            }
            return DisplayedNote(id: note.id, frame: keptOnScreen(anchor.frame(in: window.frame)), text: note.text,
                                 scopeLabel: label, windowID: id)
        case .window(_, _, .unmatched):
            return nil
        case .document(let path, let anchor):
            guard let window = visibleWindow(showing: path) else { return nil }
            return DisplayedNote(id: note.id, frame: keptOnScreen(anchor.frame(in: window.frame)), text: note.text,
                                 scopeLabel: Self.documentLabel(path: path, appName: window.appName),
                                 windowID: window.id)
        case .conversation(let ref, _, let anchor):
            guard let (window, title) = visibleWindow(showing: ref) else { return nil }
            return DisplayedNote(id: note.id, frame: keptOnScreen(anchor.frame(in: window.frame)), text: note.text,
                                 scopeLabel: .conversation(title: title), windowID: window.id)
        case .webPage(let address, _, let anchor):
            guard let (window, title) = visibleWindow(showingPage: address) else { return nil }
            return DisplayedNote(id: note.id, frame: keptOnScreen(anchor.frame(in: window.frame)), text: note.text,
                                 scopeLabel: .webPage(title: title, address: address), windowID: window.id)
        }
    }

    private static func documentLabel(path: String, appName: String) -> ScopeLabel {
        .document(appName: appName, name: URL(fileURLWithPath: path).lastPathComponent, isFolder: path.hasSuffix("/"))
    }

    /// Notes in the trash, kept so they can be restored.
    public var trashedNotes: [TrashedNote] {
        notes.compactMap { note in
            note.deletedAt.map { TrashedNote(id: note.id, text: note.text, deletedAt: $0) }
        }
    }

    /// Puts the note in the trash; it disappears but can be restored.
    public func deleteNote(_ id: NoteID) {
        update(id) { $0.deletedAt = now() }
    }

    /// Notes in the trash for `trashRetention` or longer are gone for good. Done on launch; the app also
    /// calls it now and then while running.
    public func purgeExpiredTrash() {
        let cutoff = now().addingTimeInterval(-Self.trashRetention)
        notes.removeAll { note in note.deletedAt.map { $0 <= cutoff } ?? false }
    }

    /// Removes a note in the trash for good. A note outside the trash is left alone.
    public func deleteForever(_ id: NoteID) {
        notes.removeAll { $0.id == id && $0.deletedAt != nil }
    }

    /// Removes every note in the trash for good.
    public func emptyTrash() {
        notes.removeAll { $0.deletedAt != nil }
    }

    /// The Cowork and Code sessions notes are on, whose local session files the app checks are still there.
    /// Chat keeps no local file, so its deletion can't be told and its notes are never moved away; nor are
    /// those of Claude Code in a terminal, whose session ending is not a deletion.
    public var sessionsToWatch: Set<ConversationRef> {
        Set(notes.compactMap { note in
            guard note.deletedAt == nil, case .conversation(let ref, _, _) = note.placement, [.cowork, .code].contains(ref.kind) else { return nil }
            return ref
        })
    }

    /// These sessions were deleted in Claude: their notes go to the trash. Chat conversations are ignored.
    public func sessionsDeleted(_ refs: Set<ConversationRef>) {
        let deleted = now()
        for index in notes.indices where notes[index].deletedAt == nil {
            guard case .conversation(let ref, _, _) = notes[index].placement, ref.kind != .chat, refs.contains(ref) else { continue }
            notes[index].deletedAt = deleted
        }
    }

    /// Takes the note out of the trash, back where it was.
    public func restoreNote(_ id: NoteID) {
        update(id) { $0.deletedAt = nil }
        keepOneAINote(id)
    }

    /// A conversation keeps one AI note: one coming (back) to a conversation that has another meanwhile,
    /// from the trash or a backup, goes back to being an ordinary note, with what it last said.
    private func keepOneAINote(_ id: NoteID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].ai != nil, notes[index].deletedAt == nil,
              let ref = Self.conversation(of: notes[index].placement), aiNote(on: ref, excluding: id) != nil else { return }
        notes[index].ai = nil
    }

    /// Notes waiting to be found again. They are kept until the user deals with them.
    public var unmatchedNotes: [UnmatchedNote] {
        notes.filter { $0.deletedAt == nil }.compactMap { note in
            switch note.placement {
            case .window(let fingerprint, _, .unmatched(let reason)):
                return UnmatchedNote(id: note.id, text: note.text, reason: reason,
                                     appName: fingerprint.appName, title: fingerprint.title)
            case .document(let path, _) where !pathExists(path):
                return UnmatchedNote(id: note.id, text: note.text, reason: .documentMissing,
                                     appName: "", title: URL(fileURLWithPath: path).lastPathComponent)
            default:
                return nil
            }
        }
    }

    /// Waiting notes that may belong to the focused window: same app and exactly the same (non-empty) title. Any other
    /// window would be a guess, and stays quiet; those notes are found again from the list. The window that
    /// was nearest to where this one is comes first.
    public var recoveryCandidates: [RecoveryCandidate] {
        // An untitled window says nothing about which one it is.
        guard !hidesAll, let window = focusedWindow, !window.isMinimized, let bundleID = window.bundleID,
              !window.title.isEmpty else { return [] }
        let candidates = notes.compactMap { note -> (candidate: RecoveryCandidate, distance: CGFloat)? in
            guard note.deletedAt == nil, case .window(let fingerprint, let anchor, .unmatched) = note.placement,
                  fingerprint.bundleID == bundleID, fingerprint.title == window.title,
                  !note.declinedSuggestions else { return nil }
            let distance = hypot(fingerprint.frame.midX - window.frame.midX, fingerprint.frame.midY - window.frame.midY)
            let candidate = RecoveryCandidate(noteID: note.id, windowID: window.id, preview: Self.firstLine(of: note.text),
                                              noteFrame: keptOnScreen(anchor.frame(in: window.frame)))
            return (candidate, distance)
        }
        // Sorting is stable, so equally near ones keep the order the notes were made in.
        return candidates.sorted { $0.distance < $1.distance }.map(\.candidate)
    }

    /// The user confirmed the note belongs on the window it was suggested for: it comes back where it was
    /// on it. Nothing happens if that window is no longer the focused one.
    public func confirmRecovery(of id: NoteID, on windowID: WindowID) {
        guard let window = focusedWindow, window.id == windowID else { return }
        update(id) { note in
            guard case .window(_, let anchor, .unmatched) = note.placement else { return }
            // A window note stays a window note on Claude; elsewhere it goes to the folder the window shows.
            note.placement = placement(on: window, anchor: anchor, scope: window.claudePage == nil ? .automatic : .window)
            note.declinedSuggestions = false
            note.updatedAt = now()
        }
    }

    /// The user said the note doesn't belong on that window. Titles like Safari's "Start Page" are shared by many
    /// windows, so the note isn't suggested again, also after a relaunch; it waits in the list.
    public func dismissRecovery(of id: NoteID, on windowID: WindowID) {
        guard let window = focusedWindow, window.id == windowID else { return }
        update(id) { $0.declinedSuggestions = true }
    }

    /// The window the user is working in, if it can be identified.
    public var focusedWindowID: WindowID? { focusedWindow?.id }

    /// Why a note can't be made here right now, if it can't (the app explains and offers the window instead).
    public var creationBlock: CreationBlock? {
        switch focusedWindow?.claudePage {
        case .draft: .draftConversation
        case .settings: .claudeSettings
        default: focusedWindow?.browserPage == .newTab ? .newBrowserTab : nil
        }
    }

    /// A new note would go to the window only because the page can't be told (e.g. Claude's projects page,
    /// a browser's settings); the app says so, so nobody mistakes it for a conversation or web page note.
    public var creationFallsBack: Bool {
        guard let window = focusedWindow else { return false }
        return Self.finestScope(on: window) == .window
            && (window.claudePage == .unrecognized || window.browserPage == .unrecognized)
    }

    /// Creates an empty note on the focused window, or a floating note when there is none.
    /// The note's top-left corner sits at `cursor` when the cursor is over the window.
    @discardableResult
    public func createNote(at cursor: CGPoint, scope: NoteScope = .automatic) -> NoteID {
        // Asking for a new note means the user wants to see notes again.
        hidesAll = false
        hiddenNotes.subtract(notesOnFocusedWindow)
        let size = newNoteSize
        let placement: Placement
        if let window = focusedWindow, !window.isMinimized {
            let frame = window.frame.contains(cursor)
                ? CGRect(x: cursor.x, y: cursor.y - size.height, width: size.width, height: size.height)
                    .clamped(into: window.frame)
                : freeTopRightSpot(in: window, size: size)
            placement = self.placement(on: window, anchor: WindowAnchor(frame: frame, in: window.frame), scope: scope)
        } else {
            let proposed = CGRect(x: cursor.x, y: cursor.y - size.height, width: size.width, height: size.height)
            placement = .floating(screen(containing: cursor).map { proposed.clamped(into: $0.visibleFrame) } ?? proposed)
        }
        let created = now()
        let note = Note(id: UUID(), placement: placement, text: "", createdAt: created, updatedAt: created, color: newNoteColor)
        notes.append(note)
        justPlaced.insert(note.id)
        return note.id
    }

    public func editText(of id: NoteID, to text: String) {
        update(id) { note in
            // An AI note is read-only.
            guard note.ai == nil, note.text != text else { return }
            note.text = text
            note.updatedAt = now()
        }
    }

    /// When the user stops editing: a note left empty was never really written, so it goes. Returns
    /// whether it was removed.
    @discardableResult
    public func discardIfEmpty(_ id: NoteID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].deletedAt == nil, notes[index].ai == nil,
              notes[index].text.allSatisfy(\.isWhitespace) else { return false }
        notes.remove(at: index)
        return true
    }

    /// Moves the note so its bottom-left corner is at `origin` (the overlay reports where the user dropped it).
    public func moveNote(_ id: NoteID, to origin: CGPoint) {
        reshape(id) { frame in frame.origin = origin }
    }

    /// Resizes the note from its bottom-right corner: the top-left corner stays where it is.
    public func resizeNote(_ id: NoteID, to size: CGSize) {
        heightsToFit.remove(id)
        let fitting = CGSize(width: max(size.width, Self.minimumNoteSize.width),
                             height: max(size.height, Self.minimumNoteSize.height))
        reshape(id) { frame in
            frame = CGRect(x: frame.minX, y: frame.maxY - fitting.height, width: fitting.width, height: fitting.height)
        }
    }

    /// Puts the note at `frame`, as when it is resized from one of its edges. A frame smaller than the
    /// minimum keeps its origin and grows to the minimum size (the overlay keeps the dragged edge in place).
    public func setFrame(of id: NoteID, to frame: CGRect) {
        heightsToFit.remove(id)
        let fitting = CGSize(width: max(frame.width, Self.minimumNoteSize.width),
                             height: max(frame.height, Self.minimumNoteSize.height))
        reshape(id) { current in current = CGRect(origin: frame.origin, size: fitting) }
    }

    /// The AI note takes the height its text needs (`DisplayedNote.fitsTextHeight`), keeping its top edge and
    /// width: no shorter than the minimum, no taller than `fittedHeightShare` of its screen. Once per change of
    /// its text; afterwards the height is the user's again.
    public func fitHeight(of id: NoteID, to height: CGFloat) {
        guard heightsToFit.remove(id) != nil, let note = notes.first(where: { $0.id == id }), note.ai != nil,
              let frame = displayed(note)?.frame else { return }
        let screen = screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.maxY)) }
            ?? screen(containing: CGPoint(x: frame.midX, y: frame.midY))
        let cap = screen.map { max($0.visibleFrame.height * Self.fittedHeightShare, Self.minimumNoteSize.height) } ?? .infinity
        let fitted = min(max(height.rounded(.up), Self.minimumNoteSize.height), cap)
        guard fitted != frame.height else { return }
        reshape(id) { frame in
            frame = CGRect(x: frame.minX, y: frame.maxY - fitted, width: frame.width, height: fitted)
        }
    }

    public func setColor(of id: NoteID, to color: NoteColor) {
        update(id) { note in
            // AI notes all share one colour, and theirs are their own.
            guard note.ai == nil, note.color != color, NoteColor.paperColors.contains(color) else { return }
            note.color = color
            note.updatedAt = now()
        }
    }

    public func setCollapsed(_ id: NoteID, _ collapsed: Bool) {
        update(id) { note in
            guard note.isCollapsed != collapsed else { return }
            note.isCollapsed = collapsed
            note.updatedAt = now()
        }
    }

    /// What the note's scope menu offers while it shows: what the focused window can be told to show (a
    /// conversation, a file or folder, the window itself), and floating. A note not showing offers nothing.
    public func scopeOptions(for id: NoteID) -> [ScopeOption] {
        guard let note = notes.first(where: { $0.id == id }), note.deletedAt == nil,
              let shown = displayed(note) else { return [] }
        let current = Self.scope(of: note.placement)
        // An AI note belongs to its conversation.
        if note.ai != nil { return [ScopeOption(scope: current, label: shown.scopeLabel, isCurrent: true)] }
        var options: [(BindingScope, ScopeLabel)] = []
        if let window = windowToBindTo {
            if case .conversation(_, let title) = window.claudePage { options.append((.conversation, .conversation(title: title))) }
            if let path = window.documentPath { options.append((.document, Self.documentLabel(path: path, appName: window.appName))) }
            if case .page(let address, let title) = window.browserPage { options.append((.webPage, .webPage(title: title, address: address))) }
            options.append((.window, .window(appName: window.appName, title: window.title)))
        }
        options.append((.floating, .floating))
        // The current one says what the note says now (e.g. that it fell back to the window).
        return options.map { scope, label in
            ScopeOption(scope: scope, label: scope == current ? shown.scopeLabel : label, isCurrent: scope == current)
        }
    }

    /// Binds the note another way, staying where it is on screen. A floating note well away from the
    /// window goes to the window's free top-right spot. Only a scope the menu offers is taken.
    public func changeScope(of id: NoteID, to scope: BindingScope) {
        guard let option = scopeOptions(for: id).first(where: { $0.scope == scope }), !option.isCurrent,
              let index = notes.firstIndex(where: { $0.id == id }), let shown = displayed(notes[index]) else { return }
        if scope == .floating {
            notes[index].placement = .floating(shown.frame)
        } else if let window = windowToBindTo {
            let frame = spot(for: shown, on: window)
            notes[index].placement = placement(on: window, anchor: WindowAnchor(frame: frame, in: window.frame), binding: scope)
        }
        notes[index].updatedAt = now()
    }

    /// Whether the note can be bound to what the user is working on now: there is a window to bind to, and
    /// the note isn't bound to it as finely as it can be already. Any note, shown or not (waiting to be
    /// found again, on another conversation, floating), outside the trash. Not on a page no note can be made
    /// on (a new Claude conversation, Claude's settings): the window there is only picked from the menu.
    public func canRebindToCurrentContext(_ id: NoteID) -> Bool {
        guard creationBlock == nil, let window = windowToBindTo, let note = notes.first(where: { $0.id == id }), note.deletedAt == nil,
              note.ai == nil else {
            return false
        }
        guard let shown = displayed(note), shown.windowID == window.id else { return true }
        return Self.scope(of: note.placement) != Self.finestScope(on: window)
    }

    /// Binds the note to what the user is working on now, as finely as can be told. A note showing stays
    /// where it is (or, far off the window, goes to its free top-right spot); one that wasn't showing comes
    /// back where it was on its old window, relative to this one.
    public func rebindToCurrentContext(_ id: NoteID) {
        guard canRebindToCurrentContext(id), let window = windowToBindTo,
              let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[index]
        let frame: CGRect
        if let shown = displayed(note) {
            frame = spot(for: shown, on: window)
        } else if let anchor = Self.anchor(of: note.placement) {
            frame = spot(for: keptOnScreen(anchor.frame(in: window.frame)), on: window)
        } else {
            frame = freeTopRightSpot(in: window, size: newNoteSize)
        }
        notes[index].placement = placement(on: window, anchor: WindowAnchor(frame: frame, in: window.frame))
        notes[index].declinedSuggestions = false
        notes[index].updatedAt = now()
    }

    /// The window a note would be bound to now.
    private var windowToBindTo: ObservedWindow? {
        guard let window = focusedWindow, !window.isMinimized else { return nil }
        return window
    }

    /// Where a note at `frame` goes on the window: where it is if it is on it, else the free top-right spot.
    private func spot(for frame: CGRect, on window: ObservedWindow) -> CGRect {
        window.frame.intersects(frame) ? frame : freeTopRightSpot(in: window, size: frame.size)
    }

    /// Where a showing note goes on the window: where it is if it is already showing on it.
    private func spot(for shown: DisplayedNote, on window: ObservedWindow) -> CGRect {
        shown.windowID == window.id ? shown.frame : spot(for: shown.frame, on: window)
    }

    private static func scope(of placement: Placement) -> BindingScope {
        switch placement {
        case .floating: .floating
        case .window: .window
        case .document: .document
        case .conversation: .conversation
        case .webPage: .webPage
        }
    }

    private static func anchor(of placement: Placement) -> WindowAnchor? {
        switch placement {
        case .floating: nil
        case .window(_, let anchor, _), .document(_, let anchor), .conversation(_, _, let anchor), .webPage(_, _, let anchor): anchor
        }
    }

    /// The finest scope the window can be told to show for sure.
    private static func finestScope(on window: ObservedWindow) -> BindingScope {
        if case .conversation = window.claudePage { return .conversation }
        if window.documentPath != nil { return .document }
        if case .page = window.browserPage { return .webPage }
        return .window
    }

    /// Changes where the note is on screen, which is only possible while it shows; a note on a window keeps
    /// its new place relative to that window, hanging off its edge if the user put it there.
    private func reshape(_ id: NoteID, _ change: (inout CGRect) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }), var frame = displayed(notes[index])?.frame else { return }
        change(&frame)
        let note = notes[index]
        switch note.placement {
        case .floating:
            notes[index].placement = .floating(frame)
        case .window(let fingerprint, _, .matched(let windowID)):
            guard let window = visibleWindow(windowID) else { return }
            notes[index].placement = .window(fingerprint, WindowAnchor(frame: keptOnScreen(frame), in: window.frame),
                                             .matched(windowID))
        case .window(_, _, .unmatched):
            return
        case .document(let path, _):
            guard let window = visibleWindow(showing: path) else { return }
            notes[index].placement = .document(path: path, WindowAnchor(frame: keptOnScreen(frame), in: window.frame))
        case .conversation(let ref, let title, _):
            guard let (window, _) = visibleWindow(showing: ref) else { return }
            notes[index].placement = .conversation(ref, title: title, WindowAnchor(frame: keptOnScreen(frame), in: window.frame))
        case .webPage(let address, let title, _):
            guard let (window, _) = visibleWindow(showingPage: address) else { return }
            notes[index].placement = .webPage(address: address, title: title, WindowAnchor(frame: keptOnScreen(frame), in: window.frame))
        }
        notes[index].updatedAt = now()
    }

    /// The finest context the window shows for sure: a Claude conversation, a file or folder, or else the
    /// window itself.
    private func placement(on window: ObservedWindow, anchor: WindowAnchor, scope: NoteScope = .automatic) -> Placement {
        guard scope == .automatic else { return placement(on: window, anchor: anchor, binding: .window) }
        let finest = Self.finestScope(on: window)
        if finest == .window, window.claudePage == .unrecognized || window.browserPage == .unrecognized {
            var fingerprint = WindowFingerprint(window)
            fingerprint.isFallback = true
            return .window(fingerprint, anchor, .matched(window.id))
        }
        return placement(on: window, anchor: anchor, binding: finest)
    }

    /// Bound to the window that way; a scope the window doesn't show (or floating) binds to the window itself.
    private func placement(on window: ObservedWindow, anchor: WindowAnchor, binding: BindingScope) -> Placement {
        switch binding {
        case .conversation:
            if case .conversation(let ref, let title) = window.claudePage { return .conversation(ref, title: title, anchor) }
        case .document:
            if let path = window.documentPath { return .document(path: path, anchor) }
        case .webPage:
            if case .page(let address, let title) = window.browserPage { return .webPage(address: address, title: title, anchor) }
        case .window, .floating:
            break
        }
        return .window(WindowFingerprint(window), anchor, .matched(window.id))
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private func visibleWindow(_ id: WindowID) -> ObservedWindow? {
        guard let window = focusedWindow, window.id == id, !window.isMinimized else { return nil }
        return window
    }

    /// The focused window while it shows the conversation, with the conversation's current title.
    private func visibleWindow(showing ref: ConversationRef) -> (ObservedWindow, String)? {
        guard let window = focusedWindow, !window.isMinimized,
              case .conversation(ref, let title) = window.claudePage else { return nil }
        return (window, title)
    }

    /// The focused window while it shows the web page, with the page's current title.
    private func visibleWindow(showingPage address: String) -> (ObservedWindow, String)? {
        guard let window = focusedWindow, !window.isMinimized,
              case .page(address, let title) = window.browserPage else { return nil }
        return (window, title)
    }

    private func visibleWindow(showing path: String) -> ObservedWindow? {
        guard let window = focusedWindow, window.documentPath == path, !window.isMinimized else { return nil }
        return window
    }

    /// Notes saved on exactly this window (same window-server number, same run of its app) before Hintlet
    /// restarted are back on it: no guess, so no need to ask.
    private func findAgainAfterRelaunch(_ window: ObservedWindow) {
        guard let key = window.serverKey else { return }
        for index in notes.indices {
            guard case .window(let fingerprint, let anchor, .unmatched(.relaunched)) = notes[index].placement,
                  fingerprint.serverKey == key else { continue }
            notes[index].placement = .window(fingerprint, anchor, .matched(window.id))
            notes[index].declinedSuggestions = false
        }
    }

    /// Keeps the latest title and place of a window with notes, for suggestions after a relaunch.
    private func rememberDetails(of window: ObservedWindow) {
        guard !window.isMinimized else { return }
        if case .conversation(let ref, let title) = window.claudePage {
            for index in notes.indices {
                guard case .conversation(ref, let was, let anchor) = notes[index].placement, was != title else { continue }
                notes[index].placement = .conversation(ref, title: title, anchor)
            }
        }
        if case .page(let address, let title) = window.browserPage {
            for index in notes.indices {
                guard case .webPage(address, let was, let anchor) = notes[index].placement, was != title else { continue }
                notes[index].placement = .webPage(address: address, title: title, anchor)
            }
        }
        for index in notes.indices {
            guard case .window(let fingerprint, let anchor, .matched(window.id)) = notes[index].placement else { continue }
            var latest = WindowFingerprint(window)
            latest.isFallback = fingerprint.isFallback
            if latest != fingerprint { notes[index].placement = .window(latest, anchor, .matched(window.id)) }
        }
    }

    /// The top-right default spot, nudged down-left past this window's notes already sitting (about) there.
    private func freeTopRightSpot(in window: ObservedWindow, size: CGSize) -> CGRect {
        let taken = notes.filter { $0.deletedAt == nil }.compactMap { note -> CGPoint? in
            switch note.placement {
            case .window(_, let anchor, .matched(window.id)): anchor.frame(in: window.frame).origin
            case .document(let path, let anchor) where path == window.documentPath: anchor.frame(in: window.frame).origin
            case .conversation(let ref, _, let anchor) where visibleWindow(showing: ref)?.0.id == window.id:
                anchor.frame(in: window.frame).origin
            case .webPage(let address, _, let anchor) where visibleWindow(showingPage: address)?.0.id == window.id:
                anchor.frame(in: window.frame).origin
            default: nil
            }
        }
        func isTaken(_ origin: CGPoint) -> Bool {
            taken.contains { abs($0.x - origin.x) < Self.staggerStep / 2 && abs($0.y - origin.y) < Self.staggerStep / 2 }
        }
        var frame = CGRect(x: window.frame.maxX - Self.topRightInset.width - size.width,
                           y: window.frame.maxY - Self.topRightInset.height - size.height,
                           width: size.width, height: size.height).clamped(into: window.frame)
        while isTaken(frame.origin) {
            let next = frame.offsetBy(dx: -Self.staggerStep, dy: -Self.staggerStep)
            // Once the stagger would leave the window, overlapping is the lesser evil.
            guard window.frame.contains(next) else { break }
            frame = next
        }
        return frame
    }

    private func update(_ id: NoteID, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
    }

    /// A note may hang off its window, but never off the screen: if the window has been moved so the note
    /// would leave the display, it waits at the screen's edge. It may go right down to the bottom and the sides,
    /// over the Dock, and up to the menu bar.
    private func keptOnScreen(_ frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? screen(containing: center) else {
            return frame
        }
        return frame.clamped(into: screen.placeableFrame)
    }

    /// Codex threads are listed under the app that shows them, which macOS calls ChatGPT.
    private static func listedApp(of kind: ConversationKind) -> ListedApp {
        switch kind {
        case .cli: .claudeCodeTerminal
        case .codex: .app("ChatGPT")
        case .chat, .cowork, .code: .app("Claude")
        }
    }

    private func screen(containing point: CGPoint) -> Screen? {
        screens.first { $0.frame.contains(point) } ?? screens.first
    }
}

// MARK: - The central list

extension NoteEngine {
    private enum GroupKey: Hashable {
        case floating
        case window(WindowID)
        case document(String)
        case conversation(ConversationRef)
        case webPage(String)
    }

    private struct Listing {
        var key: GroupKey
        var app: ListedApp
        var context: ScopeLabel
        var conversation: ConversationRef?
        var isArchived = false
    }

    /// Every note, for the central list. `query` keeps only the notes whose text or context's name has
    /// every word of it; `sessions` tells a Cowork or Code session's current name and whether it is archived.
    public func list(searching query: String = "",
                     sessions: (ConversationRef) -> ClaudeSessionInfo? = { _ in nil }) -> NoteList {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let waitingReasons = Dictionary(unmatchedNotes.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        var groups: [GroupKey: (listing: Listing, notes: [ListedNote])] = [:]
        var waiting: [ListedNote] = []
        var trash: [ListedNote] = []

        for note in notes {
            let listing = listing(of: note, sessions: sessions)
            let searchable = note.text + "\n" + (note.ai?.summary?.lines.joined(separator: "\n") ?? "")
            guard Self.matches(words, searchable, listing.context) else { continue }
            let reason = note.deletedAt == nil ? waitingReasons[note.id] : nil
            let entry = ListedNote(id: note.id, text: note.text, color: shownColor(of: note), updatedAt: note.updatedAt,
                                   context: listing.context, waitingReason: reason, deletedAt: note.deletedAt,
                                   aiLines: note.ai.map { $0.summary?.lines ?? [] })
            if note.deletedAt != nil {
                trash.append(entry)
            } else if reason != nil {
                waiting.append(entry)
            } else {
                groups[listing.key, default: (listing, [])].notes.append(entry)
            }
        }
        let newestFirst: (ListedNote, ListedNote) -> Bool = { $0.updatedAt > $1.updatedAt }
        let listed = groups.values.map { group in
            NoteListGroup(app: group.listing.app, context: group.listing.context, conversation: group.listing.conversation,
                          isArchived: group.listing.isArchived, notes: group.notes.sorted(by: newestFirst))
        }
        return NoteList(groups: listed.sorted { $0.notes[0].updatedAt > $1.notes[0].updatedAt },
                        waiting: waiting.sorted(by: newestFirst),
                        trash: trash.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) })
    }

    private func listing(of note: Note, sessions: (ConversationRef) -> ClaudeSessionInfo?) -> Listing {
        switch note.placement {
        case .floating:
            return Listing(key: .floating, app: .floating, context: .floating)
        case .window(let fingerprint, _, let state):
            // While it shows, it says what the note says (e.g. that a browser's page couldn't be bound to).
            let label: ScopeLabel = displayed(note)?.scopeLabel ?? (fingerprint.isFallback == true
                ? .windowFallback(appName: fingerprint.appName, title: fingerprint.title)
                : .window(appName: fingerprint.appName, title: fingerprint.title))
            // A waiting note isn't grouped: it is listed on its own.
            let key: GroupKey = if case .matched(let id) = state { .window(id) } else { .floating }
            return Listing(key: key, app: .app(fingerprint.appName), context: label)
        case .document(let path, _):
            let appName = visibleWindow(showing: path)?.appName ?? ""
            return Listing(key: .document(path), app: .documents, context: Self.documentLabel(path: path, appName: appName))
        case .conversation(let ref, let title, _):
            let info = sessions(ref)
            let name = info.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? title
            return Listing(key: .conversation(ref), app: Self.listedApp(of: ref.kind), context: .conversation(title: name),
                           conversation: ref, isArchived: info?.isArchived ?? false)
        case .webPage(let address, let title, _):
            let shownTitle = visibleWindow(showingPage: address)?.1 ?? title
            return Listing(key: .webPage(address), app: .webPages, context: .webPage(title: shownTitle, address: address))
        }
    }

    /// What "重新綁定到目前內容" would bind a note to now, for the list to say; nil when there is nothing to bind to.
    public var rebindContext: ScopeLabel? {
        guard creationBlock == nil, let window = windowToBindTo else { return nil }
        let frame = CGRect(origin: CGPoint(x: window.frame.midX, y: window.frame.midY), size: newNoteSize)
        let probe = Note(id: UUID(), placement: placement(on: window, anchor: WindowAnchor(frame: frame, in: window.frame)),
                         text: "", createdAt: now(), updatedAt: now())
        return displayed(probe)?.scopeLabel
    }

    /// Unbinds the note, shown or not: it floats, always showing. One showing stays where it is; one waiting
    /// to be found again comes back where it was on its old window, or else at the screen's top-right.
    public func makeFloating(_ id: NoteID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].deletedAt == nil, notes[index].ai == nil else { return }
        let note = notes[index]
        if case .floating = note.placement { return }
        let frame: CGRect
        if let shown = displayed(note) {
            frame = shown.frame
        } else if case .window(let fingerprint, let anchor, _) = note.placement {
            frame = keptOnScreen(anchor.frame(in: fingerprint.frame))
        } else {
            let size = Self.anchor(of: note.placement)?.size ?? newNoteSize
            let area = screens.first?.visibleFrame ?? CGRect(origin: .zero, size: size)
            frame = CGRect(x: area.maxX - Self.topRightInset.width - size.width, y: area.maxY - Self.topRightInset.height - size.height,
                           width: size.width, height: size.height).clamped(into: area)
        }
        notes[index].placement = .floating(frame)
        notes[index].declinedSuggestions = false
        notes[index].updatedAt = now()
    }

    private static func matches(_ words: [String], _ text: String, _ context: ScopeLabel) -> Bool {
        let haystack = text + "\n" + context.searchableName
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }
}

// MARK: - AI notes

extension NoteEngine {
    /// Whether the note can become an AI note now: an empty, ordinary note on a conversation of a kind AI
    /// notes are offered on, which has no AI note yet. The note's menu offers it on any such note; the
    /// note itself offers it only while just placed (`DisplayedNote.offersAI`).
    public func canMakeAINote(_ id: NoteID) -> Bool {
        guard let note = notes.first(where: { $0.id == id }), note.deletedAt == nil, note.ai == nil,
              let ref = Self.conversation(of: note.placement),
              aiConversationKinds.contains(ref.kind) else { return false }
        return aiNote(on: ref, excluding: id) == nil
    }

    /// Makes the note the conversation's AI note, read-only and in the AI colour from the settings
    /// (`aiNoteColor`), and asks for its first summary.
    public func makeAINote(_ id: NoteID) {
        guard canMakeAINote(id), let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let written = notes[index].text
        notes[index].ai = AINoteState(summary: nil, keptText: written.allSatisfy(\.isWhitespace) ? nil : written)
        notes[index].text = ""
        notes[index].updatedAt = now()
        justPlaced.remove(id)
        heightsToFit.insert(id)
        requestSummary(id)
    }

    /// "轉成一般便利貼": the AI note becomes an ordinary one the user can edit again, in its old colour,
    /// saying what the AI note says now (`summaryText` words it as shown). Before it has said anything,
    /// what the user had written before comes back.
    public func makeOrdinaryNote(_ id: NoteID, summaryText: (AISummary) -> String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), let ai = notes[index].ai else { return }
        let shown = ai.summary.map(summaryText) ?? ""
        notes[index].ai = nil
        notes[index].text = shown.allSatisfy(\.isWhitespace) ? ai.keptText ?? "" : shown
        notes[index].updatedAt = now()
        aiStatus[id] = nil
        heightsToFit.remove(id)
        summaryRequests.removeAll { $0.noteID == id }
    }

    /// Now and then: each AI note looks for a reply Claude has finished since its summary
    /// (`SummaryRequest.waitsToSettle`).
    public func checkForNewReplies() {
        for note in notes where note.ai != nil && note.deletedAt == nil {
            enqueueSummary(of: note.id, manual: false, waitingToSettle: true)
        }
    }

    /// "更新": asks for a new summary now, even if the conversation hasn't changed. Only for AI notes.
    public func requestSummary(_ id: NoteID) {
        enqueueSummary(of: id, manual: true)
    }

    /// The summaries to write, oldest request first; each is handed out once.
    public func takeSummaryRequests() -> [SummaryRequest] {
        defer { summaryRequests = [] }
        return summaryRequests.filter { request in
            notes.contains { $0.id == request.noteID && $0.ai != nil && $0.deletedAt == nil }
        }
    }

    /// A summary is being written for the note; it says so meanwhile.
    public func summaryStarted(_ id: NoteID) {
        guard isAINote(id) else { return }
        aiStatus[id] = .updating
    }

    /// Puts the summary on the AI note. Never touches any other note.
    public func applySummary(_ summary: AISummary, to id: NoteID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].ai != nil else { return }
        if notes[index].ai?.summary?.lines != summary.lines { heightsToFit.insert(id) }
        notes[index].ai?.summary = summary
        // The lines as text too, so the list shows and finds the note by them.
        notes[index].text = summary.lines.joined(separator: "\n")
        notes[index].updatedAt = now()
        aiStatus[id] = nil
    }

    /// The conversation hasn't changed since the note's summary: it stays as it is.
    public func summaryUpToDate(_ id: NoteID) {
        aiStatus[id] = nil
    }

    /// Writing the summary failed: the note keeps its last one and says the update didn't work, and why
    /// when `reason` is known.
    public func summaryFailed(_ id: NoteID, because reason: SummaryFailure? = nil) {
        guard isAINote(id) else { return }
        aiStatus[id] = .failed(reason)
    }

    /// Whether the user turned an AI note on for the conversation (and it isn't in the trash): the only
    /// conversations whose content may be read.
    public func hasAINote(on ref: ConversationRef) -> Bool {
        aiNote(on: ref) != nil
    }

    /// The note's last summary, for the next one to carry on from.
    public func summary(of id: NoteID) -> AISummary? {
        notes.first { $0.id == id }?.ai?.summary
    }

    private func isAINote(_ id: NoteID) -> Bool {
        notes.contains { $0.id == id && $0.ai != nil }
    }

    /// The conversation's AI note outside the trash, leaving out `excluded`.
    private func aiNote(on ref: ConversationRef, excluding excluded: NoteID? = nil) -> NoteID? {
        notes.first { note in
            note.id != excluded && note.ai != nil && note.deletedAt == nil && Self.conversation(of: note.placement) == ref
        }?.id
    }

    private static func conversation(of placement: Placement) -> ConversationRef? {
        if case .conversation(let ref, _, _) = placement { ref } else { nil }
    }

    private func enqueueSummary(of id: NoteID, manual: Bool, waitingToSettle: Bool = false) {
        guard let note = notes.first(where: { $0.id == id }), note.ai != nil, note.deletedAt == nil,
              let ref = Self.conversation(of: note.placement) else { return }
        if let index = summaryRequests.firstIndex(where: { $0.noteID == id }) {
            // The more urgent request wins.
            if manual { summaryRequests[index].isManual = true }
            if !waitingToSettle { summaryRequests[index].waitsToSettle = false }
            return
        }
        summaryRequests.append(SummaryRequest(noteID: id, conversation: ref, isManual: manual, waitsToSettle: waitingToSettle))
    }

    /// Switching away from a conversation (to another one, another app, or nothing known) brings its AI
    /// note up to date, so it is current when the user comes back.
    private func leaving(for observation: ContextObservation) {
        guard let window = focusedWindow, case .conversation(let left, _) = window.claudePage else { return }
        if case .window(let next) = observation, case .conversation(left, _) = next.claudePage { return }
        if let id = aiNote(on: left) { enqueueSummary(of: id, manual: false) }
    }
}

/// An AI note's state, for the overlay to draw.
public struct DisplayedAI: Equatable, Sendable {
    public let summary: AISummary?
    public let status: AIStatus

    public init(summary: AISummary?, status: AIStatus) {
        self.summary = summary
        self.status = status
    }
}

public enum AIStatus: Equatable, Sendable {
    case idle
    /// A summary is being written.
    case updating
    /// The last update didn't work, for this reason when it is known; the summary shown is the one before.
    case failed(SummaryFailure?)
}

/// "Write this AI note's summary." `isManual` for "更新" (and a new AI note): written even if the
/// conversation hasn't changed since the last one. `waitsToSettle` for the regular look for new replies:
/// written only once Claude has answered and the conversation has stopped changing.
public struct SummaryRequest: Equatable, Sendable {
    public let noteID: NoteID
    public let conversation: ConversationRef
    public var isManual: Bool
    public var waitsToSettle: Bool

    public init(noteID: NoteID, conversation: ConversationRef, isManual: Bool, waitsToSettle: Bool = false) {
        self.noteID = noteID
        self.conversation = conversation
        self.isManual = isManual
        self.waitsToSettle = waitsToSettle
    }
}

/// Pins a note to the window corner nearest to it, so the note keeps its distance from that corner
/// when the window moves or resizes. The note may sit outside the window (a negative inset).
struct WindowAnchor: Codable, Equatable, Sendable {
    let size: CGSize
    /// Whether the note hangs from the window's right edge (else its left edge).
    let fromRight: Bool
    /// Whether the note hangs from the window's top edge (else its bottom edge).
    let fromTop: Bool
    /// Distance from the anchoring vertical edge to the note's nearest side.
    let horizontalInset: CGFloat
    /// Distance from the anchoring horizontal edge to the note's nearest side.
    let verticalInset: CGFloat

    init(frame note: CGRect, in window: CGRect) {
        size = note.size
        fromRight = note.midX > window.midX
        fromTop = note.midY > window.midY
        horizontalInset = fromRight ? window.maxX - note.maxX : note.minX - window.minX
        verticalInset = fromTop ? window.maxY - note.maxY : note.minY - window.minY
    }

    /// Where the note goes for a window at `window`.
    func frame(in window: CGRect) -> CGRect {
        let x = fromRight ? window.maxX - horizontalInset - size.width : window.minX + horizontalInset
        let y = fromTop ? window.maxY - verticalInset - size.height : window.minY + verticalInset
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

extension CGRect {
    /// Moves (without resizing) so the rect lies inside `bounds` where possible. A rect bigger than
    /// `bounds` keeps its top-left corner in, so a note's first lines stay readable.
    func clamped(into bounds: CGRect) -> CGRect {
        var r = self
        r.origin.x = Swift.max(Swift.min(r.minX, bounds.maxX - r.width), bounds.minX)
        r.origin.y = Swift.min(Swift.max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
