import Foundation

/// OpenAI's models through the Responses API with the user's own key. What it is given is uploaded to
/// OpenAI (and not kept there: `store` is off); the app only uses it after the user agreed to that.
public struct OpenAISummaryModel: SummaryModel {
    public static let model = "gpt-5.6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let keys: any APIKeyStore
    private let transport: any HTTPTransport

    public init(keys: any APIKeyStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.keys = keys
        self.transport = transport
    }

    public var backend: SummaryBackend { .openAIAPI }
    public var promptBudget: Int { 60_000 }

    public func respond(instructions: String, prompt: String) async throws -> String {
        let stored = (try? keys.read()) ?? nil
        guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw SummaryFailure.noAPIKey
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request(key: key, instructions: instructions, prompt: prompt))
        } catch is URLError {
            throw SummaryFailure.offline
        }
        try check(response.statusCode, data)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw SummaryFailure.unreadableResponse }
        let parts = reply.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        let text = parts.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        if text.isEmpty, parts.contains(where: { $0.type == "refusal" }) { throw SummaryFailure.refused }
        guard !text.isEmpty else { throw SummaryFailure.unreadableResponse }
        return text
    }

    private func request(key: String, instructions: String, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(
            model: Self.model, instructions: instructions, input: prompt, maxOutputTokens: 16_000,
            reasoning: .init(effort: "low"), store: false
        ))
        return request
    }

    private func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let detail = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
        let code = detail?.code ?? ""
        let message = detail?.message.lowercased() ?? ""
        switch status {
        case 401, 403: throw SummaryFailure.keyRejected
        case 413: throw SummaryModelError.promptTooLong
        case 400 where code == "context_length_exceeded" || message.contains("context window") || message.contains("context length"):
            throw SummaryModelError.promptTooLong
        case 429: throw SummaryFailure.rateLimited
        case 500...: throw SummaryFailure.serviceUnavailable
        default: throw SummaryFailure.requestFailed(status: status)
        }
    }

    private struct Body: Encodable {
        struct Reasoning: Encodable {
            let effort: String
        }

        let model: String
        let instructions: String
        let input: String
        let maxOutputTokens: Int
        let reasoning: Reasoning
        let store: Bool

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, reasoning, store
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let type: String
            let content: [Part]?
        }

        struct Part: Decodable {
            let type: String
            let text: String?
        }

        let output: [Item]
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            let message: String
            let code: String?
        }

        let error: Detail
    }
}
