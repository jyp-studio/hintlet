import ApplicationServices
import HintletCore

/// Copies a Chat page out of Claude's Accessibility tree, away from the main thread (a long conversation
/// is thousands of elements). Only what telling messages apart needs: roles, text, headings' labels and
/// the page's classes. Nothing is scrolled or clicked: what the page has loaded is all there is (spike 04).
enum ChatPageReader {
    /// An element handed to the reading thread. AX elements may be used from any thread.
    struct Element: @unchecked Sendable {
        let element: AXUIElement
    }

    /// Bounds the copy, so a huge page can't keep Claude busy for long.
    private static let elementBudget = 40_000
    private static let maximumDepth = 120
    private static let messagingTimeout: Float = 0.25

    static func copy(_ page: Element) async -> ChatPageNode? {
        await Task.detached(priority: .utility) {
            var budget = elementBudget
            return node(page.element, depth: 0, isPage: true, budget: &budget)
        }.value
    }

    private static func node(_ element: AXUIElement, depth: Int, isPage: Bool, budget: inout Int) -> ChatPageNode? {
        guard budget > 0 else { return nil }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard let role: String = element.attribute(kAXRoleAttribute) else { return nil }
        // An artifact or preview inside the page is a page of its own, not part of what was said.
        if role == "AXWebArea", !isPage { return nil }
        var copied = ChatPageNode(role: role)
        if role == kAXStaticTextRole as String {
            copied.value = element.attribute(kAXValueAttribute)
            return copied
        }
        copied.title = element.attribute(kAXTitleAttribute) ?? element.attribute(kAXDescriptionAttribute)
        copied.classes = element.attribute("AXDOMClassList") ?? []
        guard depth < maximumDepth, let children: [AXUIElement] = element.attribute(kAXChildrenAttribute) else { return copied }
        for child in children {
            guard budget > 0 else { break }
            if let node = node(child, depth: depth + 1, isPage: false, budget: &budget) { copied.children.append(node) }
        }
        return copied
    }
}
