import AppKit
import HintletCore

/// Which thread a Codex window shows (ADR-0003): its page's title, matched against the thread names Codex keeps
/// in `~/.codex/session_index.jsonl`. Only a name no other thread has counts.
///
/// Codex is an Electron app and shows its page to Accessibility only once asked to (`AXManualAccessibility`);
/// that takes about a second, during which its notes wait. Only the page's title is read.
@MainActor
final class CodexPages {
    static let bundleID = CodexThreads.bundleID
    nonisolated static let rollouts = CodexRolloutFiles(
        codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))

    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    /// The page is deep in the tree; this is well past it, and keeps a strange tree from being walked whole.
    private static let searchDepth = 30

    private var enabled: Set<pid_t> = []
    private var index = CodexThreadIndex(jsonl: Data())
    private var indexStamp: [FileAttributeKey: AnyHashable] = [:]
    /// The page area last found, with the window it is in.
    private var webArea: (window: AXUIElement, area: AXUIElement)?

    /// The thread `window` shows; nil when it can't be told, and its notes go on the window.
    func page(of app: NSRunningApplication, in window: AXUIElement) -> ClaudePage? {
        if enabled.insert(app.processIdentifier).inserted {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, Self.manualAccessibilityAttribute as CFString, kCFBooleanTrue)
        }
        guard let area = area(in: window) else { return nil }
        let title: String? = area.attribute(kAXTitleAttribute)
        return CodexThreads.page(title: title, index: currentIndex())
    }

    /// The index again only when Codex has written to it since.
    private func currentIndex() -> CodexThreadIndex {
        let url = Self.rollouts.sessionIndex
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return index }
        let stamp: [FileAttributeKey: AnyHashable] = [
            .size: attributes[.size] as? Int ?? -1,
            .modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
        ]
        if stamp != indexStamp, let data = try? Data(contentsOf: url) {
            index = CodexThreadIndex(jsonl: data)
            indexStamp = stamp
        }
        return index
    }

    private func area(in window: AXUIElement) -> AXUIElement? {
        if let webArea, CFEqual(webArea.window, window), (webArea.area.attribute(kAXRoleAttribute) as String?) == "AXWebArea" {
            return webArea.area
        }
        guard let found = Self.findWebArea(in: window, depth: 0) else { return nil }
        webArea = (window, found)
        return found
    }

    private static func findWebArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if (element.attribute(kAXRoleAttribute) as String?) == "AXWebArea" { return element }
        guard depth < searchDepth, let children: [AXUIElement] = element.attribute(kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = findWebArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
