import CoreGraphics
import Foundation
import Testing
import HintletCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let refactor = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-000000000001")
private let tests = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-000000000002")
private let claudeFrame = CGRect(x: 100, y: 200, width: 1000, height: 700)

private func claude(_ page: ClaudePage?, id: UInt64 = 1) -> ObservedWindow {
    ObservedWindow(id: WindowID(id), appName: "Claude", title: "Claude", frame: claudeFrame,
                   bundleID: "com.anthropic.claudefordesktop", claudePage: page)
}

private let onRefactor = claude(.conversation(refactor, title: "重構登入流程"))
private let onTests = claude(.conversation(tests, title: "補測試"))
private let documents = ObservedWindow(id: WindowID(2), appName: "Finder", title: "Documents",
                                       frame: CGRect(x: 200, y: 150, width: 800, height: 600),
                                       bundleID: "com.apple.finder", documentPath: "/Users/me/Documents/")
private let terminal = ObservedWindow(id: WindowID(3), appName: "Terminal", title: "zsh",
                                      frame: CGRect(x: 300, y: 300, width: 600, height: 400), bundleID: "com.apple.Terminal")

private func scopes(_ engine: NoteEngine, _ id: NoteID) -> [BindingScope] {
    engine.scopeOptions(for: id).map(\.scope)
}

private func current(_ engine: NoteEngine, _ id: NoteID) -> BindingScope? {
    engine.scopeOptions(for: id).first(where: \.isCurrent)?.scope
}

@Suite("範圍選單")
struct ScopeMenu {
    @Test("Claude 對話上的便利貼可選對話、整個視窗或浮動，目前是對話")
    func conversationOptions() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.scopeOptions(for: id) == [
            ScopeOption(scope: .conversation, label: .conversation(title: "重構登入流程"), isCurrent: true),
            ScopeOption(scope: .window, label: .window(appName: "Claude", title: "Claude"), isCurrent: false),
            ScopeOption(scope: .floating, label: .floating, isCurrent: false),
        ])
    }

    @Test("非 Claude 視窗沒有「對話」；有資料夾時可選資料夾")
    func onlyWhatTheWindowOffers() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(documents))
        let inFolder = engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(scopes(engine, inFolder) == [.document, .window, .floating])
        #expect(current(engine, inFolder) == .document)

        engine.observe(.window(terminal))
        let onWindow = engine.createNote(at: CGPoint(x: 400, y: 650))
        #expect(scopes(engine, onWindow) == [.window, .floating])
        #expect(current(engine, onWindow) == .window)
    }

    @Test("沒有可辨識的視窗時，浮動便利貼只能是浮動")
    func floatingWithoutAWindow() {
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(scopes(engine, id) == [.floating])
        #expect(current(engine, id) == .floating)
        #expect(!engine.canRebindToCurrentContext(id))
    }

    @Test("沒顯示的便利貼沒有選項")
    func noteNotShowingHasNoOptions() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.observe(.window(onTests))

        #expect(engine.scopeOptions(for: id).isEmpty)
    }
}

@Suite("變更範圍")
struct ChangingScope {
    @Test("對話改成整個視窗：在同一位置，切到別的對話也還在")
    func conversationToWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        let frame = engine.displayedNotes[0].frame

        engine.changeScope(of: id, to: .window)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Claude", title: "Claude")])
        #expect(engine.displayedNotes.map(\.frame) == [frame])
        engine.observe(.window(onTests))
        #expect(engine.displayedNotes.map(\.frame) == [frame])
    }

    @Test("整個視窗改成對話：只在目前的對話出現")
    func windowToConversation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)

        engine.changeScope(of: id, to: .conversation)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "重構登入流程")])
        engine.observe(.window(onTests))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("資料夾改成整個視窗：別的視窗打開同一個資料夾就看不到")
    func documentToWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(documents))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.changeScope(of: id, to: .window)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Finder", title: "Documents")])
        var other = documents
        other.id = WindowID(9)
        engine.observe(.window(other))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("綁定改成浮動：留在原處，切到任何地方都看得到")
    func boundToFloating() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        let frame = engine.displayedNotes[0].frame

        engine.changeScope(of: id, to: .floating)

        #expect(engine.displayedNotes == [DisplayedNote(id: id, frame: frame, text: "", scopeLabel: .floating)])
        engine.observe(.window(terminal))
        #expect(engine.displayedNotes.map(\.frame) == [frame])
        engine.observe(.unidentified)
        #expect(engine.displayedNotes.map(\.frame) == [frame])
    }

    @Test("浮動改成綁定：在視窗上的留在原處，綁在目前視窗")
    func floatingOverTheWindowToBound() {
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))
        let frame = engine.displayedNotes[0].frame
        engine.observe(.window(terminal))

        engine.changeScope(of: id, to: .window)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Terminal", title: "zsh")])
        #expect(engine.displayedNotes.map(\.frame) == [frame])
        #expect(engine.displayedNotes.map(\.windowID) == [terminal.id])
        engine.observe(.window(documents))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("浮動改成綁定：離視窗很遠的移到視窗右上角")
    func floatingFarAwayMovesOntoTheWindow() {
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 1300, y: 300))
        engine.observe(.window(terminal))

        engine.changeScope(of: id, to: .window)

        let frame = engine.displayedNotes[0].frame
        #expect(terminal.frame.contains(frame))
        #expect(frame.maxX > terminal.frame.midX && frame.maxY > terminal.frame.midY)
    }

    @Test("認不出對話而降級的便利貼，改成整個視窗後不再標示降級")
    func fallbackNoteToWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(.unrecognized)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(engine.scopeOptions(for: id).first(where: \.isCurrent)?.label == .windowFallback(appName: "Claude", title: "Claude"))
        #expect(scopes(engine, id) == [.window, .floating])

        engine.changeScope(of: id, to: .floating)
        engine.changeScope(of: id, to: .window)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Claude", title: "Claude")])
    }

    @Test("整個視窗改成資料夾：任何打開這個資料夾的視窗都看得到")
    func windowToDocument() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(documents))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)

        engine.changeScope(of: id, to: .document)

        var other = documents
        other.id = WindowID(9)
        engine.observe(.window(other))
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.document(appName: "Finder", name: "Documents", isFolder: true)])
    }

    @Test("視窗沒有提供的範圍不會套用")
    func unavailableScopeIsIgnored() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal))
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))

        engine.changeScope(of: id, to: .conversation)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Terminal", title: "zsh")])
    }

    @Test("變更後的範圍在重新啟動後保留")
    func survivesRelaunch() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.changeScope(of: id, to: .floating)

        let relaunched = NoteEngine(screens: [laptop], document: engine.document)

        #expect(relaunched.displayedNotes.map(\.scopeLabel) == [.floating])
    }
}

@Suite("重新綁定到目前內容")
struct RebindingToCurrentContext {
    @Test("浮動便利貼綁到目前內容：Claude 上綁在對話")
    func floatingToTheConversation() {
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))
        engine.observe(.window(onRefactor))
        #expect(engine.canRebindToCurrentContext(id))

        engine.rebindToCurrentContext(id)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "重構登入流程")])
        engine.observe(.window(onTests))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("視窗範圍的便利貼重新綁定：改用最細的範圍")
    func windowNoteToTheFinestScope() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(documents))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700), scope: .window)

        engine.rebindToCurrentContext(id)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.document(appName: "Finder", name: "Documents", isFolder: true)])
    }

    @Test("已經綁在目前內容上就不需要重新綁定")
    func alreadyBoundHere() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(!engine.canRebindToCurrentContext(id))
    }

    @Test("待找回的便利貼綁到目前視窗：回到它在視窗上的相對位置")
    func unmatchedNoteToTheFocusedWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal))
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))
        engine.editText(of: id, to: "記得重跑")
        let offset = CGPoint(x: engine.displayedNotes[0].frame.minX - terminal.frame.minX,
                             y: engine.displayedNotes[0].frame.maxY - terminal.frame.maxY)
        engine.windowsClosed([terminal.id])
        #expect(engine.unmatchedNotes.map(\.id) == [id])

        var reopened = terminal
        reopened.id = WindowID(7)
        reopened.title = "別的標題"
        engine.observe(.window(reopened))
        #expect(engine.canRebindToCurrentContext(id))
        engine.rebindToCurrentContext(id)

        #expect(engine.unmatchedNotes.isEmpty)
        let frame = engine.displayedNotes[0].frame
        #expect(engine.displayedNotes.map(\.windowID) == [reopened.id])
        #expect(CGPoint(x: frame.minX - reopened.frame.minX, y: frame.maxY - reopened.frame.maxY) == offset)
    }

    @Test("另一個對話的便利貼重新綁定到目前的對話")
    func noteOfAnotherConversation() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(onRefactor))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.observe(.window(onTests))

        engine.rebindToCurrentContext(id)

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "補測試")])
    }

    @Test("視窗最小化時不能重新綁定")
    func notOntoAMinimizedWindow() {
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))
        var minimized = terminal
        minimized.isMinimized = true
        engine.observe(.window(minimized))

        #expect(!engine.canRebindToCurrentContext(id))
        #expect(scopes(engine, id) == [.floating])
    }

    @Test("新對話草稿與設定頁上不能重新綁定，但可以從選單選整個視窗")
    func notOntoADraftOrSettings() {
        for page in [ClaudePage.draft, .settings] {
            let engine = NoteEngine(screens: [laptop])
            let id = engine.createNote(at: CGPoint(x: 400, y: 600))
            engine.observe(.window(claude(page)))

            #expect(!engine.canRebindToCurrentContext(id))
            engine.rebindToCurrentContext(id)
            #expect(engine.displayedNotes.map(\.scopeLabel) == [.floating])
            #expect(scopes(engine, id) == [.window, .floating])
        }
    }

    @Test("垃圾桶裡的便利貼不能重新綁定")
    func notFromTheTrash() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal))
        let id = engine.createNote(at: CGPoint(x: 400, y: 600))
        engine.deleteNote(id)

        #expect(!engine.canRebindToCurrentContext(id))
    }
}
