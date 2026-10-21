import Foundation
import CoreGraphics
import Testing
import HintletCore

/// Screens use AppKit global coordinates: origin at the bottom-left of the primary screen, y grows upward.
private let primaryScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
private let primary = Screen(frame: primaryScreen, visibleFrame: primaryScreen)

@Suite("建立便利貼")
struct CreatingNotes {
    @Test("在游標位置建立一張空白便利貼，左上角對齊游標")
    func createsNoteWithTopLeftAtCursor() {
        let engine = NoteEngine(screens: [primary])

        engine.createNote(at: CGPoint(x: 300, y: 600))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 300, y: 420, width: 240, height: 180)])
        #expect(engine.displayedNotes.map(\.text) == [""])
    }

    @Test("游標靠近螢幕右下角時，便利貼整張留在螢幕內")
    func keepsNoteInsideScreenNearEdge() {
        let engine = NoteEngine(screens: [primary])

        engine.createNote(at: CGPoint(x: 1400, y: 100))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 1200, y: 0, width: 240, height: 180)])
    }
}

@Suite("編輯與拖曳")
struct EditingNotes {
    @Test("編輯文字後，顯示的便利貼帶有新內容")
    func editedTextIsDisplayed() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))

        engine.editText(of: id, to: "下一步：補測試")

        #expect(engine.displayedNotes.map(\.text) == ["下一步：補測試"])
    }

    @Test("拖曳後，便利貼停在放開的位置")
    func movedNoteStaysWhereDropped() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))

        engine.moveNote(id, to: CGPoint(x: 500, y: 200))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 500, y: 200, width: 240, height: 180)])
    }
}

@Suite("多螢幕")
struct MultipleScreens {
    @Test("游標在第二個螢幕時，便利貼留在第二個螢幕內")
    func clampsToScreenUnderCursor() {
        let secondaryFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let engine = NoteEngine(screens: [primary])
        engine.updateScreens([primary, Screen(frame: secondaryFrame, visibleFrame: secondaryFrame)])

        engine.createNote(at: CGPoint(x: 3300, y: 1000))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 3120, y: 820, width: 240, height: 180)])
    }

    @Test("游標在第二個螢幕的選單列上時，便利貼仍放在第二個螢幕")
    func cursorOverSecondaryMenuBarStaysOnThatScreen() {
        let secondary = Screen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let engine = NoteEngine(screens: [primary, secondary])

        engine.createNote(at: CGPoint(x: 2000, y: 1070))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 2000, y: 875, width: 240, height: 180)])
    }
}


@Suite("空白便利貼")
struct EmptyNotes {
    @Test("結束編輯時還是空白（或只有空白字元）的便利貼直接丟掉")
    func emptyNotesAreDiscarded() {
        let engine = NoteEngine(screens: [primary])
        let empty = engine.createNote(at: CGPoint(x: 300, y: 600))
        let blank = engine.createNote(at: CGPoint(x: 600, y: 600))
        engine.editText(of: blank, to: " \n ")

        #expect(engine.discardIfEmpty(empty))
        #expect(engine.discardIfEmpty(blank))
        #expect(engine.displayedNotes.isEmpty)
        #expect(engine.document == NoteEngine(screens: [primary]).document)
    }

    @Test("有內容的便利貼不受影響")
    func notesWithTextStay() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: id, to: "下一步")

        #expect(!engine.discardIfEmpty(id))
        #expect(engine.displayedNotes.map(\.text) == ["下一步"])
    }
}

@Suite("收合、尺寸、顏色")
struct NoteAppearance {
    @Test("新便利貼是黃色、展開的")
    func defaults() {
        let engine = NoteEngine(screens: [primary])
        engine.createNote(at: CGPoint(x: 300, y: 600))

        #expect(engine.displayedNotes.map(\.color) == [.yellow])
        #expect(engine.displayedNotes.map(\.isCollapsed) == [false])
    }

    @Test("調整大小時左上角不動，且不小於最小尺寸")
    func resizesFromTheTopLeft() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))

        engine.resizeNote(id, to: CGSize(width: 320, height: 260))
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 300, y: 340, width: 320, height: 260)])

        engine.resizeNote(id, to: CGSize(width: 10, height: 10))
        #expect(engine.displayedNotes.map(\.frame.size) == [NoteEngine.minimumNoteSize])
        #expect(engine.displayedNotes.map(\.frame.maxY) == [600])
    }

    @Test("從任何一邊調整大小：拖到哪裡就是哪裡，太小時保持最小尺寸")
    func resizesFromAnyEdge() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))

        // Dragging the left edge further left: the right edge stays.
        engine.setFrame(of: id, to: CGRect(x: 250, y: 420, width: 290, height: 180))
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 250, y: 420, width: 290, height: 180)])

        engine.setFrame(of: id, to: CGRect(x: 250, y: 420, width: 20, height: 20))
        #expect(engine.displayedNotes.map(\.frame.size) == [NoteEngine.minimumNoteSize])
    }

    @Test("綁在視窗的便利貼，切走再回來仍保持收合、尺寸與顏色")
    func survivesSwitching() {
        let engine = NoteEngine(screens: [primary])
        let window = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads",
                                    frame: CGRect(x: 100, y: 100, width: 900, height: 700))
        let other = ObservedWindow(id: WindowID(2), appName: "Safari", title: "文件",
                                   frame: CGRect(x: 200, y: 100, width: 900, height: 700))
        engine.observe(.window(window))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.resizeNote(id, to: CGSize(width: 300, height: 220))
        engine.setColor(of: id, to: .blue)
        engine.setCollapsed(id, true)
        let before = engine.displayedNotes

        engine.observe(.window(other))
        engine.observe(.window(window))

        #expect(engine.displayedNotes == before)
        #expect(before.map(\.frame) == [CGRect(x: 300, y: 480, width: 300, height: 220)])
    }

    @Test("收合、尺寸、顏色存檔後讀回一致")
    func survivesSaving() throws {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: id, to: "下一步")
        engine.resizeNote(id, to: CGSize(width: 300, height: 220))
        engine.setColor(of: id, to: .pink)
        engine.setCollapsed(id, true)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HintletTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try NoteStore(directory: folder).save(engine.document)
        let restored = NoteEngine(screens: [primary], document: try #require(try NoteStore(directory: folder).load()))

        #expect(restored.displayedNotes == engine.displayedNotes)
    }

    @Test("不認得的顏色（來自較新的版本）讀成黃色，不影響其他便利貼")
    func unknownColorReadsAsYellow() throws {
        let json = #"""
        {"formatVersion": 3, "notes": [{"id": "33333333-3333-3333-3333-333333333333", "text": "A", "createdAt": 0,
          "updatedAt": 0, "color": "orange", "binding": {"floating": {"frame": [[100, 100], [240, 180]]}}}]}
        """#
        let document = try JSONDecoder().decode(NotesDocument.self, from: Data(json.utf8))

        #expect(NoteEngine(screens: [primary], document: document).displayedNotes.map(\.color) == [.yellow])
    }

    @Test("收合的空白便利貼也會在結束編輯時丟掉")
    func collapsedStateDoesNotKeepEmptyNotes() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.setCollapsed(id, true)
        #expect(engine.discardIfEmpty(id))
    }
}

@Suite("刪除")
struct DeletingNotes {
    @Test("刪除的便利貼不再顯示，但進垃圾桶保留，可以復原到原處")
    func deletedNotesGoToTheTrash() {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: id, to: "別丟")
        let shown = engine.displayedNotes

        engine.deleteNote(id)
        #expect(engine.displayedNotes.isEmpty)
        #expect(engine.trashedNotes.map(\.id) == [id])

        engine.restoreNote(id)
        #expect(engine.displayedNotes == shown)
        #expect(engine.trashedNotes.isEmpty)
    }

    @Test("垃圾桶裡的便利貼不會被當成空白便利貼丟掉，也不影響新便利貼的錯開位置")
    func trashedNotesAreLeftAlone() {
        let engine = NoteEngine(screens: [primary])
        let window = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads",
                                    frame: CGRect(x: 100, y: 100, width: 900, height: 700))
        engine.observe(.window(window))
        let first = engine.createNote(at: CGPoint(x: 1300, y: 900))
        let spot = engine.displayedNotes.map(\.frame)
        engine.deleteNote(first)

        #expect(!engine.discardIfEmpty(first))
        engine.createNote(at: CGPoint(x: 1300, y: 900))
        #expect(engine.displayedNotes.map(\.frame) == spot)
    }

    @Test("垃圾桶裡的便利貼存檔後仍在垃圾桶")
    func trashSurvivesSaving() throws {
        let engine = NoteEngine(screens: [primary])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: id, to: "別丟")
        engine.deleteNote(id)

        let saved = try JSONDecoder().decode(NotesDocument.self, from: JSONEncoder().encode(engine.document))
        let restored = NoteEngine(screens: [primary], document: saved)

        #expect(restored.displayedNotes.isEmpty)
        #expect(restored.trashedNotes.map(\.text) == ["別丟"])
    }
}
