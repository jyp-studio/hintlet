import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let guide = BrowserPage.page(address: "https://example.com/guide", title: "安裝指南")
private let video = BrowserPage.page(address: "https://www.youtube.com/watch?v=abc123", title: "教學影片")

private func safari(_ page: BrowserPage?, id: UInt64 = 1, title: String = "安裝指南") -> ObservedWindow {
    ObservedWindow(id: WindowID(id), appName: "Safari", title: title, frame: CGRect(x: 100, y: 200, width: 1000, height: 700),
                   bundleID: "com.apple.Safari", browserPage: page)
}

@Suite("綁在網頁")
struct BindingToWebPages {
    @Test("在網頁上按 ⌘⌥N，便利貼綁在網頁，標籤寫出網頁標題、帶著網址")
    func bindsToThePage() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.webPage(title: "安裝指南", address: "https://example.com/guide")])
    }

    @Test("切到別的分頁時隱藏，切回來在原位置出現")
    func followsTheTab() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let shown = engine.displayedNotes

        engine.observe(.window(safari(video, title: "教學影片")))
        #expect(engine.displayedNotes.isEmpty)

        engine.observe(.window(safari(guide)))
        #expect(engine.displayedNotes == shown)
    }

    @Test("另一個視窗（或另一個瀏覽器）打開同一個網頁，便利貼出現在那個視窗的相對位置")
    func showsOnAnyWindowOfThatPage() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        var chrome = ObservedWindow(id: WindowID(7), appName: "Google Chrome", title: "安裝指南",
                                    frame: CGRect(x: 150, y: 180, width: 1000, height: 700),
                                    bundleID: "com.google.Chrome", browserPage: guide)
        engine.observe(.window(chrome))
        #expect(engine.displayedNotes.map(\.windowID) == [WindowID(7)])
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 350, y: 500, width: 240, height: 180)])

        // Only the focused window shows it, as for a folder open in two windows.
        chrome.browserPage = video
        engine.observe(.window(chrome))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("網頁標題變了，標籤跟著變")
    func titleFollowsThePage() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(safari(.page(address: "https://example.com/guide", title: "安裝指南（新版）"))))

        #expect(engine.displayedNotes.map(\.scopeLabel)
            == [.webPage(title: "安裝指南（新版）", address: "https://example.com/guide")])
    }

    @Test("瀏覽器或 Hintlet 重啟後，打開同一個網頁就直接出現，不需要「可能是這裡？」")
    func comesBackAfterRelaunch() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: "照第三步做")
        let data = try JSONEncoder().encode(engine.document)

        let relaunched = NoteEngine(screens: [laptop], document: try JSONDecoder().decode(NotesDocument.self, from: data))
        #expect(relaunched.unmatchedNotes.isEmpty)
        relaunched.observe(.window(safari(guide, id: 42)))

        #expect(relaunched.displayedNotes.map(\.text) == ["照第三步做"])
        #expect(relaunched.recoveryCandidates.isEmpty)
    }

    @Test("視窗關閉不影響網頁便利貼，不進待找回")
    func closingTheWindowKeepsTheBinding() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.windowsClosed([WindowID(1)])

        #expect(engine.unmatchedNotes.isEmpty)
        engine.observe(.window(safari(guide, id: 3)))
        #expect(engine.displayedNotes.count == 1)
    }

    @Test("小島的範圍選項：網頁、整個視窗、浮動")
    func scopeOptions() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.scopeOptions(for: id).map(\.scope) == [.webPage, .window, .floating])
        #expect(engine.scopeOptions(for: id).first?.isCurrent == true)
    }

    @Test("網頁與整個視窗互換：改成視窗後換網頁還在，改回網頁後只在這頁")
    func switchingScopes() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        let frame = engine.displayedNotes.first?.frame

        engine.changeScope(of: id, to: .window)
        #expect(engine.displayedNotes.map(\.frame) == [frame])
        engine.observe(.window(safari(video, title: "教學影片")))
        #expect(engine.displayedNotes.map(\.id) == [id])

        engine.changeScope(of: id, to: .webPage)
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.webPage(title: "教學影片", address: "https://www.youtube.com/watch?v=abc123")])
        engine.observe(.window(safari(guide)))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("綁在視窗的便利貼可以重新綁到目前的網頁")
    func rebindingGoesToThePage() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)
        #expect(engine.canRebindToCurrentContext(id))

        engine.rebindToCurrentContext(id)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.webPage(title: "安裝指南", address: "https://example.com/guide")])
        #expect(!engine.canRebindToCurrentContext(id))
    }
}

@Suite("不能以網址綁定的頁面")
struct PagesWithoutAnAddress {
    @Test("新分頁或起始頁不能新貼，提示並可以改貼在這個視窗")
    func newTabBlocksCreation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(.newTab, title: "起始頁")))

        #expect(engine.creationBlock == .newBrowserTab)
        engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Safari", title: "起始頁")])
    }

    @Test("瀏覽器自己的頁面降級到視窗範圍，標籤標示")
    func internalPagesFallBackToTheWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(.unrecognized, title: "設定")))

        #expect(engine.creationBlock == nil)
        #expect(engine.creationFallsBack)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.webPageFallback(appName: "Safari", title: "設定")])
    }

    @Test("私密瀏覽視窗只有視窗範圍，網址與頁面標題都不寫進檔案")
    func privateWindowsAreWindowOnly() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(.privateWindow, title: "私密頁面")))

        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.observe(.window(safari(.privateWindow, title: "另一個私密頁面")))

        #expect(!engine.creationFallsBack)
        // Shown with the window's title as it is now, which isn't saved.
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Safari", title: "另一個私密頁面")])
        #expect(engine.scopeOptions(for: id).map(\.scope) == [.window, .floating])
        let saved = String(decoding: try JSONEncoder().encode(engine.document), as: UTF8.self)
        #expect(!saved.contains("http"))
        #expect(!saved.contains("私密頁面"))
    }

    @Test("網頁便利貼在新分頁、內部頁面、私密視窗都不出現")
    func pageNotesStayOffOtherPages() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(safari(guide)))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        for page in [BrowserPage.newTab, .unrecognized, .privateWindow] {
            engine.observe(.window(safari(page)))
            #expect(engine.displayedNotes.isEmpty)
        }
    }
}
