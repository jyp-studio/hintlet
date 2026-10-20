import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let documentsWindow = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Documents",
                                             frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                                             bundleID: "com.apple.finder", documentPath: "/Users/me/Documents/")

private func showing(_ window: ObservedWindow, _ path: String?, title: String, id: UInt64? = nil) -> ObservedWindow {
    var copy = window
    copy.documentPath = path
    copy.title = title
    if let id { copy.id = WindowID(id) }
    return copy
}

@Suite("綁在資料夾或文件")
struct BindingToDocuments {
    @Test("在顯示資料夾的視窗建立的便利貼綁在該資料夾，標籤寫出資料夾")
    func bindsToTheFolder() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.document(appName: "Finder", name: "Documents", isFolder: true)])
    }

    @Test("同一個視窗切到別的資料夾時隱藏，切回來再出現")
    func followsTheFolderNotTheWindow() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(showing(documentsWindow, "/Users/me/Desktop/", title: "Desktop")))
        #expect(engine.displayedNotes.isEmpty)

        engine.observe(.window(documentsWindow))
        #expect(engine.displayedNotes.count == 1)
    }

    @Test("另一個視窗打開同一個資料夾時，便利貼出現在那個視窗的相對位置")
    func showsOnAnyWindowOfThatFolder() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        var other = showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 7)
        other.frame = documentsWindow.frame.offsetBy(dx: 50, dy: -20)
        engine.observe(.window(other))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 350, y: 500, width: 240, height: 180)])
        #expect(engine.displayedNotes.map(\.windowID) == [WindowID(7)])
    }

    @Test("視窗關閉不影響資料夾便利貼，重新打開就出現，不進待找回")
    func closingTheWindowKeepsTheBinding() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.windowsClosed([documentsWindow.id])
        #expect(engine.unmatchedNotes.isEmpty)

        engine.observe(.window(showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 9)))
        #expect(engine.displayedNotes.count == 1)
    }

    @Test("重新啟動後，打開同一個資料夾就直接出現，不需要確認")
    func comesBackAfterRelaunch() throws {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: "整理文件")
        let data = try JSONEncoder().encode(engine.document)

        let restored = NoteEngine(screens: [laptop], document: try JSONDecoder().decode(NotesDocument.self, from: data),
                                  pathExists: { _ in true })
        restored.observe(.window(showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 41)))

        #expect(restored.displayedNotes.map(\.text) == ["整理文件"])
        #expect(restored.unmatchedNotes.isEmpty)
        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("拖曳後，依新位置出現在這個資料夾的任何視窗")
    func movedNoteKeepsItsPlaceForTheFolder() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.moveNote(id, to: CGPoint(x: 200, y: 300))
        engine.observe(.window(showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 7)))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 200, y: 300, width: 240, height: 180)])
    }

    @Test("資料夾不見了（改名、搬走、刪除）時，便利貼進待找回，不會無聲消失")
    func missingFolderNotesWaitToBeFound() {
        var existing: Set<String> = ["/Users/me/Documents/"]
        let engine = NoteEngine(screens: [laptop], pathExists: { existing.contains($0) })
        engine.observe(.window(documentsWindow))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(engine.unmatchedNotes.isEmpty)

        existing = []

        #expect(engine.unmatchedNotes == [UnmatchedNote(id: id, text: "", reason: .documentMissing,
                                                        appName: "", title: "Documents")])
    }

    @Test("同一個資料夾的第二張便利貼也會錯開")
    func staggersOnAFolder() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(documentsWindow))

        engine.createNote(at: CGPoint(x: 1300, y: 900))
        engine.createNote(at: CGPoint(x: 1300, y: 900))

        let origins = engine.displayedNotes.map(\.frame.origin)
        #expect(origins.count == 2 && origins[0] != origins[1])
    }

    @Test("文件視窗：標籤寫出檔名")
    func bindsToTheFile() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        var report = documentsWindow
        report.appName = "Pages"
        report.title = "報告"
        report.documentPath = "/Users/me/報告.pages"
        engine.observe(.window(report))

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.document(appName: "Pages", name: "報告.pages", isFolder: false)])
    }

    @Test("讀不到路徑的視窗，便利貼仍綁在視窗")
    func windowsWithoutAPathKeepWindowBinding() {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(showing(documentsWindow, nil, title: "Documents")))

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Finder", title: "Documents")])
    }

    @Test("待找回的視窗便利貼，在有路徑的視窗確認找回後改綁該資料夾")
    func confirmingOnAFolderWindowBindsToTheFolder() throws {
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in true })
        engine.observe(.window(showing(documentsWindow, nil, title: "Documents")))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.windowsClosed([documentsWindow.id])

        engine.observe(.window(showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 7)))
        #expect(engine.recoveryCandidates.map(\.noteID) == [id])
        engine.confirmRecovery(of: id, on: WindowID(7))

        engine.observe(.window(showing(documentsWindow, "/Users/me/Documents/", title: "Documents", id: 8)))
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.document(appName: "Finder", name: "Documents", isFolder: true)])
    }
}
