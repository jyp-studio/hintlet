import Foundation

/// Which tab of the Claude app a conversation lives in, or `cli` for Claude Code in a terminal.
public enum ConversationKind: String, Codable, Sendable {
    case chat, cowork, code
    /// Claude Code run in Terminal or iTerm; the ID is its session ID, kept when the session is resumed.
    case cli
    /// A thread in the Codex app, by its thread ID; told only by a title no other thread has (ADR-0003).
    case codex
}

/// A Claude conversation, by the ID in its address; stable across restarts of either app (ADR-0001).
public struct ConversationRef: Hashable, Codable, Sendable {
    public let kind: ConversationKind
    /// As it appears in the address, e.g. a UUID for Chat, `local_<uuid>` for Cowork and Code.
    public let id: String

    public init(kind: ConversationKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// What the focused Claude window shows.
public enum ClaudePage: Equatable, Sendable {
    case conversation(ConversationRef, title: String)
    /// A new conversation not sent yet: it has no ID, so nothing can be bound to it.
    case draft
    /// Settings, shown over the current page: its conversation's notes step back until they close.
    case settings
    /// Anything else (projects, an unexpected address, an unclear page): notes fall back to the window.
    case unrecognized
}

/// The parts of Claude's Accessibility tree that identification needs, as recorded by
/// `Tools/claude-ax-probe.swift` (spike 02) and read live by the app.
public struct ClaudeSnapshot: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct FocusedElement: Codable, Sendable {
        public var role: String
        /// The address of the page the focused element is in (the outermost web area above it), if any.
        public var nearestWebAreaURL: String?

        public init(role: String, nearestWebAreaURL: String?) {
            self.role = role
            self.nearestWebAreaURL = nearestWebAreaURL
        }
    }

    public struct WebArea: Codable, Sendable {
        public var url: String?
        public var title: String?
        public var frame: Frame

        public init(url: String?, title: String?, frame: Frame) {
            self.url = url
            self.title = title
            self.frame = frame
        }
    }

    public struct Window: Codable, Sendable {
        public var focused: Bool
        public var main: Bool
        public var minimized: Bool
        public var title: String
        public var frame: Frame
        public var webAreas: [WebArea]

        public init(focused: Bool, main: Bool, minimized: Bool, title: String, frame: Frame, webAreas: [WebArea]) {
            self.focused = focused
            self.main = main
            self.minimized = minimized
            self.title = title
            self.frame = frame
            self.webAreas = webAreas
        }
    }

    public var focusedElement: FocusedElement?
    public var windows: [Window]

    public init(focusedElement: FocusedElement?, windows: [Window]) {
        self.focusedElement = focusedElement
        self.windows = windows
    }
}

/// Tells which page the focused Claude window shows, from the address of its web area. Never guesses:
/// anything unclear is `.unrecognized`, and notes fall back to the window.
public enum ClaudeIdentifier {
    static let host = "claude.ai"
    /// Web area titles are the conversation's name plus one of these.
    static let titleSuffixes = [" - Claude Code", " - Claude"]

    public static func page(in snapshot: ClaudeSnapshot) -> ClaudePage {
        guard let window = snapshot.windows.first(where: \.focused) ?? snapshot.windows.first(where: \.main) else {
            return .unrecognized
        }
        // Claude's own app shell is a web area too (a file:// page as large as the window); only pages on
        // Claude's site say which conversation is showing.
        let visible = window.webAreas.filter { $0.frame.width > 0 && $0.frame.height > 0 && isOnSite($0.url) }
        let onlyVisible = visible.count == 1 ? visible[0].url : nil
        let fromFocus = snapshot.focusedElement?.nearestWebAreaURL.flatMap { isOnSite($0) ? $0 : nil }
        if let fromFocus, let onlyVisible, fromFocus != onlyVisible { return .unrecognized }
        guard let address = fromFocus ?? onlyVisible else { return .unrecognized }
        let title = window.webAreas.first { $0.url == address }?.title ?? ""
        return page(address: address, webAreaTitle: title)
    }

    private static func isOnSite(_ address: String?) -> Bool {
        address.flatMap { URLComponents(string: $0)?.host } == host
    }

    /// The conversation a page address shows, if it shows one.
    public static func conversation(at address: String) -> ConversationRef? {
        if case .conversation(let ref, _) = page(address: address, webAreaTitle: "") { ref } else { nil }
    }

    static func page(address: String, webAreaTitle: String) -> ClaudePage {
        guard let url = URLComponents(string: address), url.host == host else { return .unrecognized }
        if url.fragment?.hasPrefix("settings") == true { return .settings }
        let parts = url.path.split(separator: "/").map(String.init)
        switch parts.count {
        case 1 where ["new", "epitaxy"].contains(parts[0]):
            return .draft
        case 2 where parts == ["task", "new"]:
            return .draft
        case 2:
            guard let ref = conversation(section: parts[0], id: parts[1]) else { return .unrecognized }
            return .conversation(ref, title: conversationTitle(from: webAreaTitle))
        default:
            return .unrecognized
        }
    }

    private static func conversation(section: String, id: String) -> ConversationRef? {
        let isUUID = UUID(uuidString: id) != nil
        let isLocalUUID = id.hasPrefix("local_") && UUID(uuidString: String(id.dropFirst("local_".count))) != nil
        switch section {
        case "chat" where isUUID: return ConversationRef(kind: .chat, id: id)
        case "cowork" where isUUID || isLocalUUID: return ConversationRef(kind: .cowork, id: id)
        case "epitaxy" where isLocalUUID: return ConversationRef(kind: .code, id: id)
        default: return nil
        }
    }

    private static func conversationTitle(from webAreaTitle: String) -> String {
        for suffix in titleSuffixes where webAreaTitle.hasSuffix(suffix) {
            return String(webAreaTitle.dropLast(suffix.count))
        }
        return webAreaTitle
    }
}

/// What a Cowork or Code session file (`…/local_<id>.json`) says about the session.
public struct ClaudeSessionInfo: Equatable, Sendable {
    public var title: String
    public var isArchived: Bool

    public init(title: String, isArchived: Bool) {
        self.title = title
        self.isArchived = isArchived
    }

    public init(json: Data) throws {
        struct File: Decodable {
            var title: String?
            var isArchived: Bool?
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        self.init(title: file.title ?? "", isArchived: file.isArchived ?? false)
    }
}
