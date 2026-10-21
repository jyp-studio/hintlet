import CoreGraphics
import Foundation
import Testing
import HintletCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let login = ConversationRef(kind: .code, id: "local_00000000-0000-4000-8000-0000000000c1")
private let deploy = ConversationRef(kind: .cowork, id: "local_00000000-0000-4000-8000-0000000000c2")
private let secret = "sk-ant-test-SECRET-1234567890"

private func claude(_ ref: ConversationRef) -> ObservedWindow {
    ObservedWindow(id: WindowID(1), appName: "Claude", title: "Claude", frame: CGRect(x: 0, y: 79, width: 1512, height: 870),
                   bundleID: "com.anthropic.claudefordesktop", claudePage: .conversation(ref, title: "對話"))
}

private func scratchDefaults() -> UserDefaults {
    let name = "HintletCoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("HintletCoreTests-\(UUID().uuidString)", isDirectory: true)
}

@Suite("AI 設定")
struct AISettingsTests {
    @Test("AI 便利貼不用一般便利貼的顏色：以前存的一般顏色改回預設的粉霧")
    func ordinaryColourGivesWay() {
        let defaults = scratchDefaults()
        defaults.set("green", forKey: "aiNoteColor")
        #expect(AISettings.load(from: defaults).noteColor == .mist)
        defaults.set("sunset", forKey: "aiNoteColor")
        #expect(AISettings.load(from: defaults).noteColor == .sunset)
    }

    @Test("預設用裝置端模型，AI 便利貼是粉霧")
    func defaults() {
        let settings = AISettings.load(from: scratchDefaults())
        #expect(settings.backend == .onDevice)
        #expect(settings.noteColor == .mist)
    }

    @Test("改用 Claude API 與換顏色會記住")
    func roundTrip() {
        let defaults = scratchDefaults()
        var settings = AISettings.load(from: defaults)
        settings.backend = .claudeAPI
        settings.noteColor = .sunset
        settings.save(to: defaults)

        #expect(AISettings.load(from: defaults) == AISettings(backend: .claudeAPI, noteColor: .sunset))
    }

    @Test("帳號後端與使用者選的 CLI 路徑會記住；沒選時是 nil")
    func accountBackends() {
        let defaults = scratchDefaults()
        #expect(AISettings.load(from: defaults).codexPath == nil)
        var settings = AISettings(backend: .codexAccount)
        settings.codexPath = "/opt/tools/codex"
        settings.claudePath = "/opt/tools/claude"
        settings.save(to: defaults)

        #expect(AISettings.load(from: defaults) == settings)

        settings.codexPath = nil
        settings.save(to: defaults)
        #expect(AISettings.load(from: defaults).codexPath == nil)
    }
}

@Suite("AI 便利貼顏色")
@MainActor
struct AINoteColour {
    private func engineWithNotes() -> (NoteEngine, ai: NoteID, plain: NoteID) {
        let engine = NoteEngine(screens: [laptop])
        engine.aiConversationKinds = [.code, .cowork]
        engine.observe(.window(claude(login)))
        let ai = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(ai)
        let plain = engine.createNote(at: CGPoint(x: 700, y: 700))
        engine.editText(of: plain, to: "一般便利貼")
        return (engine, ai, plain)
    }

    @Test("設定的顏色即時套用到所有 AI 便利貼，一般便利貼不變")
    func appliesToAINotes() {
        let (engine, ai, plain) = engineWithNotes()
        engine.observe(.window(claude(deploy)))
        let other = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(other)

        engine.aiNoteColor = .green

        let shown = Dictionary(uniqueKeysWithValues: engine.displayedNotes.map { ($0.id, $0.color) })
        #expect(shown[other] == .green)
        engine.observe(.window(claude(login)))
        let again = Dictionary(uniqueKeysWithValues: engine.displayedNotes.map { ($0.id, $0.color) })
        #expect(again[ai] == .green)
        #expect(again[plain] == .yellow)
    }

    @Test("列表裡的 AI 便利貼也用設定的顏色")
    func list() {
        let (engine, ai, _) = engineWithNotes()
        engine.aiNoteColor = .purple

        let listed = engine.list().groups.flatMap(\.notes)
        #expect(listed.first { $0.id == ai }?.color == .purple)
    }
}

@Suite("AI 便利貼：失敗時說原因")
@MainActor
struct AIFailureReasons {
    @Test("失敗原因顯示在便利貼上，並保留上一次摘要；下次成功就清掉")
    func reason() {
        let engine = NoteEngine(screens: [laptop])
        engine.aiConversationKinds = [.code]
        engine.observe(.window(claude(login)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        let summary = AISummary(doing: "重構", stoppedAt: "測試", next: "送審", coverage: .complete,
                                backend: .claudeAPI, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        engine.applySummary(summary, to: id)

        engine.summaryFailed(id, because: .keyRejected)

        let ai = engine.displayedNotes.first?.ai
        #expect(ai?.status == .failed(.keyRejected))
        #expect(ai?.summary == summary)

        engine.applySummary(summary, to: id)
        #expect(engine.displayedNotes.first?.ai?.status == .idle)
    }
}

@Suite("OpenAI API key 不進資料檔與匯出檔")
@MainActor
struct OpenAIKeyStaysOut {
    @Test("OpenAI API 寫過摘要後，notes.json、匯出檔與設定裡都沒有 key")
    func keyNotSaved() async throws {
        let openAISecret = "sk-proj-test-SECRET-0987654321"
        let engine = NoteEngine(screens: [laptop])
        engine.aiConversationKinds = [.code]
        engine.observe(.window(claude(login)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        let transport = StubTransport()
        transport.body = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": "正在做什麼：重構\n停在哪裡：測試\n下一步：送審"]]]],
        ])
        let service = PromptedSummaryService(model: OpenAISummaryModel(keys: InMemoryAPIKeyStore(key: openAISecret), transport: transport))
        let updater = SummaryUpdater(engine: engine, service: service,
                                     content: { _ in ConversationContent(messages: [TranscriptMessage(role: .user, text: "重構登入")], coverage: .complete) })
        await updater.run()
        #expect(engine.summary(of: id)?.backend == .openAIAPI)

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try NoteStore(directory: directory).save(engine.document)
        let exported = directory.appendingPathComponent("export/backup.json")
        try NoteStore.export(engine.document, to: exported)
        let defaults = scratchDefaults()
        AISettings(backend: .openAIAPI).save(to: defaults)

        for file in try FileManager.default.subpathsOfDirectory(atPath: directory.path).map({ directory.appendingPathComponent($0) })
            where !file.hasDirectoryPath {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(openAISecret))
        }
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains(openAISecret))
    }
}

@Suite("API key 不進資料檔與匯出檔")
@MainActor
struct APIKeyStaysOut {
    @Test("Claude API 寫過摘要後，notes.json、匯出檔與設定裡都沒有 key")
    func keyNotSaved() async throws {
        let engine = NoteEngine(screens: [laptop])
        engine.aiConversationKinds = [.code]
        engine.observe(.window(claude(login)))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.makeAINote(id)
        let keys = InMemoryAPIKeyStore(key: secret)
        let transport = StubTransport()
        transport.reply(text: "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
        let updater = SummaryUpdater(engine: engine, service: PromptedSummaryService(model: ClaudeAPISummaryModel(keys: keys, transport: transport)),
                                     content: { _ in ConversationContent(messages: [TranscriptMessage(role: .user, text: "重構登入")], coverage: .complete) })
        await updater.run()
        #expect(engine.summary(of: id)?.backend == .claudeAPI)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "x-api-key") == secret)

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        try store.save(engine.document)
        let exported = directory.appendingPathComponent("export/backup.json")
        try NoteStore.export(engine.document, to: exported)
        let defaults = scratchDefaults()
        AISettings(backend: .claudeAPI, noteColor: .sunset).save(to: defaults)

        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .map { directory.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath }
        #expect(!files.isEmpty)
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(secret), "key found in \(file.lastPathComponent)")
        }
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains(secret))
    }
}
