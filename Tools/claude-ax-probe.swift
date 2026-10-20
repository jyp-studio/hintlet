// 探測工具（ticket 02 / 04）：讀 Claude 桌面 App 的輔助使用樹。
// 用法：swift Tools/claude-ax-probe.swift <command> [--raw]
//   snapshot        印出各視窗與網頁區域的 JSON 快照（切面 B 素材）
//   links           列出網頁區域中指向對話的連結（只印路徑種類與數量）
//   watch <秒>      記錄 AXURL 變化與 AX 通知的時間點，量測切換延遲
//   messages        計數目前 Chat 對話中可讀到的訊息（不輸出內容）
// 預設把對話 ID 遮蔽成 <id-N>；--raw 保留原值，只在本機除錯用。
import AppKit
import ApplicationServices

let bundleID = "com.anthropic.claudefordesktop"
nonisolated(unsafe) var watchStart = Date()
let args = Array(CommandLine.arguments.dropFirst())
let raw = args.contains("--raw")

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("需要輔助使用權限\n".data(using: .utf8)!)
    exit(1)
}
guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write("Claude 沒有在執行\n".data(using: .utf8)!)
    exit(1)
}
let appElement = AXUIElementCreateApplication(claude.processIdentifier)

// MARK: - AX helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "?" }

func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    return (value as! AXValue)
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    var p = CGPoint.zero
    guard let value = axValue(element, name), AXValueGetValue(value, .cgPoint, &p) else { return nil }
    return p
}

func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    var s = CGSize.zero
    guard let value = axValue(element, name), AXValueGetValue(value, .cgSize, &s) else { return nil }
    return s
}

func focusedWindow() -> AXUIElement? {
    guard let value = attribute(appElement, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frame(_ element: AXUIElement) -> [String: Double]? {
    guard let p = point(element, kAXPositionAttribute), let s = size(element, kAXSizeAttribute) else { return nil }
    return ["x": p.x, "y": p.y, "width": s.width, "height": s.height]
}

func url(_ element: AXUIElement) -> String? {
    if let u = attribute(element, "AXURL") as? URL { return u.absoluteString }
    return attribute(element, "AXURL") as? String
}

/// 開啟 Electron 的完整輔助使用樹；剛開啟時樹可能還是空的，稍等一下再讀。
func enableManualAccessibility() {
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// 找出所有網頁區域，不深入網頁區域內部。
func webAreas(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    if role(element) == "AXWebArea" { return [element] }
    if depth > 30 { return [] }
    return children(element).flatMap { webAreas(in: $0, depth: depth + 1) }
}

func windows() -> [AXUIElement] { attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

// MARK: - Redaction

var redactions: [String: String] = [:]
let idPattern = try! NSRegularExpression(pattern: "(local_|draft_)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

/// 把 UUID 換成穩定的假 UUID，維持路徑格式，讓快照仍可當測試素材。
func redact(_ text: String) -> String {
    if raw { return text }
    var result = text
    for match in idPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        let range = Range(match.range, in: text)!
        let original = String(text[range])
        let prefix = original.hasPrefix("local_") ? "local_" : original.hasPrefix("draft_") ? "draft_" : ""
        let fake = redactions[original] ?? {
            let n = redactions.count + 1
            let made = prefix + String(format: "00000000-0000-4000-8000-%012d", n)
            redactions[original] = made
            return made
        }()
        result.replaceSubrange(Range(match.range, in: result)!, with: fake)
    }
    return result
}

/// 對話名稱是使用者內容：保留 Claude 加上的固定後綴與固定頁名，其餘換成「範例對話」。
func redactTitle(_ title: String) -> String {
    if raw { return title }
    let fixed = ["Claude", "New session - Claude", "New task - Claude", "Projects - Claude"]
    if fixed.contains(title) { return title }
    for suffix in [" - Claude Code", " - Claude"] where title.hasSuffix(suffix) { return "範例對話" + suffix }
    return "範例對話"
}

// MARK: - Commands

func snapshot() -> [String: Any] {
    let focused = focusedWindow()
    let windowList: [[String: Any]] = windows().map { window in
        let areas: [[String: Any]] = webAreas(in: window).map { area in
            var entry: [String: Any] = [
                "url": url(area).map(redact) ?? NSNull(),
                "title": (attribute(area, kAXTitleAttribute) as? String).map(redactTitle) ?? NSNull(),
                "focused": attribute(area, kAXFocusedAttribute) as? Bool ?? false,
            ]
            entry["frame"] = frame(area) ?? NSNull()
            return entry
        }
        return [
            "title": attribute(window, kAXTitleAttribute) as? String ?? NSNull(),
            "main": attribute(window, kAXMainAttribute) as? Bool ?? false,
            "focused": focused.map { CFEqual($0, window) } ?? false,
            "minimized": attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
            "frame": frame(window) ?? NSNull(),
            "webAreas": areas,
        ]
    }
    return [
        "focusedElement": focusedElementInfo() ?? NSNull(),
        "claudeVersion": claude.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] } ?? NSNull(),
        "frontmost": claude.isActive,
        "windows": windowList,
    ]
}

/// 焦點元素的角色，以及往上找到的最近網頁區域的網址（spec 的判斷規則以此為準）。
func focusedElementInfo() -> [String: Any]? {
    guard let value = attribute(appElement, kAXFocusedUIElementAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = value as! AXUIElement
    var ancestor: AXUIElement? = element
    var depth = 0
    while let current = ancestor, role(current) != "AXWebArea", depth < 200 {
        ancestor = attribute(current, kAXParentAttribute).flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        depth += 1
    }
    return [
        "role": role(element),
        "nearestWebAreaURL": ancestor.flatMap(url).map(redact) ?? NSNull(),
    ]
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}

/// 網頁區域內所有帶 AXURL 的連結，依路徑種類計數。
func links() {
    var kinds: [String: Int] = [:]
    var samples: [String: String] = [:]
    func visit(_ element: AXUIElement, depth: Int) {
        if depth > 60 { return }
        if role(element) == "AXLink", let u = url(element), let path = URL(string: u)?.path {
            let kind = path.split(separator: "/").first.map(String.init) ?? "/"
            kinds[kind, default: 0] += 1
            samples[kind] = samples[kind] ?? redact(path)
        }
        children(element).forEach { visit($0, depth: depth + 1) }
    }
    windows().flatMap { webAreas(in: $0) }.forEach { visit($0, depth: 0) }
    printJSON(["counts": kinds, "samples": samples])
}

/// 目前顯示的網頁區域：焦點視窗中尺寸非零的那一個（只有一個時直接用）。
func visibleWebArea() -> AXUIElement? {
    let window = focusedWindow() ?? windows().first
    guard let window else { return nil }
    let areas = webAreas(in: window).filter { (size($0, kAXSizeAttribute)?.width ?? 0) > 0 }
    return areas.count == 1 ? areas[0] : nil
}

/// 目前焦點視窗中所有網頁區域的網址；watch 用它偵測切換。
func currentURLs() -> String {
    guard let window = focusedWindow() else { return "-" }
    return webAreas(in: window).compactMap(url).joined(separator: " | ")
}

func watch(seconds: Double) {
    watchStart = Date()
    func stamp(_ message: String) {
        print(String(format: "%8.3f  ", Date().timeIntervalSince(watchStart)) + message)
        fflush(stdout)
    }
    var observer: AXObserver?
    let created = AXObserverCreate(claude.processIdentifier, { _, element, notification, _ in
        let r = attribute(element, kAXRoleAttribute) as? String ?? "?"
        print(String(format: "%8.3f  ", Date().timeIntervalSince(watchStart)) + "notify \(notification) on \(r)")
        fflush(stdout)
    }, &observer)
    if created == .success, let observer {
        let notifications = [
            kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXTitleChangedNotification,
            kAXLayoutChangedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification,
            "AXLoadComplete", kAXValueChangedNotification, kAXApplicationActivatedNotification,
        ]
        for name in notifications { AXObserverAddNotification(observer, appElement, name as CFString, nil) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    } else {
        stamp("無法建立 AX observer（\(created.rawValue)），只輪詢網址")
    }

    var lastURL = currentURLs()
    stamp("start url \(redact(lastURL))")
    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
        let now = currentURLs()
        if now != lastURL { stamp("url \(redact(now))"); lastURL = now }
    }
    // session 檔要讀整個資料夾，放慢到每秒一次，免得干擾網址的量測。
    var lastFocus = latestCodeFocus()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        let focus = latestCodeFocus()
        if focus != lastFocus { stamp("lastFocusedAt \(redact(focus))"); lastFocus = focus }
    }
    RunLoop.current.run(until: watchStart.addingTimeInterval(seconds))
}

/// Code session 檔中最新的 lastFocusedAt（session ID 與時間）。
func latestCodeFocus() -> String {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return "-" }
    var best: (Double, String) = (0, "-")
    for case let file as URL in enumerator where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let focused = json["lastFocusedAt"] as? Double else { continue }
        if focused > best.0 { best = (focused, (json["sessionId"] as? String) ?? file.lastPathComponent) }
    }
    return "\(best.1) @ \(Int(best.0))"
}

/// 計數 Chat 對話中讀得到的訊息，不輸出內容。
/// 使用者訊息是 class 含 `bg-user-message` 的泡泡；Claude 回覆是 class 含 `group/message-row` 的群組
/// （Tailwind class，隨 claude.ai 改版可能失效）。sequence 附上每則的 y／高度：可視範圍外的訊息仍在樹裡，但高度回報為 1。
func messages() {
    guard let area = visibleWebArea() else { print("找不到唯一的網頁區域"); return }
    var counts = ["user": 0, "assistant": 0]
    var sequence = ""
    var characters = ["user": 0, "assistant": 0]
    func textLength(_ element: AXUIElement, depth: Int = 0) -> Int {
        if depth > 60 { return 0 }
        let own = role(element) == "AXStaticText" ? (attribute(element, kAXValueAttribute) as? String)?.count ?? 0 : 0
        return own + children(element).reduce(0) { $0 + textLength($1, depth: depth + 1) }
    }
    var headings = ["You said": 0, "Claude responded": 0]
    func countHeadings(_ element: AXUIElement, depth: Int) {
        if depth > 90 { return }
        if role(element) == "AXHeading" {
            let label = children(element).compactMap { attribute($0, kAXValueAttribute) as? String }.joined()
            for prefix in headings.keys where label.hasPrefix(prefix) { headings[prefix]! += 1 }
        }
        children(element).forEach { countHeadings($0, depth: depth + 1) }
    }
    func visit(_ element: AXUIElement, depth: Int) {
        if depth > 90 { return }
        let classes = attribute(element, "AXDOMClassList") as? [String] ?? []
        let kind: String? = classes.contains { $0.contains("bg-user-message") } ? "user"
            : classes.contains("group/message-row") ? "assistant" : nil
        if let kind {
            sequence.append((kind == "user" ? "U" : "A") + "@\(Int(frame(element)?["y"] ?? -1))/\(Int(frame(element)?["height"] ?? -1)) ")
            counts[kind]! += 1
            characters[kind]! += textLength(element)
            return
        }
        children(element).forEach { visit($0, depth: depth + 1) }
    }
    visit(area, depth: 0)
    countHeadings(area, depth: 0)
    printJSON([
        "url": redact(url(area) ?? "-"),
        "messages": counts,
        "characters": characters,
        "sequence": sequence,
        "headings": headings,
    ])
}

enableManualAccessibility()
Thread.sleep(forTimeInterval: 0.5)

switch args.first {
case "snapshot": printJSON(snapshot())
case "links": links()
case "watch": watch(seconds: Double(args.dropFirst().first ?? "20") ?? 20)
case "messages": messages()
default: print("用法：swift Tools/claude-ax-probe.swift snapshot|links|watch <秒>|messages [--raw]")
}
