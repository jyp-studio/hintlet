import CoreGraphics
import Foundation
import Testing
import HintletCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let downloads = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads",
                                       frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                                       bundleID: "com.apple.finder")

@Suite("暫時隱藏全部")
struct HidingAll {
    @Test("隱藏全部時，浮動與視窗便利貼都不顯示；取消後回來")
    func hidesFloatingAndWindowNotes() {
        let engine = NoteEngine(screens: [laptop])
        engine.createNote(at: CGPoint(x: 1200, y: 900))
        engine.observe(.window(downloads))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let before = engine.displayedNotes
        #expect(before.count == 2)

        engine.hidesAll = true
        #expect(engine.displayedNotes.isEmpty)

        engine.hidesAll = false
        #expect(engine.displayedNotes == before)
    }

    @Test("隱藏時也不顯示「可能是這裡？」的提示")
    func hidesRecoverySuggestions() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(downloads))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let restored = NoteEngine(screens: [laptop], document: engine.document)
        var reopened = downloads
        reopened.id = WindowID(41)
        restored.observe(.window(reopened))
        #expect(!restored.recoveryCandidates.isEmpty)

        restored.hidesAll = true

        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("隱藏時新增便利貼，就不再隱藏")
    func creatingANoteShowsAllAgain() {
        let engine = NoteEngine(screens: [laptop])
        engine.createNote(at: CGPoint(x: 1200, y: 900))
        engine.hidesAll = true

        engine.createNote(at: CGPoint(x: 300, y: 600))

        #expect(!engine.hidesAll)
        #expect(engine.displayedNotes.count == 2)
    }

    @Test("隱藏不會寫進存檔，重新啟動後照常顯示")
    func notSaved() {
        let engine = NoteEngine(screens: [laptop])
        engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.hidesAll = true

        let restored = NoteEngine(screens: [laptop], document: engine.document)

        #expect(restored.displayedNotes.count == 1)
    }
}

private let notesApp = ObservedWindow(id: WindowID(2), appName: "Notes", title: "購物清單",
                                      frame: CGRect(x: 600, y: 200, width: 800, height: 600),
                                      bundleID: "com.apple.Notes")

@Suite("隱藏或刪除這個視窗的便利貼")
struct OneWindowsNotes {
    @Test("只隱藏目前視窗的便利貼，其他視窗與浮動的照常；再選一次就回來")
    func hidesOnlyThisWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.createNote(at: CGPoint(x: 1200, y: 900))
        engine.observe(.window(notesApp))
        engine.createNote(at: CGPoint(x: 700, y: 700))
        engine.observe(.window(downloads))
        let here = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.createNote(at: CGPoint(x: 400, y: 600))
        #expect(engine.notesOnFocusedWindow.count == 2)

        engine.setFocusedWindowNotesHidden(true)
        #expect(engine.hidesFocusedWindowNotes)
        #expect(engine.hidesSomeNotes)
        #expect(!engine.displayedNotes.contains { $0.id == here })
        #expect(engine.displayedNotes.count == 1)
        engine.observe(.window(notesApp))
        #expect(engine.displayedNotes.count == 2)

        engine.observe(.window(downloads))
        engine.setFocusedWindowNotesHidden(false)
        #expect(engine.displayedNotes.count == 3)
        #expect(!engine.hidesSomeNotes)
    }

    @Test("在隱藏的視窗新增便利貼，原本的便利貼一起回來")
    func newNoteBringsThemBack() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(downloads))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.setFocusedWindowNotesHidden(true)

        engine.createNote(at: CGPoint(x: 500, y: 600))

        #expect(engine.displayedNotes.count == 2)
        #expect(!engine.hidesFocusedWindowNotes)
    }

    @Test("刪除這個視窗的便利貼會移到垃圾桶，可以還原")
    func deletesToTrash() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(downloads))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.createNote(at: CGPoint(x: 500, y: 600))
        let ids = engine.notesOnFocusedWindow

        engine.deleteNotes(ids)
        #expect(engine.displayedNotes.isEmpty)
        #expect(engine.trashedNotes.count == 2)

        ids.forEach(engine.restoreNote)
        #expect(engine.displayedNotes.count == 2)
    }
}
