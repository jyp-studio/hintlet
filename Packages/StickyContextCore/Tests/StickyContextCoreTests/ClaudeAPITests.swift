import CoreGraphics
import Foundation
import Testing
import StickyContextCore

/// Answers every request with what the test says, and keeps what was sent. Nothing goes on the network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var body = Data()
    var failure: (any Error)?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func reply(text: String, stopReason: String = "end_turn") {
        status = 200
        body = try! JSONSerialization.data(withJSONObject: [
            "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": stopReason,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
        ])
    }

    func error(_ status: Int, type: String, message: String) {
        self.status = status
        body = try! JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": type, "message": message],
        ])
    }

    var lastBody: [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests.last?.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

/// The keychain, in memory: tests never touch the real one.
final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    var key: String?
    var readFailure: (any Error)?

    init(key: String? = nil) {
        self.key = key
    }

    func read() throws -> String? {
        if let readFailure { throw readFailure }
        return key
    }

    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}

private let testKey = "sk-ant-test-0000-not-a-real-key"

private func model(_ transport: StubTransport, key: String? = testKey) -> ClaudeAPISummaryModel {
    ClaudeAPISummaryModel(keys: InMemoryAPIKeyStore(key: key), transport: transport)
}

@Suite("Claude API：送出的請求")
struct ClaudeAPIRequests {
    @Test("POST 到 Messages API，帶使用者的 key 與 API 版本，使用目前最新的模型")
    func request() async throws {
        let transport = StubTransport()
        transport.reply(text: "正在做什麼：a\n停在哪裡：b\n下一步：c")

        _ = try await model(transport).respond(instructions: "寫三行", prompt: "對話內容")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == testKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = transport.lastBody
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "寫三行")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "對話內容")
        #expect((body["max_tokens"] as? Int ?? 0) > 0)
    }

    @Test("只用告訴使用者的那個模型：不要求伺服器改用別的模型重試")
    func noFallbackModel() async throws {
        let transport = StubTransport()
        transport.reply(text: "x\ny\nz")

        _ = try await model(transport).respond(instructions: "i", prompt: "p")

        #expect(transport.lastBody["fallbacks"] == nil)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test("回覆裡的文字區塊合起來就是答案，思考區塊不算")
    func readsText() async throws {
        let transport = StubTransport()
        transport.reply(text: "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")

        let reply = try await model(transport).respond(instructions: "i", prompt: "p")

        #expect(reply == "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
    }

    @Test("後端是 Claude API；提示預算比裝置端模型大很多")
    func backend() {
        let model = model(StubTransport())
        #expect(model.backend == .claudeAPI)
        #expect(model.promptBudget >= 20_000)
    }
}

@Suite("Claude API：失敗")
struct ClaudeAPIFailures {
    @Test("沒有 key 就不送出，回報「尚未填入 API key」")
    func noKey() async {
        let transport = StubTransport()
        await #expect(throws: SummaryFailure.noAPIKey) {
            _ = try await model(transport, key: nil).respond(instructions: "i", prompt: "p")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("空白的 key 等於沒有 key")
    func blankKey() async {
        let transport = StubTransport()
        await #expect(throws: SummaryFailure.noAPIKey) {
            _ = try await model(transport, key: "  \n").respond(instructions: "i", prompt: "p")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("讀不到鑰匙圈也算沒有 key")
    func unreadableKeychain() async {
        let transport = StubTransport()
        let keys = InMemoryAPIKeyStore(key: testKey)
        keys.readFailure = CocoaError(.fileReadNoPermission)
        await #expect(throws: SummaryFailure.noAPIKey) {
            _ = try await ClaudeAPISummaryModel(keys: keys, transport: transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("401 與 403：key 無效或沒有權限")
    func rejectedKey() async {
        for status in [401, 403] {
            let transport = StubTransport()
            transport.error(status, type: "authentication_error", message: "invalid x-api-key")
            await #expect(throws: SummaryFailure.keyRejected) {
                _ = try await model(transport).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("429：用量達上限")
    func rateLimited() async {
        let transport = StubTransport()
        transport.error(429, type: "rate_limit_error", message: "slow down")
        await #expect(throws: SummaryFailure.rateLimited) {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("5xx 與 529：服務暫時無法使用")
    func unavailable() async {
        for status in [500, 503, 529] {
            let transport = StubTransport()
            transport.error(status, type: "overloaded_error", message: "Overloaded")
            await #expect(throws: SummaryFailure.serviceUnavailable) {
                _ = try await model(transport).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("413 或「prompt is too long」：交給摘要服務縮短再試")
    func tooLong() async {
        let large = StubTransport()
        large.error(413, type: "request_too_large", message: "Request exceeds the maximum allowed number of bytes.")
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await model(large).respond(instructions: "i", prompt: "p")
        }
        let long = StubTransport()
        long.error(400, type: "invalid_request_error", message: "prompt is too long: 1200000 tokens > 1000000 maximum")
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await model(long).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("其他 400：請求被拒，附上狀態碼")
    func otherRequestErrors() async {
        let transport = StubTransport()
        transport.error(400, type: "invalid_request_error", message: "something else")
        await #expect(throws: SummaryFailure.requestFailed(status: 400)) {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("連不上網路")
    func offline() async {
        let transport = StubTransport()
        transport.failure = URLError(.notConnectedToInternet)
        await #expect(throws: SummaryFailure.offline) {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("模型拒絕回答（stop_reason refusal）")
    func refusal() async {
        let transport = StubTransport()
        transport.reply(text: "", stopReason: "refusal")
        await #expect(throws: SummaryFailure.refused) {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("看不懂的回覆")
    func unreadable() async {
        let transport = StubTransport()
        transport.body = Data("<html>".utf8)
        await #expect(throws: SummaryFailure.unreadableResponse) {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("錯誤訊息裡不會出現 key")
    func keyNotInErrors() async {
        let transport = StubTransport()
        transport.error(401, type: "authentication_error", message: "invalid x-api-key \(testKey)")
        do {
            _ = try await model(transport).respond(instructions: "i", prompt: "p")
        } catch {
            #expect(!String(describing: error).contains(testKey))
        }
    }
}

@Suite("Claude API：當作摘要服務")
struct ClaudeAPISummaries {
    private let work = [
        TranscriptMessage(role: .user, text: "幫我重構登入流程"),
        TranscriptMessage(role: .assistant, text: "我先把 session 處理抽出來。"),
    ]

    @Test("包進 PromptedSummaryService：三行摘要標記為 Claude API 寫的")
    func summary() async throws {
        let transport = StubTransport()
        transport.reply(text: "正在做什麼：重構登入\n停在哪裡：抽出 session\n下一步：補測試")
        let service = PromptedSummaryService(model: model(transport))

        let summary = try await service.summarize(ConversationContent(messages: work, coverage: .complete), previous: nil)

        #expect(summary.backend == .claudeAPI)
        #expect(summary.stoppedAt == "抽出 session")
        #expect((transport.lastBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? "" != "")
    }

    @Test("提示太長時摘要服務以一半預算再試一次")
    func retriesShorter() async throws {
        let transport = StubTransport()
        transport.error(413, type: "request_too_large", message: "too large")
        let service = PromptedSummaryService(model: model(transport))

        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await service.summarize(ConversationContent(messages: work, coverage: .complete), previous: nil)
        }
        #expect(transport.requests.count == 2)
    }
}
