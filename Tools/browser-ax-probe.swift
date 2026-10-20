// 探測工具（ticket 18）：唯讀地讀 Safari／Chrome 的輔助使用樹，看能不能拿到目前網頁的網址。
// 用法：swift Tools/browser-ax-probe.swift <safari|chrome> <command> [--raw]
//   snapshot        焦點視窗：屬性名稱、網頁區域（AXWebArea）的 AXURL、網址列的值、讀取耗時
//   watch <秒>      記錄 AXURL 變化與 AX 通知的時間點，量測切換分頁、同分頁換網址的延遲
// 只讀不寫：不設定 AXManualAccessibility／AXEnhancedUserInterface，不送 AppleScript。
// 預設把網址遮蔽成 scheme://<host-N>/<path-N>；--raw 保留原值，只在本機除錯用。
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
let raw = args.contains("--raw")
let bundleIDs = ["safari": "com.apple.Safari", "chrome": "com.google.Chrome"]
nonisolated(unsafe) var watchStart = Date()

guard args.count >= 2, let bundleID = bundleIDs[args[0]] else {
    print("用法：swift Tools/browser-ax-probe.swift <safari|chrome> <snapshot|watch 秒> [--raw]")
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("需要輔助使用權限\n".data(using: .utf8)!)
    exit(1)
}
guard let browser = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write("\(args[0]) 沒有在執行\n".data(using: .utf8)!)
    exit(1)
}
let appElement = AXUIElementCreateApplication(browser.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.5)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func names(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "?" }
func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

func url(_ element: AXUIElement) -> String? {
    if let u = attribute(element, "AXURL") as? URL { return u.absoluteString }
    return attribute(element, "AXURL") as? String
}

/// 焦點視窗；瀏覽器不在前景時退而用主視窗或第一個視窗。
func focusedWindow() -> AXUIElement? {
    for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let value = attribute(appElement, name), CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! AXUIElement) }
    }
    return (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
}

var hosts: [String: Int] = [:]
var paths: [String: Int] = [:]
func mask(_ address: String?) -> String {
    guard let address else { return "nil" }
    if raw { return address }
    guard let c = URLComponents(string: address) else { return "<unparsable>" }
    let host = c.host.map { h in "<host-\(hosts[h] ?? { hosts[h] = hosts.count + 1; return hosts.count }())>" } ?? ""
    let rest = c.path + (c.query.map { "?" + $0 } ?? "")
    let path = rest.isEmpty ? "" : "<path-\(paths[rest] ?? { paths[rest] = paths.count + 1; return paths.count }())>"
    return "\(c.scheme ?? "")://\(host)/\(path)\(c.fragment == nil ? "" : "#…")"
}

/// 寬度優先找網頁區域，不深入網頁區域內部；回傳找到的元素與走訪的節點數。
func webAreas(in root: AXUIElement, budget: Int = 4000) -> ([AXUIElement], Int) {
    var found: [AXUIElement] = []
    var queue = [root]
    var next = 0
    while next < queue.count, next < budget {
        let node = queue[next]
        next += 1
        if role(node) == "AXWebArea" { found.append(node); continue }
        queue.append(contentsOf: children(node))
    }
    return (found, next)
}

/// 網址列：工具列裡的文字欄位（Safari 的 AXTextField、Chrome 的 omnibox）。
func addressFields(in root: AXUIElement, budget: Int = 4000) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var queue = [root]
    var next = 0
    while next < queue.count, next < budget {
        let node = queue[next]
        next += 1
        let r = role(node)
        if r == "AXWebArea" { continue }
        if r == "AXTextField" || r == "AXComboBox" { found.append(node) }
        queue.append(contentsOf: children(node))
    }
    return found
}

func ms(_ start: Date) -> String { String(format: "%.2fms", Date().timeIntervalSince(start) * 1000) }

func snapshot() {
    guard let window = focusedWindow() else { print("沒有焦點視窗"); return }
    print("視窗屬性：\(names(window).joined(separator: ", "))")
    print("視窗 subrole=\(string(window, kAXSubroleAttribute) ?? "nil") identifier=\(string(window, kAXIdentifierAttribute) ?? "nil")")
    print("視窗標題長度：\(string(window, kAXTitleAttribute)?.count ?? -1)　AXDocument=\(mask(string(window, kAXDocumentAttribute)))")
    var start = Date()
    let (areas, visited) = webAreas(in: window)
    print("找網頁區域：\(areas.count) 個，走訪 \(visited) 個節點，\(ms(start))")
    for (i, area) in areas.enumerated() {
        start = Date()
        let address = url(area)
        let readCost = ms(start)
        print("  [\(i)] AXURL=\(mask(address))（讀一次 \(readCost)）標題長度=\(string(area, kAXTitleAttribute)?.count ?? -1) 子元素=\(children(area).count)")
        print("      屬性：\(names(area).joined(separator: ", "))")
    }
    start = Date()
    let fields = addressFields(in: window)
    print("文字欄位：\(fields.count) 個，\(ms(start))")
    for field in fields {
        let value = string(field, kAXValueAttribute)
        print("  \(role(field)) desc=\(string(field, kAXDescriptionAttribute) ?? "nil") id=\(string(field, kAXIdentifierAttribute) ?? "nil") value=\(mask(value))")
    }
    for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        print("App \(name)=\(attribute(appElement, name).map { "\($0)" } ?? "nil")")
    }
}

func log(_ message: String) { print(String(format: "%8.3fs ", Date().timeIntervalSince(watchStart)) + message) }

func watch(seconds: Double) {
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, _ in
        log("通知 \(notification as String) 元素=\(role(element))")
    }
    guard AXObserverCreate(browser.processIdentifier, callback, &observer) == .success, let observer else { return }
    for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification,
                 kAXValueChangedNotification, "AXLoadComplete", "AXLayoutComplete"] {
        AXObserverAddNotification(observer, appElement, name as CFString, nil)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    var last: String?? = .none
    var cached: (window: AXUIElement, area: AXUIElement)?
    watchStart = Date()
    let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
        guard let window = focusedWindow() else { return }
        if cached == nil || !CFEqual(cached!.window, window) || role(cached!.area) != "AXWebArea" {
            cached = webAreas(in: window).0.first.map { (window, $0) }
        }
        let current = cached.flatMap { url($0.area) }
        if last == nil || last! != current {
            log("AXURL → \(mask(current))")
            last = .some(current)
        }
    }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

switch args[1] {
case "snapshot": snapshot()
case "watch": watch(seconds: Double(args.dropFirst(2).first ?? "") ?? 20)
default: print("未知指令 \(args[1])")
}
