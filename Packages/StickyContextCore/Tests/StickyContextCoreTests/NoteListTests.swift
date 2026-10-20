import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let refactor = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-000000000001")
private let report = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-000000000002")

private let claudeFrame = CGRect(x: 0, y: 79, width: 1512, height: 870)
private let finderFrame = CGRect(x: 200, y: 300, width: 800, height: 500)

private func claude(_ page: ClaudePage) -> ObservedWindow {
    ObservedWindow(id: WindowID(1), appName: "Claude", title: "Claude", frame: claudeFrame,
                   bundleID: "com.anthropic.claudefordesktop", claudePage: page)
}

private let downloads = ObservedWindow(id: WindowID(2), appName: "Finder", title: "Downloads", frame: finderFrame,
                                       bundleID: "com.apple.finder")

/// A clock the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { now += seconds }
}

private func written(_ text: String, on window: ObservedWindow?, in engine: NoteEngine, at point: CGPoint = CGPoint(x: 400, y: 700)) -> NoteID {
    engine.observe(window.map(ContextObservation.window) ?? .unidentified)
    let id = engine.createNote(at: point)
    engine.editText(of: id, to: text)
    return id
}

@Suite("集中列表：分組")
struct ListGroups {
    @Test("依 App 與工作內容分組，標籤和便利貼上的一樣，最近改過的組在前")
    func groupedByAppAndContext() {
        let clock = FakeClock()
        let engine = NoteEngine(screens: [laptop], now: { clock.now })
        let login = written("登入要改 token", on: claude(.conversation(refactor, title: "重構登入流程")), in: engine)
        let shown = engine.displayedNotes.map(\.scopeLabel)
        clock.advance()
        let folder = written("整理下載", on: downloads, in: engine)
        let finderLabel = engine.displayedNotes.map(\.scopeLabel)
        clock.advance()
        let floating = written("隨時要看", on: nil, in: engine)
        clock.advance()
        let second = written("再加一張", on: claude(.conversation(refactor, title: "重構登入流程")), in: engine)

        let list = engine.list()

        #expect(list.groups.map(\.app) == [.app("Claude"), .floating, .app("Finder")])
        #expect(list.groups.map(\.context) == shown + [.floating] + finderLabel)
        #expect(list.groups.map { $0.notes.map(\.id) } == [[second, login], [floating], [folder]])
        #expect(list.groups[0].conversation == refactor)
        #expect(list.groups[2].conversation == nil)
        #expect(list.waiting.isEmpty && list.trash.isEmpty)
    }
}

@Suite("集中列表：網頁")
struct ListWebPages {
    @Test("網頁便利貼分在「網頁」，標籤和便利貼上的一樣，也找得到網頁標題")
    func webPageGroup() {
        let engine = NoteEngine(screens: [laptop])
        let safari = ObservedWindow(id: WindowID(3), appName: "Safari", title: "Swift Testing", frame: finderFrame,
                                    bundleID: "com.apple.Safari",
                                    browserPage: .page(address: "https://swift.org/testing", title: "Swift Testing"))
        let id = written("看完這篇", on: safari, in: engine)
        let shown = engine.displayedNotes.map(\.scopeLabel)

        let list = engine.list(searching: "testing")

        #expect(list.groups.map(\.app) == [.webPages])
        #expect(list.groups.map(\.context) == shown)
        #expect(list.groups.flatMap { $0.notes.map(\.id) } == [id])
    }
}

@Suite("集中列表：搜尋")
struct ListSearch {
    @Test("即時過濾：每個字都要出現，不分大小寫；沒有符合的組不出現；待找回與垃圾桶也一起過濾")
    func filtersEverySection() {
        let engine = NoteEngine(screens: [laptop])
        let token = written("登入要改 Token 過期", on: claude(.conversation(refactor, title: "重構登入流程")), in: engine)
        _ = written("買牛奶", on: downloads, in: engine)
        let waiting = written("token 的筆記", on: downloads, in: engine, at: CGPoint(x: 600, y: 600))
        let trashed = written("舊的 TOKEN 過期 寫法", on: nil, in: engine)
        engine.deleteNote(trashed)
        engine.windowsClosed([downloads.id])

        let list = engine.list(searching: "token  過期")

        #expect(list.groups.flatMap { $0.notes.map(\.id) } == [token])
        #expect(list.trash.map(\.id) == [trashed])
        #expect(list.waiting.isEmpty)
        #expect(engine.list(searching: "token").waiting.map(\.id) == [waiting])
        #expect(engine.list(searching: "沒有這個字").isEmpty)
    }

    @Test("也找得到工作內容的名稱")
    func findsByContextName() {
        let engine = NoteEngine(screens: [laptop])
        let login = written("改 token", on: claude(.conversation(refactor, title: "重構登入流程")), in: engine)
        _ = written("整理", on: downloads, in: engine)

        #expect(engine.list(searching: "登入流程").groups.flatMap { $0.notes.map(\.id) } == [login])
    }
}

@Suite("集中列表：Claude 對話")
struct ListConversations {
    @Test("Cowork／Code 以 session 檔的名稱顯示，已封存的標示出來")
    func archivedSession() {
        let engine = NoteEngine(screens: [laptop])
        _ = written("寫完第二章", on: claude(.conversation(report, title: "舊名稱")), in: engine)

        let list = engine.list { ref in ref == report ? ClaudeSessionInfo(title: "整理報告", isArchived: true) : nil }

        #expect(list.groups.map(\.context) == [.conversation(title: "整理報告")])
        #expect(list.groups.map(\.isArchived) == [true])
        #expect(list.groups.map(\.conversation) == [report])
    }

    @Test("「前往」的網址：Chat、Cowork、Code 各自的路徑；終端機裡的 Claude Code 沒有")
    func deepLinks() {
        #expect(refactor.deepLink?.absoluteString == "claude://claude.ai/chat/00000000-0000-4000-8000-000000000001")
        #expect(report.deepLink?.absoluteString == "claude://claude.ai/cowork/local_00000000-0000-4000-8000-000000000002")
        #expect(ConversationRef(kind: .code, id: "local_abc").deepLink?.absoluteString == "claude://claude.ai/epitaxy/local_abc")
        #expect(ConversationRef(kind: .cli, id: "abc").deepLink == nil)
    }

    @Test("終端機裡的 Claude Code session 自成一組，不算在 Claude App 裡")
    func terminalSessionsGroupApart() {
        let engine = NoteEngine(screens: [laptop])
        let cli = ConversationRef(kind: .cli, id: "5f0c")
        let terminal = ObservedWindow(id: WindowID(4), appName: "Terminal", title: "zsh", frame: finderFrame,
                                      bundleID: "com.apple.Terminal", claudePage: .conversation(cli, title: "修測試"))
        _ = written("跑完整套", on: terminal, in: engine)

        let list = engine.list()

        #expect(list.groups.map(\.app) == [.claudeCodeTerminal])
        #expect(list.groups.map(\.context) == [.conversation(title: "修測試")])
    }
}

@Suite("集中列表：待找回與垃圾桶")
struct ListWaitingAndTrash {
    @Test("待找回的便利貼列在待找回區，寫出原因與原本的視窗，不在分組裡")
    func waitingSection() {
        let engine = NoteEngine(screens: [laptop])
        let id = written("整理下載", on: downloads, in: engine)
        engine.windowsClosed([downloads.id])

        let list = engine.list()

        #expect(list.groups.isEmpty)
        #expect(list.waiting.map(\.id) == [id])
        #expect(list.waiting.map(\.waitingReason) == [.windowClosed])
        #expect(list.waiting.map(\.context) == [.window(appName: "Finder", title: "Downloads")])
    }

    @Test("改成浮動：回到原本視窗上的位置，一直顯示")
    func waitingToFloating() {
        let engine = NoteEngine(screens: [laptop])
        let id = written("整理下載", on: downloads, in: engine, at: CGPoint(x: 300, y: 700))
        let frame = engine.displayedNotes[0].frame
        engine.windowsClosed([downloads.id])
        engine.observe(.unidentified)

        engine.makeFloating(id)

        #expect(engine.displayedNotes.map(\.id) == [id])
        #expect(engine.displayedNotes.map(\.frame) == [frame])
        #expect(engine.displayedNotes.map(\.scopeLabel) == [.floating])
        #expect(engine.list().waiting.isEmpty)
    }

    @Test("找不到資料夾的便利貼改成浮動：出現在螢幕右上角")
    func missingFolderToFloating() {
        var exists = true
        let engine = NoteEngine(screens: [laptop], pathExists: { _ in exists })
        var folder = downloads
        folder.documentPath = "/Users/me/Downloads/"
        let id = written("整理下載", on: folder, in: engine)
        engine.observe(.unidentified)
        exists = false
        #expect(engine.list().waiting.map(\.id) == [id])

        engine.makeFloating(id)

        let shown = engine.displayedNotes
        #expect(shown.map(\.id) == [id])
        // The same top-right spot as on a window: 16 pt from the right, 40 pt below the top.
        #expect(shown.map(\.frame) == [CGRect(x: 1512 - 16 - 240, y: 79 + 870 - 40 - 180, width: 240, height: 180)])
        #expect(engine.list().waiting.isEmpty)
    }

    @Test("在列表裡（Hintlet 在前景）重新綁定：綁到剛才的工作內容；按鈕先說出會綁到哪")
    func rebindFromTheList() {
        let engine = NoteEngine(screens: [laptop])
        let id = written("整理下載", on: downloads, in: engine)
        engine.windowsClosed([downloads.id])
        let chat = claude(.conversation(refactor, title: "重構登入流程"))
        engine.observe(.window(chat))
        engine.observe(.ownApp)

        #expect(engine.rebindContext == .conversation(title: "重構登入流程"))
        #expect(engine.canRebindToCurrentContext(id))
        engine.rebindToCurrentContext(id)

        #expect(engine.list().waiting.isEmpty)
        #expect(engine.list().groups.map(\.context) == [.conversation(title: "重構登入流程")])
    }

    @Test("沒有可綁的工作內容時，重新綁定沒有對象")
    func nothingToRebindTo() {
        let engine = NoteEngine(screens: [laptop])
        #expect(engine.rebindContext == nil)
        engine.observe(.window(claude(.draft)))
        #expect(engine.rebindContext == nil)
    }

    @Test("垃圾桶最近刪的在前，帶著原本的範圍")
    func trashSection() {
        let clock = FakeClock()
        let engine = NoteEngine(screens: [laptop], now: { clock.now })
        let first = written("先刪", on: downloads, in: engine)
        let second = written("後刪", on: nil, in: engine)
        engine.deleteNote(first)
        clock.advance()
        engine.deleteNote(second)

        let list = engine.list()

        #expect(list.trash.map(\.id) == [second, first])
        #expect(list.trash.map(\.context) == [.floating, .window(appName: "Finder", title: "Downloads")])
        #expect(list.trash.map(\.deletedAt) == [clock.now, clock.now - 1])
        #expect(list.groups.isEmpty)
    }
}
