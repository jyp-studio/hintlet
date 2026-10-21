import Foundation
import Testing
import HintletCore

private let index = CodexThreadIndex(jsonl: Data("""
{"id":"01a15c92-77e9-76c1-ba20-f9920fbad1d5","thread_name":"Find grill-me skills","updated_at":"2026-10-21T03:48:29Z"}
{"id":"01a159d7-9dde-7db0-8fd1-efee16ce7ea3","thread_name":"Guardian review","updated_at":"2026-10-20T15:04:25Z"}
{"id":"01a159dd-3bfc-7703-8534-a8e2c46ae8f2","thread_name":"Guardian review","updated_at":"2026-10-20T15:10:33Z"}
{"id":"01a1595d-1111-7000-8000-000000000001","thread_name":"舊名字","updated_at":"2026-10-19T10:00:00Z"}
{"id":"01a1595d-1111-7000-8000-000000000001","thread_name":"製作 App 節奏宣傳片","updated_at":"2026-10-20T14:59:04Z"}
not json
""".utf8))

@Suite("Codex 對話：標題唯一才綁定")
struct CodexThreadIdentification {
    @Test("標題只對到一個 thread：綁在那個 thread 的 ID")
    func uniqueTitleBinds() {
        #expect(CodexThreads.page(title: "Find grill-me skills", index: index)
            == .conversation(ConversationRef(kind: .codex, id: "01a15c92-77e9-76c1-ba20-f9920fbad1d5"), title: "Find grill-me skills"))
    }

    @Test("標題有好幾個 thread 同名：分不出來，退回視窗")
    func duplicateTitleFallsBack() {
        #expect(CodexThreads.page(title: "Guardian review", index: index) == .unrecognized)
    }

    @Test("沒有 thread 叫這個名字（新對話、設定）：一般視窗")
    func unknownTitleIsAPlainWindow() {
        #expect(CodexThreads.page(title: "New thread", index: index) == nil)
        #expect(CodexThreads.page(title: "  ", index: index) == nil)
        #expect(CodexThreads.page(title: nil, index: index) == nil)
    }

    @Test("改過名的 thread 用最新的名字，舊名字不再對到")
    func renamedThreadUsesItsLatestName() {
        #expect(CodexThreads.page(title: "製作 App 節奏宣傳片", index: index)
            == .conversation(ConversationRef(kind: .codex, id: "01a1595d-1111-7000-8000-000000000001"), title: "製作 App 節奏宣傳片"))
        #expect(CodexThreads.page(title: "舊名字", index: index) == nil)
    }
}

private func line(_ ordinal: Int, _ role: String, _ text: String, type: String = "input_text") -> String {
    let content = #"[{"type":"\#(type)","text":\#(String(data: try! JSONEncoder().encode(text), encoding: .utf8)!)}]"#
    return #"{"ordinal":\#(ordinal),"type":"response_item","payload":{"type":"message","role":"\#(role)","content":\#(content)}}"#
}

@Suite("Codex 對話紀錄")
struct CodexTranscriptTests {
    @Test("只留使用者與 Codex 說的話，去掉開發者訊息、推理、工具呼叫與附加的標籤")
    func keepsOnlyWhatWasSaid() {
        let jsonl = [
            line(1, "developer", "<permissions>sandbox</permissions>"),
            line(2, "user", "<environment_context>cwd</environment_context>\n磁碟是不是快滿了？"),
            #"{"ordinal":3,"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            #"{"ordinal":4,"type":"response_item","payload":{"type":"function_call","name":"exec","arguments":"df -h"}}"#,
            #"{"ordinal":5,"type":"event_msg","payload":{"type":"token_count"}}"#,
            line(6, "assistant", "還有 80 GB，正常。", type: "output_text"),
            line(7, "user", "<environment_context>only context</environment_context>"),
        ].joined(separator: "\n")
        #expect(CodexTranscript.messages(jsonl: Data(jsonl.utf8)) == [
            TranscriptMessage(role: .user, text: "磁碟是不是快滿了？"),
            TranscriptMessage(role: .assistant, text: "還有 80 GB，正常。"),
        ])
    }

    @Test("改過前面的訊息：前段用第一個檔，從分支開始處接最新的分支")
    func followsTheLatestBranch() {
        let first = [line(1, "user", "問題一"), line(2, "assistant", "回答一", type: "output_text"),
                     line(3, "user", "原本的問題二"), line(4, "assistant", "原本的回答二", type: "output_text")].joined(separator: "\n")
        let branch = [line(3, "user", "改過的問題二"), line(4, "assistant", "新的回答二", type: "output_text")].joined(separator: "\n")
        #expect(CodexTranscript.messages(files: [Data(first.utf8), Data(branch.utf8)]).map(\.text)
            == ["問題一", "回答一", "改過的問題二", "新的回答二"])
    }

    @Test("在 sessions 資料夾裡找到 thread 的檔案，讀出整段對話")
    func readsTheThreadsFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HintletTests-\(UUID().uuidString)")
        let day = home.appendingPathComponent("sessions/2026/10/21")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let thread = "01a15c92-77e9-76c1-ba20-f9920fbad1d5"
        try Data(line(1, "user", "要做什麼？").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-10-21T11-47-45-\(thread).jsonl"))
        try Data(line(1, "user", "別的對話").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-10-21T11-50-00-01a15c92-0000-7000-8000-000000000000.jsonl"))

        let files = CodexRolloutFiles(codexHome: home)
        #expect(try files.content(of: thread).messages == [TranscriptMessage(role: .user, text: "要做什麼？")])
        #expect(throws: ClaudeTranscriptFiles.ReadError.notFound) { try files.content(of: "01a15c92-1111-7000-8000-000000000000") }
    }
}
