import Foundation
import Testing
import HintletCore

// Fake Chat pages, shaped like Claude's Accessibility tree in spike 04: a user message is a bubble
// (class `bg-user-message`) after a hidden heading "You said: …"; Claude's reply is a `group/message-row`
// group holding a hidden heading "Claude responded".

private func text(_ value: String) -> ChatPageNode {
    ChatPageNode(role: "AXStaticText", value: value)
}

private func heading(_ label: String) -> ChatPageNode {
    ChatPageNode(role: "AXHeading", children: [text(label)])
}

private func group(_ children: [ChatPageNode], classes: [String] = []) -> ChatPageNode {
    ChatPageNode(role: "AXGroup", classes: classes, children: children)
}

private func user(_ said: String) -> [ChatPageNode] {
    [heading("You said: \(said)"), group([group([text(said)])], classes: ["rounded-xl", "bg-user-message", "px-4"])]
}

private func claude(_ paragraphs: [String]) -> ChatPageNode {
    group([heading("Claude responded"), group(paragraphs.map { group([text($0)]) }),
           ChatPageNode(role: "AXButton", title: "Copy", children: [text("Copy")])],
          classes: ["group", "group/message-row"])
}

private func page(_ messages: [ChatPageNode]) -> ChatPageNode {
    ChatPageNode(role: "AXWebArea", children: [group(messages), group([text("Claude can make mistakes.")])])
}

@Suite("讀取 Chat 頁面已載入的訊息")
struct ReadingChatPages {
    @Test("依頁面標示分出使用者與 Claude 說的話，略過標題、按鈕與訊息以外的字")
    func messagesInOrder() throws {
        let content = try ChatPage.content(of: page(user("幫我規劃東京五天行程") + [claude(["第一天：淺草。", "第二天：上野。"])]
            + user("第三天想去鎌倉") + [claude(["可以，早上出發。"])]))

        #expect(content.messages == [
            TranscriptMessage(role: .user, text: "幫我規劃東京五天行程"),
            TranscriptMessage(role: .assistant, text: "第一天：淺草。\n第二天：上野。"),
            TranscriptMessage(role: .user, text: "第三天想去鎌倉"),
            TranscriptMessage(role: .assistant, text: "可以，早上出發。"),
        ])
    }

    @Test("最早的訊息已被頁面卸載：標成「僅根據已載入的 4 則訊息」")
    func partOfTheConversation() throws {
        // Spike 04's long test chat, sitting at the bottom: `A A U A`.
        let content = try ChatPage.content(of: page([claude(["1\n2\n3…200"]), claude(["好的，再列一次。"])]
            + user("最後一次，列出 1 到 200") + [claude(["1\n2\n3…200"])]))

        #expect(content.coverage == .partial(loadedMessages: 4))
    }

    @Test("已載入的內容太少，說不出什麼：標成不足，不交給模型補寫")
    func tooLittle() throws {
        let content = try ChatPage.content(of: page(user("嗨") + [claude(["你好！"])]))

        #expect(content.coverage == .insufficient)
    }

    @Test("只打了招呼，即使 Claude 回得很長，也算內容不足")
    func greetingWithALongReply() throws {
        let content = try ChatPage.content(of: page(user("嗨") + [claude(["嗨！很高興見到你。今天有什麼想做的嗎？我可以幫你寫東西、查資料、整理想法，或只是聊聊天。"])]))

        #expect(content.coverage == .insufficient)
    }

    @Test("頁面的 class 改了名：改用無障礙標題「You said」「Claude responded」分出訊息")
    func headingsWithoutClasses() throws {
        let renamed = page([heading("You said: 幫我寫一封請假信"), group([group([text("幫我寫一封請假信")])]),
                            group([heading("Claude responded"), group([group([text("主管您好，我想請明天的假。")])])])])

        let content = try ChatPage.content(of: renamed)

        #expect(content.messages == [
            TranscriptMessage(role: .user, text: "幫我寫一封請假信"),
            TranscriptMessage(role: .assistant, text: "主管您好，我想請明天的假。"),
        ])
        #expect(content.coverage == .partial(loadedMessages: 2))
    }

    @Test("頁面上分不出任何訊息（還在載入，或 Claude 改了頁面）：回報讀不到，不猜")
    func nothingToTell() {
        #expect(throws: ChatPage.ReadError.noMessages) {
            try ChatPage.content(of: page([group([text("Claude can make mistakes.")])]))
        }
    }
}

@Suite("Chat 的 AI 便利貼摘要：只根據已載入的訊息")
struct SummarizingChats {
    @Test("部分內容：摘要標示「已載入 N 則」，並要模型不推測沒看到的部分")
    func partialSummary() async throws {
        let model = FakeModel()
        let content = try ChatPage.content(of: page([claude(["第一天：淺草，第二天：上野。"])] + user("第三天想去鎌倉")))

        let summary = try await PromptedSummaryService(model: model).summarize(content, previous: nil)

        #expect(summary.coverage == .partial(loadedMessages: 2))
        #expect(model.instructions.first?.contains("沒看到的部分不要推測") == true)
        #expect(model.prompts.first?.contains("僅根據已載入的 2 則訊息") == true)
    }

    @Test("內容不足：摘要說明不足，不請模型補寫")
    func insufficientSummary() async throws {
        let model = FakeModel()
        let content = try ChatPage.content(of: page(user("嗨") + [claude(["你好！"])]))

        let summary = try await PromptedSummaryService(model: model).summarize(content, previous: nil)

        #expect(summary.coverage == .insufficient)
        #expect(summary.lines.isEmpty)
        #expect(model.prompts.isEmpty)
    }
}

private let trip = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-0000000000c1")
private let diary = ConversationRef(kind: .chat, id: "00000000-0000-4000-8000-0000000000c2")

private let tripPage = page(user("幫我規劃東京五天行程") + [claude(["第一天：淺草，第二天：上野。"])])

/// Claude's window as the test says it is: which Chat it shows, and what that page has loaded.
private final class FakeClaude: @unchecked Sendable {
    var shown: ConversationRef?
    var pages: [ConversationRef: ChatPageNode] = [:]
    var turnedOn: Set<ConversationRef> = []
    private(set) var reads: [ConversationRef] = []

    func page(_ ref: ConversationRef) -> ChatPageNode? {
        reads.append(ref)
        return shown == ref ? pages[ref] : nil
    }

    func readings() -> ChatReadings {
        ChatReadings(isTurnedOn: { [self] in turnedOn.contains($0) }, readPage: { [self] in page($0) })
    }
}

@Suite("Chat 內容只在使用者開了 AI 便利貼的對話讀取")
struct ReadingOnlyChatsWithAI {
    @Test("從頁面網址認出是哪個對話，才讀那一頁")
    func pageAddress() {
        #expect(ClaudeIdentifier.conversation(at: "https://claude.ai/chat/\(trip.id)") == trip)
        #expect(ClaudeIdentifier.conversation(at: "https://claude.ai/new") == nil)
        #expect(ClaudeIdentifier.conversation(at: "https://example.com/chat/\(trip.id)") == nil)
    }

    @Test("沒有 AI 便利貼的對話，頁面一次都不讀")
    func othersAreNeverRead() async {
        let claude = FakeClaude()
        claude.shown = diary
        claude.pages[diary] = tripPage
        let readings = claude.readings()

        await readings.capture(diary)
        await #expect(throws: ChatReadings.ReadError.notTurnedOn) { try await readings.content(of: diary) }

        #expect(claude.reads.isEmpty)
    }

    @Test("對話正顯示著：讀頁面現在載入的訊息")
    func readsWhatIsShown() async throws {
        let claude = FakeClaude()
        claude.turnedOn = [trip]
        claude.shown = trip
        claude.pages[trip] = tripPage

        let content = try await claude.readings().content(of: trip)

        #expect(content.coverage == .partial(loadedMessages: 2))
        #expect(content.messages.first == TranscriptMessage(role: .user, text: "幫我規劃東京五天行程"))
    }

    @Test("使用者已切到別的對話：用離開前最後讀到的內容")
    func lastReadAfterLeaving() async throws {
        let claude = FakeClaude()
        claude.turnedOn = [trip]
        claude.shown = trip
        claude.pages[trip] = tripPage
        let readings = claude.readings()
        await readings.capture(trip)

        claude.shown = diary
        let content = try await readings.content(of: trip)

        #expect(content.coverage == .partial(loadedMessages: 2))
    }

    @Test("從沒讀到過、現在也沒顯示：回報讀不到")
    func neverShown() async {
        let claude = FakeClaude()
        claude.turnedOn = [trip]

        await #expect(throws: ChatReadings.ReadError.notShown) { try await claude.readings().content(of: trip) }
    }

    @Test("頁面一時分不出訊息（還在載入）：留著上一次讀到的")
    func keepsTheLastGoodRead() async throws {
        let claude = FakeClaude()
        claude.turnedOn = [trip]
        claude.shown = trip
        claude.pages[trip] = tripPage
        let readings = claude.readings()
        await readings.capture(trip)

        claude.pages[trip] = page([])
        await readings.capture(trip)
        claude.shown = nil

        #expect(try await readings.content(of: trip).coverage == .partial(loadedMessages: 2))
    }

    @Test("停用 AI 之後，先前讀到的內容也不留")
    func forgetsWhenTurnedOff() async {
        let claude = FakeClaude()
        claude.turnedOn = [trip]
        claude.shown = trip
        claude.pages[trip] = tripPage
        let readings = claude.readings()
        await readings.capture(trip)

        claude.turnedOn = []
        await readings.capture(trip)
        claude.turnedOn = [trip]
        claude.shown = nil

        await #expect(throws: ChatReadings.ReadError.notShown) { try await readings.content(of: trip) }
    }
}
