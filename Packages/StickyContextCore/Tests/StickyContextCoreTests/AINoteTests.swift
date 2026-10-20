import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let login = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-0000000000a1")
private let deploy = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-0000000000a2")
private let chat = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-0000000000a3")

private func claude(_ ref: ConversationRef?, title: String = "對話") -> ObservedWindow {
    ObservedWindow(id: WindowID(1), appName: "Claude", title: "Claude", frame: CGRect(x: 0, y: 79, width: 1512, height: 870),
                   bundleID: "com.anthropic.claudefordesktop",
                   claudePage: ref.map { .conversation($0, title: title) } ?? .unrecognized)
}

private let finder = ObservedWindow(id: WindowID(2), appName: "Finder", title: "Downloads",
                                    frame: CGRect(x: 100, y: 200, width: 800, height: 600), bundleID: "com.apple.finder")

private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func summary(_ doing: String = "重構登入", at date: Date = noon) -> AISummary {
    AISummary(doing: doing, stoppedAt: "測試失敗", next: "修好測試", coverage: .complete, backend: .onDevice, updatedAt: date)
}

/// An engine with AI notes available for Code and Cowork, on the `login` conversation.
private func engineOnLogin() -> NoteEngine {
    let engine = NoteEngine(screens: [laptop])
    engine.aiConversationKinds = [.code, .cowork]
    engine.observe(.window(claude(login)))
    return engine
}

@Suite("AI 便利貼：何時可以變成 AI 便利貼")
struct OfferingAINotes {
    @Test("Code 對話上剛貼下的空白便利貼提供「讓 AI 記錄脈絡？」")
    func offeredOnANewConversationNote() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.canMakeAINote(id))
        #expect(engine.displayedNotes.first?.offersAI == true)
    }

    @Test("一開始打字，下方的提議就消失；但仍可從選單轉成 AI 便利貼")
    func goneOnceTyped() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.editText(of: id, to: "我")

        #expect(engine.canMakeAINote(id))
        #expect(engine.displayedNotes.first?.offersAI == false)
    }

    @Test("AI 便利貼轉回一般便利貼時，內容就是它現在顯示的；還沒寫出摘要時，原本寫的字回來")
    func typedNoteRoundTrip() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: "記得問部署時間")
        engine.setColor(of: id, to: .green)

        engine.makeAINote(id)
        #expect(engine.displayedNotes.first?.text == "")
        engine.applySummary(summary(), to: id)
        engine.makeOrdinaryNote(id) { $0.lines.joined(separator: "，") }

        let note = try! #require(engine.displayedNotes.first)
        #expect(note.ai == nil)
        #expect(note.color == .green)
        #expect(note.text == summary().lines.joined(separator: "，"))
        engine.editText(of: id, to: "改得動")
        #expect(engine.displayedNotes.first?.text == "改得動")

        let other = engine.createNote(at: CGPoint(x: 600, y: 700))
        engine.editText(of: other, to: "還沒摘要")
        engine.deleteNote(id)
        engine.makeAINote(other)
        engine.makeOrdinaryNote(other) { $0.lines.joined() }
        #expect(engine.displayedNotes.first { $0.id == other }?.text == "還沒摘要")
    }

    @Test("打字時提議消失，刪光字又出現")
    func offerFollowsEmptiness() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.editText(of: id, to: "我")
        #expect(engine.displayedNotes.first?.offersAI == false)
        engine.editText(of: id, to: "")

        #expect(engine.displayedNotes.first?.offersAI == true)
        #expect(engine.displayedNotes.first?.canBecomeAI == true)
        #expect(engine.canMakeAINote(id))
    }

    @Test("不是剛貼下的空白對話便利貼（例如上次留下的）不出現選項，只能從選單轉")
    func notOfferedOnAnOlderEmptyNote() {
        let earlier = engineOnLogin()
        _ = earlier.createNote(at: CGPoint(x: 300, y: 700))
        let engine = NoteEngine(screens: [laptop], document: earlier.document)
        engine.aiConversationKinds = [.code, .cowork]
        engine.observe(.window(claude(login)))

        #expect(engine.displayedNotes.first?.offersAI == false)
        #expect(engine.displayedNotes.first?.canBecomeAI == true)
    }

    @Test("只在對話範圍出現：視窗與浮動便利貼沒有選項")
    func onlyOnConversations() {
        let engine = engineOnLogin()
        engine.observe(.window(finder))
        let onWindow = engine.createNote(at: CGPoint(x: 300, y: 500))
        engine.observe(.unidentified)
        let floating = engine.createNote(at: CGPoint(x: 300, y: 500))

        #expect(!engine.canMakeAINote(onWindow))
        #expect(!engine.canMakeAINote(floating))
    }

    @Test("系統不支援 AI 時（沒有可用的對話種類）完全不出現")
    func hiddenWhenUnsupported() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(claude(login)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(!engine.canMakeAINote(id))
        #expect(engine.displayedNotes.first?.offersAI == false)
    }

    @Test("沒開放的對話種類不提供")
    func notOnOtherKinds() {
        let engine = engineOnLogin()
        engine.observe(.window(claude(chat)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(!engine.canMakeAINote(id))
    }

    @Test("Chat 對話只在使用者把便利貼轉成 AI 便利貼後才算開啟記錄，停用 AI 就關閉")
    func chatTurnedOnByTheUser() {
        let engine = engineOnLogin()
        engine.aiConversationKinds = [.code, .cowork, .chat]
        engine.observe(.window(claude(chat)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        #expect(engine.canMakeAINote(id))
        #expect(!engine.hasAINote(on: chat))

        engine.makeAINote(id)
        #expect(engine.hasAINote(on: chat))

        engine.deleteNote(id)
        #expect(!engine.hasAINote(on: chat))
    }

    @Test("AI 便利貼丟進垃圾桶，對話就不再記錄")
    func trashedAINoteTurnsItOff() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)

        engine.deleteNote(id)

        #expect(!engine.hasAINote(on: login))
    }

    @Test("對話已有 AI 便利貼時，新的便利貼不再出現選項")
    func onePerConversation() {
        let engine = engineOnLogin()
        let first = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(first)

        let second = engine.createNote(at: CGPoint(x: 600, y: 700))
        engine.makeAINote(second)

        #expect(!engine.canMakeAINote(second))
        #expect(engine.displayedNotes.filter { $0.ai != nil }.map(\.id) == [first])
    }

    @Test("AI 便利貼放進垃圾桶後，這個對話又可以有新的 AI 便利貼")
    func trashedAINoteFreesTheConversation() {
        let engine = engineOnLogin()
        let first = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(first)
        engine.deleteNote(first)

        let second = engine.createNote(at: CGPoint(x: 600, y: 700))

        #expect(engine.canMakeAINote(second))
    }

    @Test("從垃圾桶復原 AI 便利貼時對話已有另一張，復原的那張變回一般便利貼")
    func restoringKeepsOnePerConversation() {
        let engine = engineOnLogin()
        let first = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(first)
        _ = engine.takeSummaryRequests()
        engine.applySummary(summary("第一張"), to: first)
        engine.deleteNote(first)
        let second = engine.createNote(at: CGPoint(x: 600, y: 700))
        engine.makeAINote(second)

        engine.restoreNote(first)

        #expect(engine.displayedNotes.filter { $0.ai != nil }.map(\.id) == [second])
        #expect(engine.displayedNotes.contains { $0.id == first && $0.ai == nil && !$0.text.isEmpty })
    }

    @Test("匯入的備份在已有 AI 便利貼的對話上又帶一張：匯入的那張變回一般便利貼")
    func importingKeepsOnePerConversation() {
        let elsewhere = engineOnLogin()
        let imported = elsewhere.createNote(at: CGPoint(x: 300, y: 700))
        elsewhere.makeAINote(imported)
        elsewhere.applySummary(summary("另一台的"), to: imported)
        let engine = engineOnLogin()
        let here = engine.createNote(at: CGPoint(x: 600, y: 700))
        engine.makeAINote(here)

        engine.importNotes(elsewhere.document)

        #expect(engine.displayedNotes.filter { $0.ai != nil }.map(\.id) == [here])
        #expect(engine.displayedNotes.contains { $0.id == imported && $0.ai == nil && !$0.text.isEmpty })
    }
}

@Suite("AI 便利貼：唯讀、顏色與停用")
struct AINoteBehaviour {
    @Test("變成 AI 便利貼後預設粉霧，等待第一次摘要")
    func mistAndWaiting() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.makeAINote(id)

        let note = try! #require(engine.displayedNotes.first)
        #expect(note.color == .mist)
        #expect(note.ai == DisplayedAI(summary: nil, status: .idle))
        #expect(engine.takeSummaryRequests() == [SummaryRequest(noteID: id, conversation: login, isManual: true)])
    }

    @Test("AI 便利貼唯讀：不能打字、不能換顏色、不會因為空白被丟掉")
    func readOnly() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)

        engine.editText(of: id, to: "手動改")
        engine.setColor(of: id, to: .pink)

        #expect(engine.displayedNotes.first?.text == "")
        #expect(engine.displayedNotes.first?.color == .mist)
        #expect(!engine.discardIfEmpty(id))
        #expect(engine.displayedNotes.count == 1)
    }

    @Test("摘要寫進 AI 便利貼，顯示三行與更新時間；文字也可被列表搜尋")
    func summaryShows() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)

        engine.applySummary(summary(), to: id)

        #expect(engine.displayedNotes.first?.ai?.summary == summary())
        #expect(engine.list(searching: "修好測試").groups.flatMap(\.notes).map(\.id) == [id])
    }

    @Test("AI 從不改動手寫便利貼")
    func neverTouchesHandwrittenNotes() {
        let engine = engineOnLogin()
        let handwritten = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: handwritten, to: "我自己寫的")

        engine.applySummary(summary(), to: handwritten)
        engine.summaryStarted(handwritten)
        engine.summaryFailed(handwritten)

        let note = try! #require(engine.displayedNotes.first)
        #expect(note.text == "我自己寫的")
        #expect(note.ai == nil)
        #expect(note.color == .yellow)
    }

    @Test("AI 便利貼只能留在自己的對話上：範圍選單只有目前的對話")
    func staysOnItsConversation() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)

        engine.changeScope(of: id, to: .floating)
        engine.makeFloating(id)

        #expect(engine.scopeOptions(for: id).map(\.scope) == [.conversation])
        #expect(engine.displayedNotes.first?.scopeLabel == .conversation(title: "對話"))
    }

    @Test("更新中與更新失敗會顯示；失敗時保留上一次的摘要")
    func updatingAndFailing() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        engine.applySummary(summary(), to: id)

        engine.summaryStarted(id)
        #expect(engine.displayedNotes.first?.ai?.status == .updating)

        engine.summaryFailed(id)
        #expect(engine.displayedNotes.first?.ai == DisplayedAI(summary: summary(), status: .failed(nil)))
    }
}

@Suite("AI 便利貼：切走時更新")
struct RefreshingOnSwitchingAway {
    @Test("切到別的對話時，剛離開的對話的 AI 便利貼排入更新")
    func switchingConversations() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        _ = engine.takeSummaryRequests()

        engine.observe(.window(claude(deploy)))

        #expect(engine.takeSummaryRequests() == [SummaryRequest(noteID: id, conversation: login, isManual: false)])
        #expect(engine.takeSummaryRequests().isEmpty)
    }

    @Test("切到別的 App 也算切走；切到 Hintlet 自己不算")
    func switchingApps() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        _ = engine.takeSummaryRequests()

        engine.observe(.ownApp)
        #expect(engine.takeSummaryRequests().isEmpty)

        engine.observe(.window(finder))
        #expect(engine.takeSummaryRequests().map(\.noteID) == [id])
    }

    @Test("同一個對話的觀測（例如標題變了）不觸發更新")
    func stayingDoesNothing() {
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        _ = engine.takeSummaryRequests()

        engine.observe(.window(claude(login, title: "新標題")))

        #expect(engine.takeSummaryRequests().isEmpty)
    }

    @Test("離開沒有 AI 便利貼的對話不排入任何更新；手寫便利貼不受影響")
    func onlyAINotes() {
        let engine = engineOnLogin()
        engine.editText(of: engine.createNote(at: CGPoint(x: 300, y: 700)), to: "手寫")

        engine.observe(.window(claude(deploy)))

        #expect(engine.takeSummaryRequests().isEmpty)
    }

    @Test("手動更新排入一次手動請求；手寫便利貼不會")
    func manualRefresh() {
        let engine = engineOnLogin()
        let ai = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(ai)
        _ = engine.takeSummaryRequests()
        let handwritten = engine.createNote(at: CGPoint(x: 600, y: 700))

        engine.requestSummary(ai)
        engine.requestSummary(handwritten)

        #expect(engine.takeSummaryRequests() == [SummaryRequest(noteID: ai, conversation: login, isManual: true)])
    }
}

@Suite("AI 便利貼：存檔")
struct SavingAINotes {
    @Test("AI 便利貼與摘要存檔後讀回，仍是 AI 便利貼")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StickyContextTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = engineOnLogin()
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        engine.applySummary(summary(), to: id)

        try NoteStore(directory: folder).save(engine.document)
        let restored = NoteEngine(screens: [laptop], document: try #require(try NoteStore(directory: folder).load()))
        restored.aiConversationKinds = [.code, .cowork]
        restored.observe(.window(claude(login)))

        #expect(restored.displayedNotes.first?.ai?.summary == summary())
        #expect(restored.displayedNotes.first?.color == .mist)
    }

    @Test("版本 5 的檔案（還沒有 AI 便利貼）直接讀入，便利貼都是手寫的")
    func readsVersionFive() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StickyContextTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v5 = #"""
        {"formatVersion": 5, "notes": [{"id": "55555555-5555-5555-5555-555555555555", "text": "手寫", "createdAt": 0,
          "updatedAt": 0, "binding": {"conversation": {"ref": {"kind": "code", "id": "local_00000000-0000-4000-8000-0000000000a1"},
          "title": "對話", "anchor": {"size": [240, 180], "fromRight": true, "fromTop": true, "horizontalInset": 16, "verticalInset": 40}}}}]}
        """#
        try Data(v5.utf8).write(to: folder.appendingPathComponent("notes.json"))

        let engine = NoteEngine(screens: [laptop], document: try #require(try NoteStore(directory: folder).load()))
        engine.observe(.window(claude(login)))

        #expect(engine.displayedNotes.map(\.text) == ["手寫"])
        #expect(engine.displayedNotes.first?.ai == nil)
        #expect(NotesDocument.currentVersion == 6)
    }
}
