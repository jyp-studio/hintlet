import Foundation

/// Sends one HTTP request. The app uses URLSession; tests answer with a stub, so nothing goes on the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Where the user's API key (Claude or OpenAI) is kept: the Keychain in the app, memory in tests. Never the notes file.
public protocol APIKeyStore: Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

/// Why a summary couldn't be written, as far as the note can tell the user.
public enum SummaryFailure: Error, Equatable, Sendable {
    /// An API backend is chosen but no key has been entered.
    case noAPIKey
    /// The key was refused (wrong, revoked, or without access).
    case keyRejected
    case rateLimited
    case serviceUnavailable
    case offline
    /// The model declined to answer.
    case refused
    case unreadableResponse
    case requestFailed(status: Int)
    /// The CLI of an account backend isn't installed, or couldn't be started.
    case toolNotFound(SummaryTool)
    /// The CLI is there but not signed in (or its sign-in expired).
    case notSignedIn(SummaryTool)
    /// The CLI failed for some other reason.
    case toolFailed(SummaryTool)
    /// No answer in time.
    case timedOut
}

/// The CLIs the account backends run.
public enum SummaryTool: String, Equatable, Sendable {
    case claudeCode, codex
}

/// Claude through the Messages API with the user's own key. What it is given is uploaded to Anthropic;
/// the app only uses it after the user agreed to that.
public struct ClaudeAPISummaryModel: SummaryModel {
    /// The newest Claude model.
    public static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let keys: any APIKeyStore
    private let transport: any HTTPTransport

    public init(keys: any APIKeyStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.keys = keys
        self.transport = transport
    }

    public var backend: SummaryBackend { .claudeAPI }

    /// The context window is far larger than this; the prompt is kept to what a progress note needs.
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
        if reply.stopReason == "refusal" { throw SummaryFailure.refused }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw SummaryFailure.unreadableResponse }
        return text
    }

    private func request(key: String, instructions: String, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(Body(
            model: Self.model, maxTokens: 16_000, system: instructions,
            messages: [.init(role: "user", content: prompt)],
            outputConfig: .init(effort: "low")
        ))
        return request
    }

    private func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message.lowercased() ?? ""
        switch status {
        case 401, 403: throw SummaryFailure.keyRejected
        case 413: throw SummaryModelError.promptTooLong
        case 400 where message.contains("prompt is too long"): throw SummaryModelError.promptTooLong
        case 429: throw SummaryFailure.rateLimited
        case 500...: throw SummaryFailure.serviceUnavailable
        default: throw SummaryFailure.requestFailed(status: status)
        }
    }

    private struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let outputConfig: OutputConfig

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }
}
