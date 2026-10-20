import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let day: TimeInterval = 24 * 60 * 60

/// A clock the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

private func engine(clock: FakeClock, document: NotesDocument? = nil) -> NoteEngine {
    NoteEngine(screens: [laptop], document: document, now: { clock.now })
}

private func writtenNote(_ text: String, in engine: NoteEngine) -> NoteID {
    let id = engine.createNote(at: CGPoint(x: 300, y: 700))
    engine.editText(of: id, to: text)
    return id
}

@Suite("垃圾桶保留 30 天")
struct TrashRetention {
    @Test("刪除滿 30 天的便利貼被清除，未滿的還在")
    func purgedAfterThirtyDays() {
        let clock = FakeClock()
        let engine = engine(clock: clock)
        let old = writtenNote("舊的", in: engine)
        engine.deleteNote(old)
        clock.advance(10 * day)
        let recent = writtenNote("新的", in: engine)
        engine.deleteNote(recent)

        clock.advance(20 * day - 1)
        engine.purgeExpiredTrash()
        #expect(engine.trashedNotes.map(\.id) == [old, recent])

        clock.advance(1)
        engine.purgeExpiredTrash()
        #expect(engine.trashedNotes.map(\.id) == [recent])
        engine.restoreNote(old)
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("重新開啟時，已過期的便利貼直接清除")
    func purgedWhenLoaded() throws {
        let clock = FakeClock()
        let first = engine(clock: clock)
        first.deleteNote(writtenNote("過期", in: first))
        let saved = try JSONDecoder().decode(NotesDocument.self, from: JSONEncoder().encode(first.document))

        clock.advance(31 * day)
        #expect(engine(clock: clock, document: saved).trashedNotes.isEmpty)
    }
}

@Suite("永久刪除")
struct DeletingForGood {
    @Test("從垃圾桶永久刪除一張，其他留著；不在垃圾桶的便利貼不受影響")
    func deleteOneForGood() {
        let engine = engine(clock: FakeClock())
        let gone = writtenNote("不要了", in: engine)
        let kept = writtenNote("先留著", in: engine)
        let showing = writtenNote("還在用", in: engine)
        engine.deleteNote(gone)
        engine.deleteNote(kept)

        engine.deleteForever(gone)
        engine.deleteForever(showing)

        #expect(engine.trashedNotes.map(\.id) == [kept])
        #expect(engine.displayedNotes.map(\.id) == [showing])
        engine.restoreNote(gone)
        #expect(engine.displayedNotes.map(\.id) == [showing])
    }

    @Test("清空垃圾桶")
    func emptyTheTrash() {
        let engine = engine(clock: FakeClock())
        engine.deleteNote(writtenNote("一", in: engine))
        engine.deleteNote(writtenNote("二", in: engine))
        let showing = writtenNote("還在用", in: engine)

        engine.emptyTrash()

        #expect(engine.trashedNotes.isEmpty)
        #expect(engine.displayedNotes.map(\.id) == [showing])
    }
}

private let chat = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-000000000001")
private let code = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-000000000002")
private let cowork = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-000000000003")

private func claude(showing ref: ConversationRef) -> ContextObservation {
    .window(ObservedWindow(id: WindowID(1), appName: "Claude", title: "Claude",
                           frame: CGRect(x: 0, y: 79, width: 1512, height: 870),
                           bundleID: "com.anthropic.claudefordesktop",
                           claudePage: .conversation(ref, title: "對話")))
}

@Suite("Session 被刪除")
struct DeletedSessions {
    /// One written note on each conversation.
    private func notesOnEachConversation(clock: FakeClock) -> (NoteEngine, [ConversationRef: NoteID]) {
        let engine = engine(clock: clock)
        var ids: [ConversationRef: NoteID] = [:]
        for ref in [chat, code, cowork] {
            engine.observe(claude(showing: ref))
            ids[ref] = writtenNote("在 \(ref.kind)", in: engine)
        }
        return (engine, ids)
    }

    @Test("只看 Code 與 Cowork 的 session，Chat 不偵測")
    func watchesOnlyLocalSessions() {
        let (engine, _) = notesOnEachConversation(clock: FakeClock())

        #expect(engine.sessionsToWatch == [code, cowork])
    }

    @Test("Code session 消失，它的便利貼移到垃圾桶，回到那個對話也不再出現")
    func deletedSessionsNotesGoToTheTrash() {
        let clock = FakeClock()
        let (engine, ids) = notesOnEachConversation(clock: clock)

        engine.sessionsDeleted([code])

        #expect(engine.trashedNotes.map(\.id) == [ids[code]])
        #expect(engine.trashedNotes.map(\.deletedAt) == [clock.now])
        engine.observe(claude(showing: code))
        #expect(engine.displayedNotes.isEmpty)
        #expect(engine.sessionsToWatch == [cowork])
    }

    @Test("Chat 對話的便利貼不因任何偵測而移走")
    func chatNotesAreNeverMovedAway() {
        let (engine, ids) = notesOnEachConversation(clock: FakeClock())

        engine.sessionsDeleted([chat])

        #expect(engine.trashedNotes.isEmpty)
        engine.observe(claude(showing: chat))
        #expect(engine.displayedNotes.map(\.id) == [ids[chat]])
    }
}
