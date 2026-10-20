import Foundation
import Testing
import StickyContextCore

/// A model that answers with whatever the test says, and remembers what it was asked.
final class FakeModel: SummaryModel, @unchecked Sendable {
    var reply: String
    var failure: (any Error)?
    /// Fails with "prompt too long" while the prompt is longer than this.
    var acceptsPromptsUpTo = Int.max
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []
    let backend: SummaryBackend
    let promptBudget: Int

    init(reply: String = "正在做什麼：重構登入\n停在哪裡：測試失敗\n下一步：修好測試",
         backend: SummaryBackend = .onDevice, promptBudget: Int = 4000) {
        self.reply = reply
        self.backend = backend
        self.promptBudget = promptBudget
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        self.instructions.append(instructions)
        prompts.append(prompt)
        if let failure { throw failure }
        if prompt.count > acceptsPromptsUpTo { throw SummaryModelError.promptTooLong }
        return reply
    }
}

private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func content(_ messages: [TranscriptMessage], coverage: SummaryCoverage = .complete) -> ConversationContent {
    ConversationContent(messages: messages, coverage: coverage)
}

private let loginWork = [
    TranscriptMessage(role: .user, text: "幫我重構登入流程"),
    TranscriptMessage(role: .assistant, text: "我先把 session 處理抽出來。測試目前有兩個失敗。"),
]

@Suite("SummaryService：目標、重點與下一步")
struct GoalPointNextSummaries {
    @Test("模型回覆的三行成為目標、重點與下一步，附上涵蓋程度、後端與更新時間")
    func goalPointNext() async throws {
        let model = FakeModel(reply: "目標：修好建置\n重點：磁碟正常；I/O 錯誤是 Google Drive 在備份 ~/dev\n下一步：等你：在 Google Drive 排除 ~/dev")
        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)

        #expect(summary.goal == "修好建置")
        #expect(summary.point == "磁碟正常；I/O 錯誤是 Google Drive 在備份 ~/dev")
        #expect(summary.state == (.waitingForYou, "在 Google Drive 排除 ~/dev"))
        #expect(summary.lines.count == 3)
        #expect(summary.coverage == .complete)
        #expect(summary.backend == .onDevice)
        #expect(summary.updatedAt == noon)
    }

    @Test("沒有要使用者做的事時沒有下一步，只有兩行")
    func noNextStep() async throws {
        let model = FakeModel(reply: "目標：重做動態島按鈕\n重點：顏色點與按鈕都改成 26pt")
        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)

        #expect(summary.lines == ["重做動態島按鈕", "顏色點與按鈕都改成 26pt"])
        #expect(summary.state.0 == .unknown)
    }

    @Test("指示要寫結論本身、不寫「回答了」這類動作，並說明目標何時才換")
    func instructionsAskForTheGist() async throws {
        let model = FakeModel()
        _ = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)

        let instructions = try #require(model.instructions.first)
        for words in ["目標：", "重點：", "下一步：", "回答了", "等你", "卡住", "新工作"] { #expect(instructions.contains(words)) }
    }

    @Test("狀態認得等你、卡住、進行中，英文也是；沒寫狀態的算未知")
    func states() {
        func state(_ next: String) -> SummaryState {
            AISummary(goal: "g", point: "p", next: next, coverage: .complete, backend: .onDevice, updatedAt: noon).state.0
        }
        #expect(state("進行中：改 BrowserPages") == .working)
        #expect(state("等你：要不要合併") == .waitingForYou)
        #expect(state("卡住：build.db 錯誤") == .stuck)
        #expect(state("Your turn: pick a name") == .waitingForYou)
        #expect(state("修好測試") == .unknown)
    }

    @Test("標籤、項目符號、編號、粗體與句號都拿掉，順序照標籤")
    func toleratesDecoration() async throws {
        let model = FakeModel(reply: """
        以下是摘要：
        - **重點**：部署腳本寫好，還沒上線。
        1. **目標:** 上線部署腳本
        * 下一步： 等你：確認上線時間
        """)
        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)

        #expect(summary.lines == ["上線部署腳本", "部署腳本寫好，還沒上線", "等你：確認上線時間"])
    }

    @Test("舊格式的三行回覆也讀得懂")
    func olderThreeLineReply() async throws {
        let summary = try await PromptedSummaryService(model: FakeModel(), now: { noon }).summarize(content(loginWork), previous: nil)

        #expect(summary.lines == ["重構登入", "測試失敗", "修好測試"])
    }

    @Test("只有部分行有標籤時，其他行照順序補上")
    func someLabels() async throws {
        let model = FakeModel(reply: "目標：把設定視窗改成 macOS 原生樣式\n大小有彈出選單與滑桿兩種做法\n等你：選一種")
        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)

        #expect(summary.lines == ["把設定視窗改成 macOS 原生樣式", "大小有彈出選單與滑桿兩種做法", "等你：選一種"])
    }

    @Test("回覆不到兩行就算失敗，不湊數")
    func tooFewLines() async throws {
        let model = FakeModel(reply: "只有一行")
        await #expect(throws: SummaryError.malformedReply) {
            try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: nil)
        }
    }

    @Test("沒有任何訊息時不問模型，摘要標示內容不足")
    func nothingToSummarize() async throws {
        let model = FakeModel()
        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content([]), previous: nil)

        #expect(summary.coverage == .insufficient)
        #expect(summary.lines.isEmpty)
        #expect(model.prompts.isEmpty)
    }

    @Test("只讀到部分訊息時，提示寫明只根據 N 則訊息、不推測，摘要也標示部分")
    func partialCoverage() async throws {
        let model = FakeModel()
        let summary = try await PromptedSummaryService(model: model, now: { noon })
            .summarize(content(loginWork, coverage: .partial(loadedMessages: 2)), previous: nil)

        #expect(summary.coverage == .partial(loadedMessages: 2))
        #expect(model.prompts[0].contains("2"))
        #expect(model.instructions[0].contains("不要推測"))
    }

    @Test("提示放得下時包含第一個要求與最近的訊息；太長時保留開頭要求與最新的訊息")
    func promptKeepsTheGoalAndTheLatest() async throws {
        let model = FakeModel(promptBudget: 600)
        var messages = [TranscriptMessage(role: .user, text: "目標：把付款流程搬到新 API")]
        for index in 1...40 { messages.append(TranscriptMessage(role: .assistant, text: "第 \(index) 步完成了一些事情，細節很多很多。")) }

        _ = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(messages), previous: nil)

        let prompt = model.prompts[0]
        #expect(prompt.count <= 600)
        #expect(prompt.contains("把付款流程搬到新 API"))
        #expect(prompt.contains("第 40 步"))
        #expect(!prompt.contains("第 2 步"))
    }

    @Test("Claude 最新一則回覆比較早的訊息放得多：停在哪裡要靠它")
    func latestReplyGetsMoreRoom() async throws {
        let model = FakeModel(promptBudget: 6000)
        let long = String(repeating: "細節", count: 400) + "結尾的結論"
        let messages = [TranscriptMessage(role: .user, text: "目標"),
                        TranscriptMessage(role: .assistant, text: "早先的 " + long),
                        TranscriptMessage(role: .assistant, text: "最新的 " + long)]

        _ = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(messages), previous: nil)

        let prompt = model.prompts[0]
        #expect(prompt.contains("最新的"))
        #expect(prompt.contains("結尾的結論"))
        #expect(prompt.components(separatedBy: "結尾的結論").count == 2)
    }

    @Test("話題換了：最新的一問一答放在最前面，最初的要求只當背景")
    func latestTopicLeads() async throws {
        let model = FakeModel()
        let previous = AISummary(doing: "討論電子寵物", stoppedAt: "說明個性", next: "問屬性", coverage: .complete,
                                 backend: .onDevice, updatedAt: noon)
        let messages = [TranscriptMessage(role: .user, text: "電子寵物有什麼功能？"),
                        TranscriptMessage(role: .assistant, text: "牠有個性與心情。"),
                        TranscriptMessage(role: .user, text: "台北明天天氣如何？"),
                        TranscriptMessage(role: .assistant, text: "明天有颱風，請留意。"),
                        TranscriptMessage(role: .user, text: "那台積電股票會跌嗎？"),
                        TranscriptMessage(role: .assistant, text: "我無法預測股價。")]

        _ = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(messages), previous: previous)

        let prompt = model.prompts[0]
        let latestQuestion = try #require(prompt.range(of: "那台積電股票會跌嗎？"))
        let latestReply = try #require(prompt.range(of: "我無法預測股價。"))
        let firstRequest = try #require(prompt.range(of: "電子寵物有什麼功能？"))
        #expect(latestQuestion.lowerBound < firstRequest.lowerBound)
        #expect(latestReply.lowerBound < firstRequest.lowerBound)
        #expect(prompt.contains("上一張便利貼的目標（沒有開始新工作就沿用）：討論電子寵物"))
        #expect(model.instructions[0].contains("新工作"))
    }

    @Test("模型說提示太長時，縮短一半再試一次")
    func retriesShorter() async throws {
        let model = FakeModel(promptBudget: 2000)
        model.acceptsPromptsUpTo = 1200
        var messages = [TranscriptMessage(role: .user, text: "目標")]
        for index in 1...200 { messages.append(TranscriptMessage(role: .assistant, text: "第 \(index) 步")) }

        let summary = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(messages), previous: nil)

        #expect(model.prompts.count == 2)
        #expect(summary.doing == "重構登入")
    }

    @Test("上一次的摘要只給目標，讓目標穩定；重點與下一步不給，免得模型照抄舊內容")
    func onlyThePreviousGoalIsGiven() async throws {
        let model = FakeModel()
        let previous = AISummary(doing: "舊的在做", stoppedAt: "舊的停處", next: "舊的下一步", coverage: .complete,
                                 backend: .onDevice, updatedAt: noon)

        _ = try await PromptedSummaryService(model: model, now: { noon }).summarize(content(loginWork), previous: previous)

        #expect(model.prompts[0].contains("舊的在做"))
        #expect(!model.prompts[0].contains("舊的停處"))
        #expect(!model.prompts[0].contains("舊的下一步"))
    }
}
