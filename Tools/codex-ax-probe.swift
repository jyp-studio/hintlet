// Usage: swift Tools/codex-ax-probe.swift [--enable-accessibility] [--probe-routing-attributes]
// Records routing metadata only; never titles, text values, descriptions or messages.
import AppKit
import ApplicationServices
import CryptoKit

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission unavailable; no permission prompt requested.\n".utf8))
    exit(1)
}
guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
    FileHandle.standardError.write(Data("Codex is not running.\n".utf8))
    exit(2)
}
let application = AXUIElementCreateApplication(running.processIdentifier)
AXUIElementSetMessagingTimeout(application, 0.2)
// Enabling Electron's full tree costs resources, so require an explicit opt-in even in this probe.
if CommandLine.arguments.contains("--enable-accessibility") {
    AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 1.2)
}

let pattern = try NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
func redacted(_ original: String) -> String {
    var result = original
    for match in pattern.matches(in: original, range: NSRange(original.startIndex..., in: original)).reversed() {
        let value = String(original[Range(match.range, in: original)!])
        // UUIDs have sufficient entropy to use a deterministic digest without exposing their originals.
        // Stable pseudonyms let separately recorded snapshots reveal real switches and stale routes.
        let digest = SHA256.hash(data: Data(("Hintlet Codex AX fixture v1:" + value.lowercased()).utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [(0, 8), (8, 12), (12, 16), (16, 20), (20, 32)].map { start, end in
            String(hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
        }
        result.replaceSubrange(Range(match.range, in: result)!, with: parts.joined(separator: "-"))
    }
    return result
}

let focused = attribute(application, kAXFocusedWindowAttribute)
let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
var rows: [[String: Any]] = []
var truncated = false
for (windowIndex, window) in windows.enumerated() {
    var queue: [(element: AXUIElement, depth: Int, parent: Int)] = [(window, 0, -1)]
    var next = 0
    while next < queue.count, next < 5000 {
        let (element, depth, parent) = queue[next]
        let index = next
        next += 1
        AXUIElementSetMessagingTimeout(element, 0.2)
        var row: [String: Any] = ["window": windowIndex, "node": index, "parent": parent, "depth": depth]
        for key in ["AXRole", "AXSubrole", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXSelected", "AXFocused", "AXARIACurrent"] {
            guard let value = attribute(element, key) else { continue }
            if let strings = value as? [String] { row[key] = strings.map(redacted) }
            else if let string = value as? String { row[key] = redacted(string) }
            else if let number = value as? NSNumber { row[key] = number }
        }
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success {
            row["attributeNames"] = names as? [String] ?? []
        }
        var parameterizedNames: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameterizedNames) == .success {
            row["parameterizedAttributeNames"] = parameterizedNames as? [String] ?? []
        }
        // A document URL may carry a route in its query even when its full path isn't allowlisted.
        // Keep only structure and pseudonymized UUIDs, never arbitrary query values or local paths.
        if row["AXRole"] as? String == "AXWebArea", let value = attribute(element, kAXURLAttribute),
           let address = (value as? URL)?.absoluteString ?? (value as? String),
           let components = URLComponents(string: address), components.scheme == "app" {
            row["AXURLScheme"] = "app"
            row["AXURLQueryKeys"] = components.queryItems?.map(\.name) ?? []
            row["AXURLUUIDs"] = pattern.matches(in: address, range: NSRange(address.startIndex..., in: address)).map {
                redacted(String(address[Range($0.range, in: address)!]))
            }
        }
        if CommandLine.arguments.contains("--probe-routing-attributes"), row["AXARIACurrent"] as? String == "page" {
            var results: [String: Int32] = [:]
            for key in ["data-app-action-sidebar-thread-id", "AXDOMAttributes", "AXHTMLAttributes", "AXDataAttributes"] {
                var value: AnyObject?
                results[key] = AXUIElementCopyAttributeValue(element, key as CFString, &value).rawValue
            }
            row["customRoutingAttributeResults"] = results
        }
        if let value = attribute(element, kAXURLAttribute) {
            let address = (value as? URL)?.absoluteString ?? (value as? String)
            // Message links are not routing evidence and can contain private paths or credentials.
            if let address, var components = URLComponents(string: address),
               components.user == nil, components.password == nil, components.port == nil {
                let parts = components.path.split(separator: "/").map(String.init)
                let appDocument = components.scheme == "app" && components.host == "."
                    && ["/index.html", "/detached-window.html"].contains(components.path)
                let threadRoute = components.scheme == "codex" && components.host == "threads"
                    && parts.count == 1 && UUID(uuidString: parts[0]) != nil
                if appDocument || threadRoute {
                    components.query = nil
                    components.fragment = nil
                    row["AXURL"] = components.string.map(redacted)
                }
            }
        }
        rows.append(row)
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if depth < 70 {
            let remaining = max(0, 5000 - queue.count)
            if children.count > remaining { truncated = true }
            queue.append(contentsOf: children.prefix(remaining).map { ($0, depth + 1, index) })
        } else if !children.isEmpty { truncated = true }
    }
}
let focusedIndex = windows.firstIndex { window in focused.map { CFEqual($0, window) } ?? false }
let output: [String: Any] = [
    "version": running.bundleURL.flatMap { Bundle(url: $0) }?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
    "focusedWindow": focusedIndex.map { $0 as Any } ?? NSNull(),
    "truncated": truncated,
    "nodes": rows,
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
