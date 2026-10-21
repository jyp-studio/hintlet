import AppKit
import ApplicationServices
import HintletCore

/// Reads which conversation the Claude app shows, from the address of its web area (ADR-0001, spike 02).
/// Claude only builds its full Accessibility tree when asked to, which costs it some resources, so that
/// happens only once the user has agreed.
@MainActor
final class ClaudePages {
    nonisolated static let bundleID = "com.anthropic.claudefordesktop"
    private static let consentKey = "claudeAccessibilityConsent"
    /// Not among the AX constants AppKit exports.
    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let webAreaRole = "AXWebArea"
    /// Claude's tree takes a moment to fill in after it is first asked for (spike 02).
    static let treeDelay: TimeInterval = 0.6
    /// Bounds the search for web areas, so a huge page can't stall the main thread.
    private static let searchBudget = 2000
    private static let searchDepth = 40
    /// Far enough to climb from inside an artifact (four web areas deep, about 50 levels) to the window.
    private static let climbDepth = 80
    /// A busy Claude mustn't hold up the main thread.
    private static let messagingTimeout: Float = 0.25
    /// The page last read and its address then. Polling reads just that address (about 0.03 ms) instead of
    /// climbing from the focus again (about 4 ms).
    private var watchedPage: (area: AXUIElement, address: String?)?
    private var blindChecks = 0

    /// nil until the user has been asked.
    var consent: Bool? {
        get { UserDefaults.standard.object(forKey: Self.consentKey) as? Bool }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.consentKey)
            if newValue != true { webAreaCache = nil }
        }
    }

    /// When each Claude process was asked to build its tree; asked again after Claude restarts.
    private var enabledAt: [pid_t: Date] = [:]
    /// The web areas of the window last searched: found once, then only their addresses are read.
    private var webAreaCache: (window: AXUIElement, areas: [AXUIElement])?
    /// Cowork and Code session files, found once and re-read only when they change.
    private var sessionFiles: [ConversationRef: (url: URL, modified: Date, checked: Date, info: ClaudeSessionInfo)] = [:]
    /// A running Code session rewrites its file all the time; a rename can wait this long to show.
    private static let sessionRecheckInterval: TimeInterval = 5

    /// Asks Claude for its full tree, once per Claude process. Returns true if it was asked just now.
    @discardableResult
    func enable(in app: NSRunningApplication) -> Bool {
        guard consent == true, enabledAt[app.processIdentifier] == nil else { return false }
        enabledAt[app.processIdentifier] = Date()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, Self.manualAccessibilityAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// Asks a Claude whose tree stayed empty for it again, at most every few seconds. Returns true if it
    /// was asked just now.
    private func askAgain(in app: NSRunningApplication) -> Bool {
        guard let asked = enabledAt[app.processIdentifier], Date().timeIntervalSince(asked) >= Self.askAgainInterval else {
            return false
        }
        enabledAt[app.processIdentifier] = nil
        webAreaCache = nil
        return enable(in: app)
    }

    private static let askAgainInterval: TimeInterval = 3

    /// The tree was asked for only a moment ago and may still be empty.
    func isWarmingUp(_ app: NSRunningApplication) -> Bool {
        enabledAt[app.processIdentifier].map { Date().timeIntervalSince($0) < Self.treeDelay } ?? false
    }

    /// Explains what turning it on means and asks. Returns the answer, which is kept.
    func askForConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "讓便利貼認得 Claude 的對話")
        alert.informativeText = String(localized: """
        要把便利貼貼在某個 Claude 對話上，Hintlet 需要請 Claude 開啟完整的輔助使用資訊，才能知道目前顯示的是哪個對話。

        開啟後 Claude 會多用一些記憶體與處理器資源。Hintlet 只讀取對話的網址與標題；只有你開了 AI 便利貼的 Chat 對話，才會讀取頁面上已載入的訊息來寫摘要。

        不開啟的話，在 Claude 上的便利貼會綁在整個視窗。之後可以從選單列的 Hintlet 選單改變。
        """)
        alert.addButton(withTitle: String(localized: "開啟"))
        alert.addButton(withTitle: String(localized: "只用視窗範圍"))
        AppPresence.comeForward()
        let agreed = alert.runModal() == .alertFirstButtonReturn
        consent = agreed
        return agreed
    }

    /// The page shown in `window` of Claude; nil without consent or while the tree is still filling in
    /// (then conversation notes simply wait, rather than the page counting as unrecognized).
    func page(of app: NSRunningApplication, element: AXUIElement, window: AXUIElement) -> ClaudePage? {
        guard consent == true, enabledAt[app.processIdentifier] != nil, !isWarmingUp(app) else { return nil }
        let snapshot = snapshot(app: element, window: window)
        if snapshot.windows.allSatisfy(\.webAreas.isEmpty) {
            // A Claude that was only just launched when the tree was asked for may not have kept the
            // request: ask again, and let its notes wait for the tree instead of counting the page as unknown.
            if askAgain(in: app) { return nil }
        }
        let page = ClaudeIdentifier.page(in: snapshot)
        guard case .conversation(let ref, let title) = page else { return page }
        // Cowork and Code keep their names in their session files (spec); Chat only in the page.
        return .conversation(ref, title: sessionInfo(for: ref)?.title.nonEmpty ?? title)
    }

    /// Whether the page last read may show something else now: its address changed, or there was none to
    /// watch. Cheap enough to ask many times a second.
    func pageMayHaveChanged() -> Bool {
        guard let watched = watchedPage else {
            // Nothing to watch (the focus is outside the page): the full read, but only every fifth time.
            blindChecks += 1
            return blindChecks % 5 == 0
        }
        AXUIElementSetMessagingTimeout(watched.area, Self.messagingTimeout)
        return watched.area.address != watched.address
    }

    private func snapshot(app: AXUIElement, window: AXUIElement) -> ClaudeSnapshot {
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        var focused: ClaudeSnapshot.FocusedElement?
        // Only the focus inside this window says anything about it.
        if let element = app.elementAttribute(kAXFocusedUIElementAttribute),
           let owner = element.elementAttribute(kAXWindowAttribute), CFEqual(owner, window),
           let role: String = element.attribute(kAXRoleAttribute) {
            let page = pageWebArea(from: element)
            let address = page.flatMap(\.address)
            watchedPage = page.map { ($0, address) }
            focused = .init(role: role, nearestWebAreaURL: address)
        } else {
            watchedPage = nil
        }
        let areas = webAreas(in: window).map { area in
            let size = area.size ?? .zero
            return ClaudeSnapshot.WebArea(url: area.address, title: area.attribute(kAXTitleAttribute),
                                          frame: .init(x: 0, y: 0, width: size.width, height: size.height))
        }
        let windowSnapshot = ClaudeSnapshot.Window(focused: true, main: true, minimized: false, title: "",
                                                   frame: .init(x: 0, y: 0, width: 0, height: 0), webAreas: areas)
        return ClaudeSnapshot(focusedElement: focused, windows: [windowSnapshot])
    }

    /// The page the focus is in: the outermost web area above it. Content embedded in the page (an
    /// artifact or preview in the side panel is a web area of its own, at another address) doesn't
    /// change which conversation is showing.
    private func pageWebArea(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var outermost: AXUIElement?
        for _ in 0..<Self.climbDepth {
            guard let node = current else { break }
            AXUIElementSetMessagingTimeout(node, Self.messagingTimeout)
            let role: String? = node.attribute(kAXRoleAttribute)
            if role == kAXWindowRole as String { break }
            if role == Self.webAreaRole { outermost = node }
            current = node.elementAttribute(kAXParentAttribute)
        }
        return outermost
    }

    /// The window's web areas: from the cache while they are still there, else searched afresh.
    private func webAreas(in window: AXUIElement) -> [AXUIElement] {
        if let cache = webAreaCache, CFEqual(cache.window, window), !cache.areas.isEmpty,
           cache.areas.allSatisfy({ $0.attribute(kAXRoleAttribute) == Self.webAreaRole }) {
            return cache.areas
        }
        let areas = searchWebAreas(in: window)
        webAreaCache = (window, areas)
        return areas
    }

    private func searchWebAreas(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var next = 0
        while next < queue.count, next < Self.searchBudget {
            let (node, depth) = queue[next]
            next += 1
            AXUIElementSetMessagingTimeout(node, Self.messagingTimeout)
            if node.attribute(kAXRoleAttribute) == Self.webAreaRole {
                // A page's own contents hold no further pages worth reading.
                found.append(node)
                continue
            }
            guard depth < Self.searchDepth, let children: [AXUIElement] = node.attribute(kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return found
    }

    /// The page of Chat conversation `ref`, copied out of Claude, if a Claude window shows it now; nil
    /// otherwise (or without consent). Called only for conversations the user turned an AI note on for.
    func chatPage(showing ref: ConversationRef) async -> ChatPageNode? {
        guard consent == true, ref.kind == .chat, let area = webArea(showing: ref) else { return nil }
        return await ChatPageReader.copy(.init(element: area))
    }

    /// The web area showing `ref`: among those last found if it is there, else in any of Claude's windows.
    private func webArea(showing ref: ConversationRef) -> AXUIElement? {
        func shows(_ area: AXUIElement) -> Bool {
            AXUIElementSetMessagingTimeout(area, Self.messagingTimeout)
            return area.address.flatMap(ClaudeIdentifier.conversation(at:)) == ref
        }
        if let cached = webAreaCache?.areas.first(where: shows) { return cached }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              enabledAt[app.processIdentifier] != nil else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let windows: [AXUIElement] = element.attribute(kAXWindowsAttribute) ?? []
        return windows.lazy.flatMap { self.searchWebAreas(in: $0) }.first(where: shows)
    }

    /// What a Cowork or Code session's file says (its name, whether it is archived); nil for Chat, which
    /// keeps no local file, or when the file can't be found.
    func sessionInfo(for ref: ConversationRef) -> ClaudeSessionInfo? {
        let now = Date()
        if let known = sessionFiles[ref] {
            if now.timeIntervalSince(known.checked) < Self.sessionRecheckInterval { return known.info }
            let modified = Self.modificationDate(of: known.url)
            if modified == known.modified {
                sessionFiles[ref]?.checked = now
                return known.info
            }
            if let modified, let info = Self.readSession(at: known.url) {
                sessionFiles[ref] = (known.url, modified, now, info)
                return info
            }
        }
        guard let url = Self.findSessionFile(for: ref), let modified = Self.modificationDate(of: url),
              let info = Self.readSession(at: url) else { return nil }
        sessionFiles[ref] = (url, modified, now, info)
        return info
    }

    /// Where Claude keeps Cowork and Code sessions on this Mac.
    static let sessionFolder = ClaudeSessionFolder(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Claude"))

    private static func findSessionFile(for ref: ConversationRef) -> URL? {
        sessionFolder.file(for: ref)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func readSession(at url: URL) -> ClaudeSessionInfo? {
        (try? Data(contentsOf: url)).flatMap { try? ClaudeSessionInfo(json: $0) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension AXUIElement {
    /// A web area's address (AXURL).
    var address: String? {
        guard let value: AnyObject = attribute(kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    var size: CGSize? {
        guard let value: AnyObject = attribute(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
