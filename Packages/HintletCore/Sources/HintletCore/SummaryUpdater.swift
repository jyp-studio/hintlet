import Foundation

/// Writes the summaries the engine asks for, one at a time: reads the conversation (only those with an AI
/// note), asks the summary service, and puts the result on the AI note. An automatic refresh of a
/// conversation that hasn't changed since its last summary doesn't ask the model at all.
@MainActor
public final class SummaryUpdater {
    private let engine: NoteEngine
    /// Swappable while running (ticket 16: the Claude API instead of the on-device model).
    public var service: any SummaryService
    private let content: @Sendable (ConversationRef) async throws -> ConversationContent
    /// Called whenever a note's summary or status changed, to redraw and save.
    public var onChange: () -> Void = {}
    private var isRunning = false
    /// What each AI note's conversation read the last time new replies were looked for: a reply counts as
    /// finished once a look finds the same as the one before.
    private var lastLook: [NoteID: String] = [:]

    /// `content` reads a conversation the user turned an AI note on for; it is never called for any other.
    public init(engine: NoteEngine, service: any SummaryService,
                content: @escaping @Sendable (ConversationRef) async throws -> ConversationContent) {
        self.engine = engine
        self.service = service
        self.content = content
    }

    /// Works through everything the engine has asked for, including what it asks for meanwhile. Returns
    /// at once if a run is going already (that run picks the new requests up).
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while case let requests = engine.takeSummaryRequests(), !requests.isEmpty {
            for request in requests { await write(request) }
        }
    }

    private func write(_ request: SummaryRequest) async {
        if request.waitsToSettle {
            await writeIfSettled(request)
            return
        }
        let id = request.noteID
        engine.summaryStarted(id)
        onChange()
        let previous = engine.summary(of: id)
        do {
            let conversation = try await content(request.conversation)
            if !request.isManual, let previous, previous.sourceRevision == conversation.revision,
               previous.backend == service.backend {
                // Nothing new since the last summary.
                engine.summaryUpToDate(id)
            } else {
                let summary = try await service.summarize(conversation, previous: previous)
                // The engine only puts it on a note that is still an AI note.
                engine.applySummary(summary, to: id)
            }
        } catch {
            engine.summaryFailed(id, because: error as? SummaryFailure)
        }
        onChange()
    }

    /// Quietly, unless there is something to write: a finished reply (the last message is Claude's, the
    /// same as at the last look) the summary doesn't cover yet.
    private func writeIfSettled(_ request: SummaryRequest) async {
        let id = request.noteID
        guard let conversation = try? await content(request.conversation) else { return }
        let previousLook = lastLook.updateValue(conversation.revision, forKey: id)
        let summary = engine.summary(of: id)
        guard previousLook == conversation.revision, conversation.messages.last?.role == .assistant,
              summary?.sourceRevision != conversation.revision || summary?.backend != service.backend else { return }
        engine.summaryStarted(id)
        onChange()
        do {
            engine.applySummary(try await service.summarize(conversation, previous: summary), to: id)
        } catch {
            engine.summaryFailed(id, because: error as? SummaryFailure)
        }
        onChange()
    }
}
