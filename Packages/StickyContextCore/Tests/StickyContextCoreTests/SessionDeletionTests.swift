import Foundation
import Testing
import StickyContextCore

private let code = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-000000000002")
private let otherCode = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-000000000009")
private let cowork = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-000000000003")
private let chat = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-000000000001")

/// A stand-in for `~/Library/Application Support/Claude`, laid out as Claude files its sessions:
/// `<folder>/<account>/<organisation>/local_<uuid>.json`.
private struct ClaudeFolder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")

    private func organisation(for kind: ConversationKind) -> URL {
        let folder = kind == .code ? "claude-code-sessions" : "local-agent-mode-sessions"
        return root.appendingPathComponent("\(folder)/account/organisation")
    }

    func write(_ ref: ConversationRef) throws {
        let folder = organisation(for: ref.kind)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title":"session"}"#.utf8).write(to: folder.appendingPathComponent("\(ref.id).json"))
    }

    func remove(_ ref: ConversationRef) throws {
        try FileManager.default.removeItem(at: organisation(for: ref.kind).appendingPathComponent("\(ref.id).json"))
    }

    /// What Claude leaves behind when a Code session is deleted: `deleted_<uuid>`.
    func leaveTombstone(for ref: ConversationRef) throws {
        let name = "deleted_" + ref.id.dropFirst("local_".count)
        try Data("1792070212961".utf8).write(to: organisation(for: ref.kind).appendingPathComponent(name))
    }
}

@Suite("偵測 Code／Cowork session 被刪除")
struct DetectingDeletedSessions {
    @Test("session 檔還在，就不算刪除")
    func presentSessionIsKept() throws {
        let claude = ClaudeFolder()
        try claude.write(code)
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))

        #expect(detector.deletedSessions(among: [code]).isEmpty)
        #expect(detector.deletedSessions(among: [code]).isEmpty)
    }

    @Test("session 檔消失，連續兩次檢查都不在才算刪除")
    func missingTwiceInARowIsDeleted() throws {
        let claude = ClaudeFolder()
        try claude.write(cowork)
        try claude.write(ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-000000000008"))
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))
        #expect(detector.deletedSessions(among: [cowork]).isEmpty)

        try claude.remove(cowork)
        #expect(detector.deletedSessions(among: [cowork]).isEmpty)
        #expect(detector.deletedSessions(among: [cowork]) == [cowork])
    }

    @Test("短暫消失後又出現，不算刪除")
    func briefGapIsNotADeletion() throws {
        let claude = ClaudeFolder()
        try claude.write(code)
        try claude.write(otherCode)
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))

        try claude.remove(code)
        #expect(detector.deletedSessions(among: [code]).isEmpty)
        try claude.write(code)
        #expect(detector.deletedSessions(among: [code]).isEmpty)
        try claude.remove(code)
        #expect(detector.deletedSessions(among: [code]).isEmpty)
    }

    @Test("Code 留下刪除記號時，一次就確定")
    func tombstoneIsCertain() throws {
        let claude = ClaudeFolder()
        try claude.write(code)
        try claude.leaveTombstone(for: code)
        try claude.remove(code)
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))

        #expect(detector.deletedSessions(among: [code]) == [code])
    }

    @Test("看不到 Claude 的 session 資料夾（沒裝、沒權限、整個清空）時，什麼都不算刪除")
    func unreadableFolderSaysNothing() throws {
        let claude = ClaudeFolder()
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))
        for _ in 0..<3 { #expect(detector.deletedSessions(among: [code, cowork]).isEmpty) }

        // The only session there was is gone: the folder may as well have been wiped.
        try claude.write(code)
        try claude.remove(code)
        for _ in 0..<3 { #expect(detector.deletedSessions(among: [code]).isEmpty) }
    }

    @Test("Chat 對話沒有本機檔，永遠不算刪除")
    func chatIsNeverDeleted() throws {
        let claude = ClaudeFolder()
        try claude.write(code)
        let detector = SessionDeletionDetector(files: ClaudeSessionFolder(root: claude.root))

        for _ in 0..<3 { #expect(detector.deletedSessions(among: [chat]).isEmpty) }
    }

    @Test("找得到 session 檔的位置，供讀標題用")
    func findsTheSessionFile() throws {
        let claude = ClaudeFolder()
        try claude.write(code)

        let file = try #require(ClaudeSessionFolder(root: claude.root).file(for: code))
        #expect(try ClaudeSessionInfo(json: Data(contentsOf: file)).title == "session")
        #expect(ClaudeSessionFolder(root: claude.root).file(for: chat) == nil)
    }
}
