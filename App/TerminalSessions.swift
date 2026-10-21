import AppKit
import Darwin
import HintletCore

/// Which Claude Code conversation the front tab of Terminal or iTerm shows (spike 06): the tab's tty from
/// Apple Events, the process in front on that tty, and the session file Claude Code keeps for it.
/// Terminal and iTerm don't tell Accessibility the tty, so the first ask shows the system's "Hintlet wants
/// to control Terminal" prompt. That only happens once Claude Code is actually running in a terminal.
@MainActor
final class TerminalSessions {
    nonisolated static let terminalBundleID = "com.apple.Terminal"
    nonisolated static let iTermBundleID = "com.googlecode.iterm2"
    static let bundleIDs: Set<String> = [terminalBundleID, iTermBundleID]
    /// A busy terminal mustn't hold notes up for long.
    nonisolated private static let timeout: TimeInterval = 0.25
    /// Apple Events wait for the terminal, and the very first one for the user to answer the prompt.
    private static let queue = DispatchQueue(label: "Hintlet.TerminalSessions", qos: .userInitiated)
    nonisolated private static var sessionsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    private struct Key: Hashable {
        let window: WindowID
        let title: String
    }

    /// The front tab's tty as last told, per window and title; nil once asked and not told (no permission).
    private var ttys: [Key: String?] = [:]
    private var asking: Set<Key> = []
    private var lastAsked: [Key: Date] = [:]
    /// Windows are read many times a second while they move; the tab can't change that fast.
    private static let askInterval: TimeInterval = 0.5

    /// The conversation the window's front tab shows, from the tty as last known. Asks the terminal again
    /// in the background (the user may have switched tabs), and `onChange` runs if its answer differs.
    func page(of app: NSRunningApplication, window: WindowID, titled title: String, number: UInt32?,
              onChange: @escaping @MainActor () -> Void) -> ClaudePage? {
        // Nothing to find (and no reason to ask for permission) without Claude Code running somewhere.
        let records = Self.runningRecords()
        guard !records.isEmpty, let bundleID = app.bundleIdentifier else { return nil }
        let key = Key(window: window, title: title)
        let known = ttys[key] ?? nil
        let recently = lastAsked[key].map { Date().timeIntervalSince($0) < Self.askInterval } ?? false
        if !asking.contains(key), !recently {
            asking.insert(key)
            lastAsked[key] = Date()
            Self.queue.async {
                // The first time, this waits for the user to answer the system's prompt.
                let answer = Self.frontTabTTY(of: bundleID, windowTitled: title, number: number, askingPermission: true)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.asking.remove(key)
                        if self.remember(answer, for: key) != known { onChange() }
                    }
                }
            }
        }
        return known.flatMap { Self.page(onTTY: $0, records: records) }
    }

    /// Asks right away, for the moment a note is created and its place must be known.
    func pageNow(of app: NSRunningApplication, window: WindowID, titled title: String, number: UInt32?) -> ClaudePage? {
        let records = Self.runningRecords()
        guard !records.isEmpty, let bundleID = app.bundleIdentifier else { return nil }
        // Never shows the permission prompt here: that would freeze the app until it is answered.
        let answer = Self.frontTabTTY(of: bundleID, windowTitled: title, number: number, askingPermission: false)
        return remember(answer, for: Key(window: window, title: title)).flatMap { Self.page(onTTY: $0, records: records) }
    }

    func forget(_ windows: [WindowID]) {
        let gone = Set(windows)
        ttys = ttys.filter { !gone.contains($0.key.window) }
        lastAsked = lastAsked.filter { !gone.contains($0.key.window) }
    }

    private enum Answer: Sendable {
        case tty(String)
        /// No permission, or the terminal has no such tab: asking again won't help.
        case noTTY
        /// The terminal's front window was another one, or the prompt isn't answered yet: ask again later.
        case askAgain
    }

    private func remember(_ answer: Answer, for key: Key) -> String? {
        switch answer {
        case .tty(let tty): ttys[key] = .some(tty)
        case .noTTY: ttys[key] = .some(nil)
        case .askAgain: break
        }
        return ttys[key] ?? nil
    }

    // MARK: Processes and session files

    private static func page(onTTY tty: String, records: [ClaudeCodeSessionRecord]) -> ClaudePage? {
        guard let (foreground, processes) = processes(onTTY: tty) else { return nil }
        return ClaudeCodeTerminal.page(foregroundGroup: foreground, processes: processes, records: records)
    }

    /// Claude Code's session files for processes still running, as written from a terminal.
    nonisolated private static func runningRecords() -> [ClaudeCodeSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let record = try? ClaudeCodeSessionRecord(json: data),
                  record.entrypoint == "cli", kill(record.pid, 0) == 0 || errno == EPERM else { return nil }
            return record
        }
    }

    /// The processes on `tty` (e.g. "/dev/ttys005") and the process group in front there.
    nonisolated private static func processes(onTTY tty: String) -> (Int32, [TTYProcess])? {
        var info = stat()
        guard stat(tty, &info) == 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(info.st_rdev))]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Room for processes started in between.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 8
        var list = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &list, &size, nil, 0) == 0 else { return nil }
        let found = list.prefix(size / MemoryLayout<kinfo_proc>.stride)
        guard let foreground = found.first?.kp_eproc.e_tpgid else { return nil }
        let processes = found.map { entry -> TTYProcess in
            var command = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let start = entry.kp_proc.p_starttime
            return TTYProcess(pid: entry.kp_proc.p_pid, processGroup: entry.kp_eproc.e_pgid,
                              startedAt: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6),
                              name: name)
        }
        return (foreground, processes)
    }

    // MARK: Apple Events

    /// The tty of the front tab, if the terminal's front window is the one titled `title` (or, in Terminal,
    /// numbered `number`: Claude Code keeps changing the title's first character while it works, so the
    /// title alone may not match). Equivalent to `tty of selected tab of window 1` (Terminal) or
    /// `tty of current session of current window` (iTerm).
    nonisolated private static func frontTabTTY(of bundleID: String, windowTitled title: String, number: UInt32?,
                                                askingPermission: Bool) -> Answer {
        let app = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = app.aeDesc else { return .noTTY }
        switch AEDeterminePermissionToAutomateTarget(target, AEEventClass(kAECoreSuite), AEEventID(kAEGetData),
                                                     askingPermission) {
        case noErr: break
        case OSStatus(errAEEventWouldRequireUserConsent): return .askAgain
        default: return .noTTY
        }
        // Four-character codes from each app's scripting dictionary.
        let window: NSAppleEventDescriptor
        let session: NSAppleEventDescriptor
        let ttyProperty: String
        switch bundleID {
        case terminalBundleID:
            window = specifier(class: "cwin", form: "indx", data: NSAppleEventDescriptor(int32: 1), in: .null())
            session = property("tcnt", of: window)
            ttyProperty = "ttty"
        case iTermBundleID:
            window = property("Crwn", of: .null())
            session = property("Wcsn", of: window)
            ttyProperty = "Stty"
        default:
            return .noTTY
        }
        let isThatWindow = get(property("pnam", of: window), from: bundleID)?.stringValue == title
            || (bundleID == terminalBundleID && number != nil
                && get(property("ID  ", of: window), from: bundleID)?.int32Value == number.map { Int32(bitPattern: $0) })
        guard isThatWindow else { return .askAgain }
        guard let tty = get(property(ttyProperty, of: session), from: bundleID)?.stringValue,
              tty.hasPrefix("/dev/") else { return .noTTY }
        return .tty(tty)
    }

    nonisolated private static func get(_ object: NSAppleEventDescriptor, from bundleID: String) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: keyDirectObject)
        let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        return reply?.paramDescriptor(forKeyword: keyDirectObject)
    }

    nonisolated private static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(class: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)), in: container)
    }

    nonisolated private static func specifier(class wanted: String, form: String, data: NSAppleEventDescriptor,
                                              in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(wanted)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }

    nonisolated private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
