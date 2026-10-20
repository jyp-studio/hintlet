import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let refactor = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-000000000001")
private let tests = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-000000000002")

private func claude(_ page: ClaudePage?, id: UInt64 = 1) -> ObservedWindow {
    ObservedWindow(id: WindowID(id), appName: "Claude", title: "Claude", frame: CGRect(x: 0, y: 79, width: 1512, height: 870),
                   bundleID: "com.anthropic.claudefordesktop", claudePage: page)
}

@Suite("綁定 Claude 對話")
struct BindingToConversations {
    @Test("在對話上按 ⌘⌥N，便利貼綁在該對話，標籤寫出對話標題")
    func bindsToTheConversation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "重構登入流程")])
    }

    @Test("切到別的對話時立刻隱藏，回來時在原位置出現")
    func showsOnlyOnItsConversation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let shown = engine.displayedNotes

        engine.observe(.window(claude(.conversation(tests, title: "補測試"))))
        #expect(engine.displayedNotes.isEmpty)

        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        #expect(engine.displayedNotes == shown)
    }

    @Test("在對話之間快速切換，不會在新對話上出現舊對話的便利貼")
    func rapidSwitchingNeverShowsTheOldNote() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        for page in [ClaudePage.conversation(tests, title: "補測試"), .draft, .unrecognized, .settings,
                     .conversation(tests, title: "補測試")] {
            engine.observe(.window(claude(page)))
            #expect(engine.displayedNotes.isEmpty)
        }
    }

    @Test("對話改名後標籤顯示新標題")
    func renamedConversation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(claude(.conversation(refactor, title: "登入流程 v2"))))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "登入流程 v2")])
    }

    @Test("設定開著時對話的便利貼先隱藏，視窗範圍的便利貼照常")
    func settingsHideConversationNotes() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.createNote(at: CGPoint(x: 600, y: 700), scope: .window)

        engine.observe(.window(claude(.settings)))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Claude", title: "Claude")])
    }

    @Test("對話範圍與視窗範圍的便利貼同時顯示，各自標示")
    func conversationAndWindowNotesTogether() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.createNote(at: CGPoint(x: 600, y: 700), scope: .window)

        engine.observe(.window(claude(.conversation(tests, title: "補測試"))))
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [
            .conversation(title: "重構登入流程"), .window(appName: "Claude", title: "Claude"),
        ])
    }

    @Test("Claude 重開後（新的視窗身分）對話的便利貼直接回來")
    func comesBackAfterRelaunch() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: "下一步：補測試")
        let saved = try JSONDecoder().decode(NotesDocument.self, from: JSONEncoder().encode(engine.document))

        let restored = NoteEngine(screens: [laptop], document: saved)
        restored.observe(.window(claude(.conversation(refactor, title: "重構登入流程"), id: 41)))

        #expect(restored.displayedNotes.map(\.text) == ["下一步：補測試"])
        #expect(restored.unmatchedNotes.isEmpty)
    }
}

@Suite("Claude 不能貼與降級")
struct ConversationRefusalsAndFallback {
    @Test("新對話頁不能貼：告知原因，也不建立便利貼")
    func draftRefuses() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.draft)))

        #expect(engine.creationBlock == .draftConversation)
    }

    @Test("新對話頁選「改貼在這個視窗」，綁在 Claude 視窗")
    func draftCanUseTheWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.draft)))

        engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Claude", title: "Claude")])
    }

    @Test("設定開著時不能貼")
    func settingsRefuse() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.settings)))

        #expect(engine.creationBlock == .claudeSettings)
    }

    @Test("專案頁等認不出對話的頁面，降級綁在視窗，標籤寫明是降級")
    func unrecognizedFallsBackToTheWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.unrecognized)))

        #expect(engine.creationBlock == nil)
        #expect(engine.creationFallsBack)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.windowFallback(appName: "Claude", title: "Claude")])

        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.windowFallback(appName: "Claude", title: "Claude")])
    }

    @Test("在 Claude 對話上找回待找回的視窗便利貼，仍綁在視窗")
    func recoveringOnClaudeKeepsTheWindowScope() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.draft)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)
        engine.windowsClosed([WindowID(1)])

        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"), id: 2)))
        engine.confirmRecovery(of: id, on: WindowID(2))
        engine.observe(.window(claude(.conversation(tests, title: "補測試"), id: 2)))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Claude", title: "Claude")])
    }

    @Test("引擎說得出目前的焦點視窗")
    func tellsTheFocusedWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.draft, id: 7)))
        #expect(engine.focusedWindowID == WindowID(7))
        engine.observe(.unidentified)
        #expect(engine.focusedWindowID == nil)
    }

    @Test("在對話上或一般視窗上沒有阻擋也不降級")
    func normalPagesAreFine() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.conversation(refactor, title: "重構登入流程"))))
        #expect(engine.creationBlock == nil)
        #expect(!engine.creationFallsBack)
    }
}
