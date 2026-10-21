import Foundation
import Testing
import HintletCore

/// Seam: what is running on a terminal tab's tty, plus Claude Code's `~/.claude/sessions/<pid>.json` files
/// → which Claude Code conversation the tab shows (spike 06).
private let sessionID = "11111111-2222-4333-8444-555555555555"
private let started = Date(timeIntervalSince1970: 1_792_290_000)

/// The tab's shell, its process group in the background while Claude Code runs in front.
private let shell = TTYProcess(pid: 100, processGroup: 100, startedAt: started.addingTimeInterval(-60), name: "zsh")
private let claude = TTYProcess(pid: 200, processGroup: 200, startedAt: started, name: "claude")
private let record = ClaudeCodeSessionRecord(pid: 200, sessionID: sessionID, startedAt: started.addingTimeInterval(0.4),
                                             entrypoint: "cli", name: "補測試")

@Suite("終端機分頁裡的 Claude Code 對話")
struct ClaudeCodeInTerminal {
    @Test("前景是 claude、有它的 session 檔：綁在那個 session ID，標題取 session 名稱")
    func foregroundClaude() {
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 200, processes: [shell, claude], records: [record])
            == .conversation(ConversationRef(kind: .cli, id: sessionID), title: "補測試"))
    }

    @Test("Claude Code 結束、或按 Ctrl-Z 放到背景，前景回到 shell：不是對話")
    func shellInFront() {
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 100, processes: [shell, claude], records: [record]) == nil)
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 100, processes: [shell], records: []) == nil)
    }

    @Test("當掉留下的 session 檔、PID 已被別的程序重用：不認")
    func staleRecordWithReusedPID() {
        let reused = TTYProcess(pid: 200, processGroup: 200, startedAt: started.addingTimeInterval(3600), name: "claude")
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 200, processes: [shell, reused], records: [record]) == nil)
    }

    @Test("前景程序有 session 檔但不是終端機啟動的（Claude App 自己的 Code session）：不認")
    func notFromTheCLI() {
        var desktop = record
        desktop.entrypoint = "claude-desktop"
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 200, processes: [shell, claude], records: [desktop]) == nil)
    }

    @Test("session ID 格式不符：降級不猜測")
    func unexpectedSessionID() {
        var odd = record
        odd.sessionID = "not-a-uuid"
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 200, processes: [shell, claude], records: [odd]) == nil)
    }

    @Test("前景同時有兩個 Claude Code（例如管線裡）：分不出是哪個，不認")
    func twoInFront() {
        let other = TTYProcess(pid: 201, processGroup: 200, startedAt: started, name: "claude")
        var second = record
        second.pid = 201
        second.sessionID = "99999999-2222-4333-8444-555555555555"
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 200, processes: [shell, claude, other], records: [record, second]) == nil)
    }

    @Test("同一個分頁裡先後啟動兩次：認的是現在在跑的那一次")
    func relaunchedInTheSameTab() {
        let later = TTYProcess(pid: 300, processGroup: 300, startedAt: started.addingTimeInterval(120), name: "claude")
        let laterRecord = ClaudeCodeSessionRecord(pid: 300, sessionID: "22222222-2222-4333-8444-555555555555",
                                                  startedAt: started.addingTimeInterval(120.5), entrypoint: "cli", name: nil)
        // The first run was killed and left its file behind.
        #expect(ClaudeCodeTerminal.page(foregroundGroup: 300, processes: [shell, later], records: [record, laterRecord])
            == .conversation(ConversationRef(kind: .cli, id: "22222222-2222-4333-8444-555555555555"), title: ""))
    }

    @Test("讀 Claude Code 寫的 session 檔")
    func readsSessionFile() throws {
        let json = #"""
        {"pid":57454,"sessionId":"11111111-2222-4333-8444-555555555555","cwd":"/Users/me/dev/Note",
         "startedAt":1792290484851,"procStart":"Sun Oct 18 02:28:04 2026","version":"2.1.220","kind":"interactive",
         "entrypoint":"cli","name":"Note-24","status":"idle"}
        """#
        #expect(try ClaudeCodeSessionRecord(json: Data(json.utf8)) == ClaudeCodeSessionRecord(
            pid: 57454, sessionID: sessionID, startedAt: Date(timeIntervalSince1970: 1_792_290_484.851),
            entrypoint: "cli", name: "Note-24"))
    }
}

private func terminal(_ page: ClaudePage?, id: UInt64, title: String = "jyp — claude — 80×24") -> ObservedWindow {
    ObservedWindow(id: WindowID(id), appName: "Terminal", title: title, frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                   bundleID: "com.apple.Terminal", documentPath: "/Users/me/dev/Note/", claudePage: page)
}

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

@Suite("綁在終端機裡的 Claude Code 對話")
struct BindingToTerminalSessions {
    private let session = ClaudePage.conversation(ConversationRef(kind: .cli, id: sessionID), title: "補測試")

    @Test("分頁在跑 Claude Code 時，便利貼綁在 session（比資料夾細）；回到 shell 就收起")
    func bindsToTheSession() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal(session, id: 1)))
        engine.createNote(at: CGPoint(x: 300, y: 500))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.conversation(title: "補測試")])
        engine.observe(.window(terminal(nil, id: 1, title: "jyp — -zsh — 80×24")))
        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("Hintlet 重開、在另一個分頁 resume 同一個 session：便利貼回來")
    func comesBackOnResume() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HintletTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal(session, id: 1)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 500))
        engine.editText(of: id, to: "下一步：跑測試")
        try NoteStore(directory: folder).save(engine.document)

        let restored = NoteEngine(screens: [laptop], document: try #require(try NoteStore(directory: folder).load()))
        restored.observe(.window(terminal(session, id: 7)))

        #expect(restored.displayedNotes.map(\.text) == ["下一步：跑測試"])
    }

    @Test("終端機的 session 結束不代表刪除：不列入 Claude 刪除 session 的檢查，便利貼不進垃圾桶")
    func notWatchedForDeletion() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal(session, id: 1)))
        engine.createNote(at: CGPoint(x: 300, y: 500))

        #expect(engine.sessionsToWatch.isEmpty)
    }

    @Test("寫入的檔案標上新版本，舊版 Hintlet 不會誤讀不認得的對話種類")
    func newFormatVersion() throws {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(terminal(session, id: 1)))
        engine.createNote(at: CGPoint(x: 300, y: 500))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.document)) as? [String: Any]

        #expect((object?["formatVersion"] as? Int ?? 0) >= 5)
    }
}
