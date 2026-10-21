import Foundation

/// A piece of a Chat page's Accessibility tree, copied out of Claude so it can be read away from it.
public struct ChatPageNode: Equatable, Sendable {
    public var role: String
    /// AXValue, for text.
    public var value: String?
    /// AXTitle or AXDescription.
    public var title: String?
    /// AXDOMClassList.
    public var classes: [String]
    public var children: [ChatPageNode]

    public init(role: String, value: String? = nil, title: String? = nil, classes: [String] = [], children: [ChatPageNode] = []) {
        self.role = role
        self.value = value
        self.title = title
        self.classes = classes
        self.children = children
    }
}

/// Where AI notes on Chat read their conversation from: the page while Claude shows it, or else what it
/// had loaded when last read. Only conversations the user turned an AI note on for are ever read.
public actor ChatReadings {
    public enum ReadError: Error, Equatable {
        /// The conversation has no AI note: its page is not read.
        case notTurnedOn
        /// Claude doesn't show it (or its page has no messages to tell apart yet), and nothing was read
        /// from it while it did.
        case notShown
    }

    private let isTurnedOn: @Sendable (ConversationRef) async -> Bool
    private let readPage: @Sendable (ConversationRef) async -> ChatPageNode?
    private var lastRead: [ConversationRef: ConversationContent] = [:]

    /// `readPage` gives the conversation's page if Claude shows it now, else nil.
    public init(isTurnedOn: @escaping @Sendable (ConversationRef) async -> Bool,
                readPage: @escaping @Sendable (ConversationRef) async -> ChatPageNode?) {
        self.isTurnedOn = isTurnedOn
        self.readPage = readPage
    }

    /// Reads the conversation while it shows, so its AI note can still be brought up to date after the
    /// user has moved on (by then the page shows something else). Does nothing for one without an AI note.
    public func capture(_ ref: ConversationRef) async {
        _ = try? await read(ref)
    }

    /// What the conversation has loaded now, or had when last read.
    public func content(of ref: ConversationRef) async throws -> ConversationContent {
        if let content = try await read(ref) { return content }
        guard let last = lastRead[ref] else { throw ReadError.notShown }
        return last
    }

    /// The page's messages now, if it shows; nil if it doesn't or had none to tell apart.
    private func read(_ ref: ConversationRef) async throws -> ConversationContent? {
        guard await isTurnedOn(ref) else {
            lastRead[ref] = nil
            throw ReadError.notTurnedOn
        }
        guard let page = await readPage(ref), let content = try? ChatPage.content(of: page) else { return nil }
        lastRead[ref] = content
        return content
    }
}

/// What a Chat conversation's page has loaded (spike 04). Chat keeps no local transcript and unloads
/// messages far above what is on screen, so a summary is only ever based on the messages loaded when the
/// page was read, and says how many; nothing is scrolled to load more.
public enum ChatPage {
    public enum ReadError: Error, Equatable {
        /// No message could be told apart on the page: it is still loading, or Claude's page changed.
        /// Reported as such, never guessed around.
        case noMessages
    }

    static let userBubbleClass = "bg-user-message"
    static let replyRowClass = "group/message-row"
    /// The hidden headings before each message: English strings for screen readers, steadier than the classes.
    static let userHeading = "You said"
    static let replyHeading = "Claude responded"
    /// Below this many letters from the user in all, the conversation says too little for a summary (a
    /// greeting), however long Claude's answer to it.
    static let minimumUserCharacters = 6

    public static func content(of page: ChatPageNode) throws -> ConversationContent {
        var messages: [TranscriptMessage] = []
        collect(page, into: &messages)
        if messages.isEmpty { collectByHeadings(page, into: &messages) }
        guard !messages.isEmpty else { throw ReadError.noMessages }
        let asked = messages.filter { $0.role == .user }
            .reduce(0) { $0 + $1.text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count }
        let coverage: SummaryCoverage = asked < minimumUserCharacters ? .insufficient : .partial(loadedMessages: messages.count)
        return ConversationContent(messages: messages, coverage: coverage)
    }

    private static func collect(_ node: ChatPageNode, into messages: inout [TranscriptMessage]) {
        let role: TranscriptMessage.Role? = if node.classes.contains(where: { $0.contains(userBubbleClass) }) {
            .user
        } else if node.classes.contains(replyRowClass) {
            .assistant
        } else {
            nil
        }
        guard let role else {
            node.children.forEach { collect($0, into: &messages) }
            return
        }
        messages.append(TranscriptMessage(role: role, text: text(of: node)))
    }

    /// Without the classes: a user message is what its heading says after "You said:"; Claude's reply is
    /// what the group holding its heading says.
    private static func collectByHeadings(_ node: ChatPageNode, into messages: inout [TranscriptMessage]) {
        for child in node.children {
            guard child.role == "AXHeading" else {
                collectByHeadings(child, into: &messages)
                continue
            }
            let label = text(inside: child)
            if label.hasPrefix(replyHeading) {
                messages.append(TranscriptMessage(role: .assistant, text: text(of: node)))
                return
            }
            if label.hasPrefix(userHeading) {
                let said = label.dropFirst(userHeading.count).drop { $0 == ":" || $0 == "：" || $0.isWhitespace }
                messages.append(TranscriptMessage(role: .user, text: String(said)))
            }
        }
    }

    private static func text(inside heading: ChatPageNode) -> String {
        let own = heading.value ?? heading.title ?? ""
        return own + heading.children.map(text(inside:)).joined()
    }

    /// The words in a message: text runs side by side make one paragraph, separate blocks go on lines of
    /// their own. The hidden headings and the buttons (copy, retry, edit) aren't part of what was said.
    private static func text(of node: ChatPageNode) -> String {
        if node.role == "AXStaticText" { return node.value ?? "" }
        if ["AXHeading", "AXButton"].contains(node.role) { return "" }
        let parts = node.children.map(text(of:)).filter { !$0.isEmpty }
        let isParagraph = node.children.allSatisfy { $0.role == "AXStaticText" }
        return parts.joined(separator: isParagraph ? "" : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
