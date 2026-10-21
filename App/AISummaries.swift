import Foundation
import HintletCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The summary backends this Mac can use, and where AI notes read their conversations from.
enum AISummaries {
    /// Apple's on-device model, if this Mac has it ready (macOS 26 with Apple Intelligence on); nil hides AI
    /// notes altogether. Never the Private Cloud Compute model: nothing leaves the Mac.
    static func onDeviceService() -> (any SummaryService)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            return PromptedSummaryService(model: OnDeviceSummaryModel())
        }
        #endif
        return nil
    }

    /// Where the `claude` or `codex` the user signed in to is, if anywhere.
    static func locate(_ tool: SummaryTool, chosen: String?) -> URL? {
        CommandLocator.locate(tool, chosen: chosen, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// A summary service on the user's Claude or ChatGPT account, through its CLI. Without one found, every
    /// summary fails with a note saying so.
    static func accountService(_ tool: SummaryTool, at executable: URL?) -> any SummaryService {
        switch tool {
        case .claudeCode: PromptedSummaryService(model: ClaudeCodeSummaryModel(executable: executable, workingDirectory: cliFolder))
        case .codex: PromptedSummaryService(model: CodexSummaryModel(executable: executable, workingDirectory: cliFolder))
        }
    }

    /// An empty folder of our own for the CLIs to run in, so they never pick up a project's CLAUDE.md or AGENTS.md.
    /// Checks and signs in the account behind a CLI.
    static func account(_ tool: SummaryTool, at executable: URL?) -> AccountSignIn {
        AccountSignIn(tool: tool, executable: executable, workingDirectory: cliFolder)
    }

    private static let cliFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.jyp.hintlet/AI", isDirectory: true)

    /// The conversations AI notes can be made on with the backends here. Chat is read from its page, so
    /// only what the page has loaded (ticket 15). Codex threads from Codex's own files (ADR-0003).
    static let conversationKinds: Set<ConversationKind> = [.code, .cowork, .chat, .codex]

    /// How often a Chat conversation with an AI note is read while it shows, so its note can still be
    /// brought up to date once the user has moved on to another conversation (the page then shows that one).
    static let chatCaptureInterval: TimeInterval = 8

    /// How often AI notes look for a reply Claude has finished; a reply counts as finished once two looks
    /// in a row find the same.
    static let replyCheckInterval: TimeInterval = 6

    /// Code and Cowork transcripts, read from Claude's local files and never written to.
    static let transcripts = ClaudeTranscriptFiles(
        // The same folder as `ClaudePages.sessionFolder`, which belongs to the main actor.
        sessionFolder: ClaudeSessionFolder(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude")),
        claudeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    )

    private static let cache = TranscriptCache()

    /// Reads a conversation an AI note is on, away from the main thread. A transcript that hasn't changed
    /// since it was last read isn't read again (switching away from a conversation happens often).
    @Sendable static func content(of ref: ConversationRef) async throws -> ConversationContent {
        try await Task.detached(priority: .utility) {
            if ref.kind == .codex {
                let files = CodexPages.rollouts.files(for: ref.id)
                guard !files.isEmpty else { throw ClaudeTranscriptFiles.ReadError.notFound }
                return try await cache.content(of: files) { try CodexPages.rollouts.content(of: ref.id) }
            }
            guard let url = transcripts.transcript(for: ref) else { throw ClaudeTranscriptFiles.ReadError.notFound }
            return try await cache.content(of: [url]) { try ClaudeTranscriptFiles.content(at: url) }
        }.value
    }
}

/// The last read of each transcript (a Codex thread can take more than one file), by the files' sizes and
/// modification dates.
private actor TranscriptCache {
    private var entries: [[URL]: (stamp: [[FileAttributeKey: AnyHashable]], content: ConversationContent)] = [:]

    func content(of files: [URL], read: () throws -> ConversationContent) throws -> ConversationContent {
        let stamp: [[FileAttributeKey: AnyHashable]] = try files.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return [
                .size: attributes[.size] as? Int ?? -1,
                .modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
            ]
        }
        if let entry = entries[files], entry.stamp == stamp { return entry.content }
        let content = try read()
        entries[files] = (stamp, content)
        return content
    }
}

#if canImport(FoundationModels)
/// Foundation Models' system model, one fresh session per summary.
@available(macOS 26.0, *)
struct OnDeviceSummaryModel: SummaryModel {
    var backend: SummaryBackend { .onDevice }

    /// The context window is in tokens (4096 on macOS 26); Chinese takes about a token a character. What is
    /// left after the instructions and a three-line answer goes to the conversation.
    var promptBudget: Int {
        max(SystemLanguageModel.default.contextSize - 1200, 1000)
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            return try await session.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
            throw SummaryModelError.promptTooLong
        } catch {
            if #available(macOS 27.0, *), let error = error as? LanguageModelError, case .contextSizeExceeded = error {
                throw SummaryModelError.promptTooLong
            }
            throw error
        }
    }
}
#endif
