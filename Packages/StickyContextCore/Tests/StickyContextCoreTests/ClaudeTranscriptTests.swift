import Foundation
import Testing
import StickyContextCore

/// Lines shaped like Claude's local transcripts (`<cliSessionId>.jsonl`), trimmed to what matters.
private let transcript = #"""
{"type":"queue-operation","operation":"enqueue"}
{"type":"user","isSidechain":false,"message":{"role":"user","content":"幫我重構登入流程<system-reminder>內部提示</system-reminder>"}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"想一下"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"先把 session 處理抽出來。"}]}}
{"type":"user","message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>只看登入</command-args>"}}
{"type":"user","message":{"role":"user","content":"<task-notification><status>done</status></task-notification>"}}
{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"子代理的話"}]}}
not json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"再加上測試"},{"type":"image"}]}}
"""#

private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("StickyContextTests-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite("讀取 Code 與 Cowork 的本機對話紀錄")
struct ReadingTranscripts {
    @Test("只留下使用者與 Claude 說的話：略過內部訊息、思考、工具、子代理與系統提示")
    func keepsWhatWasSaid() {
        let messages = ClaudeTranscript.messages(jsonl: Data(transcript.utf8))

        #expect(messages == [
            TranscriptMessage(role: .user, text: "幫我重構登入流程"),
            TranscriptMessage(role: .assistant, text: "先把 session 處理抽出來。"),
            TranscriptMessage(role: .user, text: "/review 只看登入"),
            TranscriptMessage(role: .user, text: "再加上測試"),
        ])
    }

    @Test("Code session：由 session 檔的 cliSessionId 找到 ~/.claude/projects 裡的紀錄，涵蓋完整")
    func codeSession() throws {
        let folder = TemporaryFolder()
        let claude = folder.url.appendingPathComponent("Claude"), home = folder.url.appendingPathComponent("dot-claude")
        let ref = ConversationRef(kind: .code, id: "local_aaaa")
        try write(#"{"sessionId":"local_aaaa","cliSessionId":"cli-1","title":"登入"}"#,
                  to: claude.appendingPathComponent("claude-code-sessions/acct/org/local_aaaa.json"))
        try write(transcript, to: home.appendingPathComponent("projects/-Users-me-app/cli-1.jsonl"))
        let files = ClaudeTranscriptFiles(sessionFolder: ClaudeSessionFolder(root: claude), claudeHome: home)

        let content = try files.content(of: ref)

        #expect(content.coverage == .complete)
        #expect(content.messages.first?.text == "幫我重構登入流程")
    }

    @Test("Cowork session：紀錄在 session 自己的資料夾裡")
    func coworkSession() throws {
        let folder = TemporaryFolder()
        let claude = folder.url.appendingPathComponent("Claude"), home = folder.url.appendingPathComponent("dot-claude")
        let ref = ConversationRef(kind: .cowork, id: "local_bbbb")
        let org = claude.appendingPathComponent("local-agent-mode-sessions/acct/org")
        try write(#"{"sessionId":"local_bbbb","cliSessionId":"cli-2"}"#, to: org.appendingPathComponent("local_bbbb.json"))
        try write(transcript, to: org.appendingPathComponent("local_bbbb/.claude/projects/-sessions-outputs/cli-2.jsonl"))
        let files = ClaudeTranscriptFiles(sessionFolder: ClaudeSessionFolder(root: claude), claudeHome: home)

        #expect(try files.content(of: ref).messages.count == 4)
    }

    @Test("找不到紀錄時回報錯誤；Chat 與終端機的對話不從這裡讀")
    func missing() throws {
        let folder = TemporaryFolder()
        let files = ClaudeTranscriptFiles(sessionFolder: ClaudeSessionFolder(root: folder.url), claudeHome: folder.url)

        #expect(throws: ClaudeTranscriptFiles.ReadError.notFound) {
            try files.content(of: ConversationRef(kind: .code, id: "local_none"))
        }
        #expect(throws: ClaudeTranscriptFiles.ReadError.notFound) {
            try files.content(of: ConversationRef(kind: .chat, id: "x"))
        }
    }

    @Test("讀取不改動任何檔案")
    func readOnly() throws {
        let folder = TemporaryFolder()
        let claude = folder.url.appendingPathComponent("Claude"), home = folder.url.appendingPathComponent("dot-claude")
        let session = claude.appendingPathComponent("claude-code-sessions/acct/org/local_aaaa.json")
        let log = home.appendingPathComponent("projects/p/cli-1.jsonl")
        try write(#"{"cliSessionId":"cli-1"}"#, to: session)
        try write(transcript, to: log)
        let before = try [session, log].map { try Data(contentsOf: $0) }
        let dates = try [session, log].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }

        _ = try ClaudeTranscriptFiles(sessionFolder: ClaudeSessionFolder(root: claude), claudeHome: home)
            .content(of: ConversationRef(kind: .code, id: "local_aaaa"))

        #expect(try [session, log].map { try Data(contentsOf: $0) } == before)
        #expect(try [session, log].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date } == dates)
    }
}
