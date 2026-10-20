import Foundation
import Testing
import StickyContextCore

private let testKey = "sk-proj-test-0000-not-a-real-key"

private func model(_ transport: StubTransport, key: String? = testKey) -> OpenAISummaryModel {
    OpenAISummaryModel(keys: InMemoryAPIKeyStore(key: key), transport: transport)
}

private extension StubTransport {
    func openAIReply(_ text: String) {
        status = 200
        body = try! JSONSerialization.data(withJSONObject: [
            "object": "response", "status": "completed",
            "output": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text, "annotations": []]]],
            ],
        ])
    }

    func openAIError(_ status: Int, code: String?, message: String) {
        self.status = status
        var detail: [String: Any] = ["message": message, "type": "invalid_request_error"]
        if let code { detail["code"] = code }
        body = try! JSONSerialization.data(withJSONObject: ["error": detail])
    }
}

@Suite("OpenAI API：送出的請求")
struct OpenAIRequests {
    @Test("POST 到 Responses API，帶 Bearer key；指示放 instructions，對話放 input，不讓 OpenAI 保存")
    func request() async throws {
        let transport = StubTransport()
        transport.openAIReply("正在做什麼：a\n停在哪裡：b\n下一步：c")

        _ = try await model(transport).respond(instructions: "寫三行", prompt: "對話內容")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = transport.lastBody
        #expect(body["model"] as? String == OpenAISummaryModel.model)
        #expect(body["instructions"] as? String == "寫三行")
        #expect(body["input"] as? String == "對話內容")
        #expect(body["store"] as? Bool == false)
        #expect((body["max_output_tokens"] as? Int ?? 0) > 0)
    }

    @Test("讀出 message 裡的 output_text，推理區塊不算")
    func readsText() async throws {
        let transport = StubTransport()
        transport.openAIReply("正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
        #expect(try await model(transport).respond(instructions: "i", prompt: "p") == "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
    }

    @Test("後端是 OpenAI API")
    func backend() {
        #expect(model(StubTransport()).backend == .openAIAPI)
    }
}

@Suite("OpenAI API：失敗")
struct OpenAIFailures {
    @Test("沒有 key 就不送出")
    func noKey() async {
        let transport = StubTransport()
        await #expect(throws: SummaryFailure.noAPIKey) {
            _ = try await model(transport, key: " ").respond(instructions: "i", prompt: "p")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("401 與 403：key 無效或沒有權限")
    func rejected() async {
        for status in [401, 403] {
            let transport = StubTransport()
            transport.openAIError(status, code: "invalid_api_key", message: "Incorrect API key provided: \(testKey)")
            do {
                _ = try await model(transport).respond(instructions: "i", prompt: "p")
                Issue.record("should fail")
            } catch {
                #expect(error as? SummaryFailure == .keyRejected)
                #expect(!String(describing: error).contains(testKey))
            }
        }
    }

    @Test("429（含額度用完）：用量達上限")
    func rateLimited() async {
        for code in ["rate_limit_exceeded", "insufficient_quota"] {
            let transport = StubTransport()
            transport.openAIError(429, code: code, message: "limit")
            await #expect(throws: SummaryFailure.rateLimited) {
                _ = try await model(transport).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("context_length_exceeded 與 413：交給摘要服務縮短再試")
    func tooLong() async {
        let long = StubTransport()
        long.openAIError(400, code: "context_length_exceeded", message: "Your input exceeds the context window of this model.")
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await model(long).respond(instructions: "i", prompt: "p")
        }
        let large = StubTransport()
        large.openAIError(413, code: nil, message: "Request too large")
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await model(large).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("5xx、其他 400、連不上網路")
    func others() async {
        let busy = StubTransport()
        busy.openAIError(503, code: nil, message: "overloaded")
        await #expect(throws: SummaryFailure.serviceUnavailable) {
            _ = try await model(busy).respond(instructions: "i", prompt: "p")
        }
        let bad = StubTransport()
        bad.openAIError(400, code: "invalid_value", message: "bad")
        await #expect(throws: SummaryFailure.requestFailed(status: 400)) {
            _ = try await model(bad).respond(instructions: "i", prompt: "p")
        }
        let offline = StubTransport()
        offline.failure = URLError(.notConnectedToInternet)
        await #expect(throws: SummaryFailure.offline) {
            _ = try await model(offline).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("拒絕回答與看不懂的回覆")
    func refusalAndUnreadable() async {
        let refused = StubTransport()
        refused.body = try! JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [["type": "message", "role": "assistant", "content": [["type": "refusal", "refusal": "I can't help"]]]],
        ])
        await #expect(throws: SummaryFailure.refused) {
            _ = try await model(refused).respond(instructions: "i", prompt: "p")
        }
        let garbage = StubTransport()
        garbage.body = Data("<html>".utf8)
        await #expect(throws: SummaryFailure.unreadableResponse) {
            _ = try await model(garbage).respond(instructions: "i", prompt: "p")
        }
    }
}

@Suite("各個後端：哪些會上傳")
struct BackendUploads {
    @Test("只有裝置端模型不上傳，其他四個都會")
    func uploads() {
        #expect(!SummaryBackend.onDevice.uploadsContent)
        for backend in [SummaryBackend.claudeAccount, .codexAccount, .claudeAPI, .openAIAPI] {
            #expect(backend.uploadsContent, "\(backend.rawValue)")
        }
    }
}
