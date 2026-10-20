import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let login = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-0000000000b1")
private let deploy = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-0000000000b2")
private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func claude(_ ref: ConversationRef) -> ObservedWindow {
    ObservedWindow(id: WindowID(1), appName: "Claude", title: "Claude", frame: CGRect(x: 0, y: 79, width: 1512, height: 870),
                   bundleID: "com.anthropic.claudefordesktop", claudePage: .conversation(ref, title: "對話"))
}

/// Conversations as the test says they read now.
private final class FakeTranscripts: @unchecked Sendable {
    var messages: [ConversationRef: [TranscriptMessage]] = [:]
    var unreadable: Set<ConversationRef> = []
    private(set) var reads: [ConversationRef] = []

    func content(of ref: ConversationRef) throws -> ConversationContent {
        reads.append(ref)
        if unreadable.contains(ref) { throw CocoaError(.fileReadNoPermission) }
        return ConversationContent(messages: messages[ref] ?? [], coverage: .complete)
    }
}

@MainActor
private struct Fixture {
    let engine = NoteEngine(screens: [laptop])
    let model = FakeModel()
    let transcripts = FakeTranscripts()
    let updater: SummaryUpdater

    init() {
        engine.aiConversationKinds = [.code, .cowork]
        let transcripts = transcripts
        updater = SummaryUpdater(engine: engine, service: PromptedSummaryService(model: model, now: { noon }),
                                 content: { try transcripts.content(of: $0) })
        transcripts.messages[login] = [TranscriptMessage(role: .user, text: "重構登入")]
        engine.observe(.window(claude(login)))
    }

    func aiNote() -> NoteID {
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        return id
    }
}

@Suite("SummaryService 切面：更新 AI 便利貼")
@MainActor
struct UpdatingAINotes {
    @Test("新的 AI 便利貼馬上寫第一次摘要")
    func firstSummary() async {
        let fixture = Fixture()
        _ = fixture.aiNote()

        await fixture.updater.run()

        #expect(fixture.engine.displayedNotes.first?.ai?.summary?.doing == "重構登入")
        #expect(fixture.engine.displayedNotes.first?.ai?.status == .idle)
    }

    @Test("切走對話時以假模型更新它的 AI 便利貼")
    func switchingAwayRefreshes() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()
        fixture.transcripts.messages[login]?.append(TranscriptMessage(role: .assistant, text: "測試全過了"))
        fixture.model.reply = "正在做什麼：重構登入\n停在哪裡：測試全過\n下一步：送審"

        fixture.engine.observe(.window(claude(deploy)))
        await fixture.updater.run()

        #expect(fixture.engine.summary(of: id)?.stoppedAt == "測試全過")
        #expect(fixture.model.prompts.count == 2)
    }

    @Test("對話沒有變化時，切走不再問模型；手動更新照樣問")
    func unchangedConversationIsSkipped() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()

        fixture.engine.observe(.window(claude(deploy)))
        await fixture.updater.run()
        #expect(fixture.model.prompts.count == 1)

        fixture.engine.requestSummary(id)
        await fixture.updater.run()
        #expect(fixture.model.prompts.count == 2)
    }

    @Test("模型失敗時保留上一次的摘要並顯示失敗")
    func failureKeepsTheLastSummary() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()
        let first = fixture.engine.summary(of: id)
        fixture.model.failure = CocoaError(.featureUnsupported)

        fixture.engine.requestSummary(id)
        await fixture.updater.run()

        #expect(fixture.engine.summary(of: id) == first)
        #expect(fixture.engine.displayedNotes.first?.ai?.status == .failed(nil))
    }

    @Test("讀不到對話紀錄也算失敗，不會寫出空摘要")
    func unreadableTranscript() async {
        let fixture = Fixture()
        fixture.transcripts.unreadable = [login]
        let id = fixture.aiNote()

        await fixture.updater.run()

        #expect(fixture.engine.summary(of: id) == nil)
        #expect(fixture.engine.displayedNotes.first?.ai?.status == .failed(nil))
        #expect(fixture.model.prompts.isEmpty)
    }

    @Test("只讀有 AI 便利貼的對話；手寫便利貼從不被改動")
    func readsOnlyWhatWasAllowed() async {
        let fixture = Fixture()
        let handwritten = fixture.engine.createNote(at: CGPoint(x: 600, y: 700))
        fixture.engine.editText(of: handwritten, to: "我自己寫的")
        fixture.engine.observe(.window(claude(deploy)))
        fixture.transcripts.messages[deploy] = [TranscriptMessage(role: .user, text: "部署")]
        let id = fixture.aiNote()

        fixture.engine.observe(.window(claude(login)))
        await fixture.updater.run()

        #expect(fixture.transcripts.reads == [deploy])
        fixture.engine.observe(.window(claude(login)))
        #expect(fixture.engine.displayedNotes.first { $0.id == handwritten }?.text == "我自己寫的")
        #expect(fixture.engine.summary(of: id) != nil)
    }
}

@Suite("SummaryUpdater：改用 Claude API")
@MainActor
struct SwitchingToClaudeAPI {
    @Test("改用 Claude API 後，切走時的自動更新也用它寫，即使對話沒變")
    func autoRefreshUsesNewBackend() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()
        let transport = StubTransport()
        transport.reply(text: "正在做什麼：重構登入\n停在哪裡：API 寫的\n下一步：送審")
        fixture.updater.service = PromptedSummaryService(
            model: ClaudeAPISummaryModel(keys: InMemoryAPIKeyStore(key: "sk-ant-test-key"), transport: transport))

        fixture.engine.observe(.window(claude(deploy)))
        await fixture.updater.run()

        #expect(transport.requests.count == 1)
        #expect(fixture.engine.summary(of: id)?.backend == .claudeAPI)
        #expect(fixture.engine.summary(of: id)?.stoppedAt == "API 寫的")
    }

    @Test("Claude API 失敗：顯示原因，保留上一次摘要")
    func failureKeepsLastSummary() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()
        let before = fixture.engine.summary(of: id)
        let transport = StubTransport()
        transport.error(429, type: "rate_limit_error", message: "slow down")
        fixture.updater.service = PromptedSummaryService(
            model: ClaudeAPISummaryModel(keys: InMemoryAPIKeyStore(key: "sk-ant-test-key"), transport: transport))

        fixture.engine.requestSummary(id)
        await fixture.updater.run()

        let ai = fixture.engine.displayedNotes.first?.ai
        #expect(ai?.status == .failed(.rateLimited))
        #expect(ai?.summary == before)
    }
}

@Suite("SummaryUpdater：Claude 每次回完就更新")
@MainActor
struct UpdatingAfterEachReply {
    private func settled(_ fixture: Fixture) async {
        fixture.engine.checkForNewReplies()
        await fixture.updater.run()
    }

    @Test("Claude 回完、內容停下來不再變之後才更新")
    func waitsForTheReplyToSettle() async {
        let fixture = Fixture()
        let id = fixture.aiNote()
        await fixture.updater.run()
        fixture.transcripts.messages[login]?.append(TranscriptMessage(role: .assistant, text: "改好了"))
        fixture.model.reply = "正在做什麼：重構登入\n停在哪裡：改好了\n下一步：跑測試"

        await settled(fixture)
        #expect(fixture.model.prompts.count == 1)

        await settled(fixture)
        #expect(fixture.model.prompts.count == 2)
        #expect(fixture.engine.summary(of: id)?.stoppedAt == "改好了")
    }

    @Test("還在回覆（內容一直變）時不更新")
    func notWhileReplying() async {
        let fixture = Fixture()
        _ = fixture.aiNote()
        await fixture.updater.run()

        for step in 1...3 {
            fixture.transcripts.messages[login]?.append(TranscriptMessage(role: .assistant, text: "第 \(step) 步"))
            await settled(fixture)
        }

        #expect(fixture.model.prompts.count == 1)
    }

    @Test("最後一則是使用者的訊息時（Claude 還沒回），不更新")
    func notBeforeClaudeAnswers() async {
        let fixture = Fixture()
        _ = fixture.aiNote()
        await fixture.updater.run()
        fixture.transcripts.messages[login]?.append(TranscriptMessage(role: .user, text: "再加一個測試"))

        await settled(fixture)
        await settled(fixture)

        #expect(fixture.model.prompts.count == 1)
    }

    @Test("沒有新內容時不打擾：不顯示「正在更新」也不問模型")
    func quietWhenNothingChanged() async {
        let fixture = Fixture()
        _ = fixture.aiNote()
        await fixture.updater.run()
        var statuses: [AIStatus?] = []
        fixture.updater.onChange = { [engine = fixture.engine] in statuses.append(engine.displayedNotes.first?.ai?.status) }

        await settled(fixture)
        await settled(fixture)

        #expect(fixture.model.prompts.count == 1)
        #expect(!statuses.contains(.updating))
    }
}

