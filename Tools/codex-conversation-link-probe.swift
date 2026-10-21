// Usage: swift Tools/codex-conversation-link-probe.swift --copy-deeplink [--expect <thread-uuid>]
// Uses the focused chat's own menu, not the broadcast Copy deeplink shortcut.
// Research only: use validated local threads and do not interact with the app or clipboard while running.
// General pasteboard change counts do not prove authorship; this is not a production identifier.
import AppKit
import ApplicationServices
import CryptoKit

// The app already uses this to distinguish native windows from changing AX references.
@_silgen_name("_AXUIElementGetWindow")
private func axWindowNumber(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowNumber(_ element: AXUIElement) -> CGWindowID? {
    var number: CGWindowID = 0
    guard axWindowNumber(element, &number) == .success, number != 0 else { return nil }
    return number
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func descendants(_ root: AXUIElement) -> [AXUIElement]? {
    var queue = [root]
    var next = 0
    while next < queue.count {
        let element = queue[next]
        next += 1
        AXUIElementSetMessagingTimeout(element, 0.2)
        // In this tested shell, chat headers and portal menus are outside the message panel.
        // This sparse traversal is for controlled single-pane research, not proof of pane uniqueness.
        let identifier = attribute(element, "AXDOMIdentifier") as? String ?? ""
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if identifier == "app-shell-sidebar" || identifier.hasSuffix("-chat-panel")
            || ["AXStaticText", "AXTextArea", "AXImage"].contains(role) { continue }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        // An incomplete search cannot prove that a header or panel is unique.
        guard queue.count + children.count <= 5000 else { return nil }
        queue.append(contentsOf: children)
    }
    return queue
}

func panelIdentifier(in window: AXUIElement) -> String? {
    guard let nodes = descendants(window) else { return nil }
    let identifiers = nodes.compactMap { attribute($0, "AXDOMIdentifier") as? String }
        .filter { $0.hasSuffix("-chat-panel") }
    return identifiers.count == 1 ? identifiers[0] : nil
}

func menuItem(_ title: String, in window: AXUIElement) -> AXUIElement? {
    guard let nodes = descendants(window) else { return nil }
    let items = nodes.filter {
        attribute($0, kAXRoleAttribute) as? String == "AXMenuItem"
            && attribute($0, kAXTitleAttribute) as? String == title
    }
    return items.count == 1 ? items[0] : nil
}

func waitForMenuItem(_ title: String, in window: AXUIElement) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(1.2)
    repeat {
        if let item = menuItem(title, in: window) { return item }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return nil
}

func pseudonym(_ id: String) -> String {
    SHA256.hash(data: Data(("Hintlet Codex link probe v1:" + id.lowercased()).utf8))
        .prefix(16).map { String(format: "%02x", $0) }.joined()
}

func run() throws -> [String: Any] {
    guard CommandLine.arguments.contains("--copy-deeplink") else {
        return ["status": "explicit --copy-deeplink opt-in required; opens chat menus and temporarily uses clipboard"]
    }
    guard AXIsProcessTrusted() else { return ["status": "accessibility permission unavailable; no prompt requested"] }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
        return ["status": "Codex must be frontmost"]
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    guard let rawWindow = attribute(application, kAXFocusedWindowAttribute),
          CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return ["status": "no focused window"] }
    let window = rawWindow as! AXUIElement
    guard let originalNumber = windowNumber(window) else { return ["status": "native window identity unavailable"] }
    guard let panel = panelIdentifier(in: window), let nodes = descendants(window) else {
        return ["status": "requires one chat panel; no identity guessed"]
    }
    // These English control labels are deliberately version/locale specific in this research tool.
    let headers = nodes.filter {
        attribute($0, kAXRoleAttribute) as? String == "AXPopUpButton"
            && attribute($0, kAXTitleAttribute) as? String == "Chat actions"
    }
    guard headers.count == 1 else { return ["status": "requires one Chat actions control; no identity guessed"] }

    let pasteboard = NSPasteboard.general
    let originalCount = pasteboard.changeCount
    var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
    var bytes = 0
    for item in pasteboard.pasteboardItems ?? [] {
        var entries: [(NSPasteboard.PasteboardType, Data)] = []
        for type in item.types {
            // Never clear a clipboard whose advertised representations could not be preserved.
            guard let data = item.data(forType: type) else { return ["status": "clipboard cannot be preserved"] }
            bytes += data.count
            guard bytes <= 8 * 1024 * 1024 else { return ["status": "clipboard too large for this probe"] }
            entries.append((type, data))
        }
        saved.append(entries)
    }
    guard pasteboard.changeCount == originalCount else { return ["status": "clipboard changed during backup"] }
    var ownedClipboardCount: Int?
    var openedMenu = false
    defer {
        // Cancel a still-open menu directly; Escape could reach the chat and interrupt generation.
        if openedMenu, let remaining = descendants(window) {
            for menu in remaining where attribute(menu, kAXRoleAttribute) as? String == "AXMenu" {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
        }
        // A concurrent user copy wins. Restoring data cannot restore the original pasteboard owner.
        if let ownedClipboardCount, pasteboard.changeCount == ownedClipboardCount {
            pasteboard.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    let started = Date()
    guard AXUIElementPerformAction(headers[0], kAXPressAction as CFString) == .success else {
        return ["status": "cannot open chat menu"]
    }
    openedMenu = true
    guard let copy = waitForMenuItem("Copy", in: window),
          AXUIElementPerformAction(copy, kAXPressAction as CFString) == .success else {
        return ["status": "Copy submenu unavailable"]
    }
    guard let deeplink = waitForMenuItem("Copy deeplink", in: window),
          AXUIElementPerformAction(deeplink, kAXPressAction as CFString) == .success else {
        return ["status": "Copy deeplink item unavailable"]
    }
    let deadline = Date().addingTimeInterval(3)
    while pasteboard.changeCount == originalCount, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    let copiedCount = pasteboard.changeCount
    guard copiedCount != originalCount, let text = pasteboard.string(forType: .string),
          let url = URLComponents(string: text), url.scheme == "codex", url.host == "threads",
          url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else {
        return ["status": "no supported local thread link; clipboard NOT restored because writer is unknown"]
    }
    let parts = url.path.split(separator: "/")
    guard parts.count == 1, let uuid = UUID(uuidString: String(parts[0])) else {
        return ["status": "unsupported thread identifier; clipboard NOT restored because writer is unknown"]
    }
    ownedClipboardCount = copiedCount
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          let focused = attribute(application, kAXFocusedWindowAttribute), CFEqual(focused, window),
          CFGetTypeID(focused) == AXUIElementGetTypeID(), windowNumber(focused as! AXUIElement) == originalNumber,
          panelIdentifier(in: window) == panel else { return ["status": "window or panel changed; identity rejected"] }
    var result: [String: Any] = ["status": "identified", "threadPseudonym": pseudonym(uuid.uuidString),
                               "windowNumber": originalNumber,
                               "elapsedMilliseconds": Int(Date().timeIntervalSince(started) * 1000)]
    if let index = CommandLine.arguments.firstIndex(of: "--expect"), index + 1 < CommandLine.arguments.count {
        result["matchesExpected"] = UUID(uuidString: CommandLine.arguments[index + 1]) == uuid
    }
    return result
}

let wallStarted = Date()
var result = try run()
result["totalProbeMilliseconds"] = Int(Date().timeIntervalSince(wallStarted) * 1000)
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
FileHandle.standardOutput.write(Data("\n".utf8))
