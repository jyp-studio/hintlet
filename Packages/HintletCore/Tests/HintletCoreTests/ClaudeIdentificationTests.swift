import Foundation
import Testing
import HintletCore

/// Seam B: Accessibility snapshots recorded from the Claude app (spike 02) → what the user is looking at.
private func snapshot(_ name: String) throws -> ClaudeSnapshot {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ClaudeAX"))
    return try JSONDecoder().decode(ClaudeSnapshot.self, from: Data(contentsOf: url))
}

private let sampleID = "00000000-0000-4000-8000-000000000001"

@Suite("辨識 Claude 頁面（錄下的快照）")
struct ClaudePageIdentification {
    @Test("Chat 對話：對話 ID 與標題（去掉「 - Claude」）")
    func chatConversation() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("chat-conversation"))
            == .conversation(ConversationRef(kind: .chat, id: sampleID), title: "範例對話"))
    }

    @Test("Cowork session")
    func coworkSession() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("cowork-session"))
            == .conversation(ConversationRef(kind: .cowork, id: "local_\(sampleID)"), title: "範例對話"))
    }

    @Test("Code session：標題去掉「 - Claude Code」")
    func codeSession() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("code-session"))
            == .conversation(ConversationRef(kind: .code, id: "local_\(sampleID)"), title: "範例對話"))
    }

    @Test("新對話頁（Chat、Cowork、Code 首頁、被導回的已刪除對話）是草稿", arguments: [
        "chat-new", "cowork-new", "code-home", "chat-deleted-redirects-to-new",
    ])
    func drafts(name: String) throws {
        #expect(ClaudeIdentifier.page(in: try snapshot(name)) == .draft)
    }

    @Test("設定開著時是設定頁")
    func settings() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("settings-over-new")) == .settings)
    }

    @Test("專案頁等其他頁認不出對話，降級")
    func projects() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("projects")) == .unrecognized)
    }

    @Test("網址像對話但 ID 格式不符，降級不猜測")
    func unexpectedURL() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("synthetic-unexpected-url")) == .unrecognized)
    }

    @Test("兩個網頁區域、其一尺寸為零時，依焦點元素判斷")
    func twoWebAreas() throws {
        #expect(ClaudeIdentifier.page(in: try snapshot("synthetic-two-web-areas"))
            == .conversation(ConversationRef(kind: .chat, id: sampleID), title: "範例對話"))
    }
}

@Suite("辨識 Claude 頁面（規則）")
struct ClaudePageRules {
    private func page(focusedURL: String?, webAreas: [(url: String, title: String, width: Double)]) -> ClaudePage {
        let areas = webAreas.map {
            ClaudeSnapshot.WebArea(url: $0.url, title: $0.title, frame: .init(x: 0, y: 0, width: $0.width, height: 900))
        }
        let window = ClaudeSnapshot.Window(focused: true, main: true, minimized: false, title: "Claude",
                                           frame: .init(x: 0, y: 0, width: 1200, height: 900), webAreas: areas)
        return ClaudeIdentifier.page(in: ClaudeSnapshot(
            focusedElement: focusedURL.map { .init(role: "AXTextArea", nearestWebAreaURL: $0) }, windows: [window]))
    }

    @Test("焦點不在網頁裡時，用視窗中唯一尺寸非零的網頁區域")
    func fallsBackToTheOnlyWebArea() {
        #expect(page(focusedURL: nil, webAreas: [("https://claude.ai/chat/\(sampleID)", "A - Claude", 1200)])
            == .conversation(ConversationRef(kind: .chat, id: sampleID), title: "A"))
    }

    @Test("焦點不在網頁裡、又有多個網頁區域時，無法確定，降級")
    func severalWebAreasAreAmbiguous() {
        #expect(page(focusedURL: nil, webAreas: [
            ("https://claude.ai/chat/\(sampleID)", "A - Claude", 1200),
            ("https://claude.ai/chat/00000000-0000-4000-8000-000000000002", "B - Claude", 1200),
        ]) == .unrecognized)
    }

    /// Claude's own app shell is a web area of its own (a file:// page) as large as the conversation.
    private static let shell = ("file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", "Claude", 1200.0)

    @Test("Claude 的外框（file:// 網頁區域）不算一頁：焦點不在網頁裡時用唯一的 Claude 網頁")
    func shellIsNotAPage() {
        #expect(page(focusedURL: nil, webAreas: [Self.shell, ("https://claude.ai/epitaxy/local_\(sampleID)", "A - Claude Code", 1200)])
            == .conversation(ConversationRef(kind: .code, id: "local_\(sampleID)"), title: "A"))
    }

    @Test("焦點在 Claude 的外框（例如上方的按鈕）時，仍是外框旁那一頁")
    func focusInTheShell() {
        #expect(page(focusedURL: Self.shell.0, webAreas: [Self.shell, ("https://claude.ai/chat/\(sampleID)", "A - Claude", 1200)])
            == .conversation(ConversationRef(kind: .chat, id: sampleID), title: "A"))
    }

    @Test("焦點與唯一網頁區域互相矛盾時，降級")
    func contradictionIsUnrecognized() {
        #expect(page(focusedURL: "https://claude.ai/chat/00000000-0000-4000-8000-000000000002",
                     webAreas: [("https://claude.ai/chat/\(sampleID)", "A - Claude", 1200)]) == .unrecognized)
    }

    @Test("沒有網頁區域時，降級")
    func noWebArea() {
        #expect(page(focusedURL: nil, webAreas: []) == .unrecognized)
    }

    @Test("對話上開著設定，也是設定頁")
    func settingsOverAConversation() {
        #expect(page(focusedURL: "https://claude.ai/chat/\(sampleID)#settings/general",
                     webAreas: [("https://claude.ai/chat/\(sampleID)#settings/general", "A - Claude", 1200)]) == .settings)
    }

    @Test("別的網域不是 Claude 對話")
    func otherHost() {
        #expect(page(focusedURL: "https://example.com/chat/\(sampleID)",
                     webAreas: [("https://example.com/chat/\(sampleID)", "A - Claude", 1200)]) == .unrecognized)
    }
}

@Suite("Claude session 檔")
struct ClaudeSessionFiles {
    @Test("讀出標題與是否封存")
    func readsTitleAndArchive() throws {
        let json = #"{"sessionId": "local_x", "title": "整理報告", "isArchived": true, "cwd": "/tmp"}"#
        #expect(try ClaudeSessionInfo(json: Data(json.utf8)) == ClaudeSessionInfo(title: "整理報告", isArchived: true))
    }

    @Test("沒有封存欄位時視為未封存")
    func archiveDefaultsToFalse() throws {
        #expect(try ClaudeSessionInfo(json: Data(#"{"title": "A"}"#.utf8)) == ClaudeSessionInfo(title: "A", isArchived: false))
    }
}
