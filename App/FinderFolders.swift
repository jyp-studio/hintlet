import AppKit
import StickyContextCore

/// Which folder a Finder window shows. Finder doesn't tell Accessibility, only Apple Events (the first ask
/// shows the system's "Hintlet wants to control Finder" prompt). Answers are remembered per window and title,
/// and checked again whenever the user comes back to the window, since two folders can share a name.
@MainActor
final class FinderFolders {
    nonisolated static let bundleID = "com.apple.finder"
    /// A busy Finder mustn't hold notes up for long.
    nonisolated private static let timeout: TimeInterval = 0.25
    /// After an answer about another window (say a Get Info window was in front), wait before asking again.
    private static let retryDelay: TimeInterval = 1
    /// Apple Events wait for Finder, and the very first one for the user to answer the permission prompt.
    private static let queue = DispatchQueue(label: "StickyContext.FinderFolders", qos: .userInitiated)

    private struct Key: Hashable {
        let window: WindowID
        let title: String
    }

    /// nil once looked up and not found (no permission, not a folder window): don't keep asking.
    private var known: [Key: String?] = [:]
    private var asking: Set<Key> = []
    private var lastAskedAgain: [Key: Date] = [:]

    /// The folder as last known (nil until Finder has answered). `checkAgain` asks Finder anyway, and
    /// `onChange` runs if the answer turns out different.
    func folder(of window: WindowID, titled title: String, checkAgain: Bool,
                onChange: @escaping @MainActor () -> Void) -> String? {
        let key = Key(window: window, title: title)
        let cached = known[key] ?? nil
        guard known[key] == nil || checkAgain, !asking.contains(key) else { return cached }
        if let last = lastAskedAgain[key], Date().timeIntervalSince(last) < Self.retryDelay { return cached }
        asking.insert(key)
        Self.queue.async {
            // The first time, this waits for the user to answer the system's prompt.
            let answer = Self.frontWindowFolder(titled: title, askingPermission: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.asking.remove(key)
                    let before = self.known[key] ?? nil
                    if self.remember(answer, for: key) != before { onChange() }
                }
            }
        }
        return cached
    }

    /// Asks right away, for the moment a note is created and its place must be known.
    func folderNow(of window: WindowID, titled title: String) -> String? {
        // Never shows the permission prompt here: that would freeze the app until it is answered.
        remember(Self.frontWindowFolder(titled: title, askingPermission: false), for: Key(window: window, title: title))
    }

    func forget(_ windows: [WindowID]) {
        let gone = Set(windows)
        known = known.filter { !gone.contains($0.key.window) }
        lastAskedAgain = lastAskedAgain.filter { !gone.contains($0.key.window) }
    }

    private enum Answer: Sendable {
        case folder(String)
        /// No permission, or the window shows no folder (e.g. Recents): asking again won't help.
        case noFolder
        /// Finder's front window was another one by the time it answered, or the user hasn't answered the
        /// permission prompt yet: ask again later.
        case askAgain
    }

    /// Records the answer and returns the folder now known for `key`.
    private func remember(_ answer: Answer, for key: Key) -> String? {
        switch answer {
        case .folder(let path):
            known[key] = .some(path)
            lastAskedAgain[key] = nil
        case .noFolder:
            known[key] = .some(nil)
        case .askAgain:
            lastAskedAgain[key] = Date()
        }
        return known[key] ?? nil
    }

    // MARK: Apple Events

    // Four-character codes from Finder's scripting dictionary.
    nonisolated private static let finderWindowClass = "brow"
    nonisolated private static let nameProperty = "pnam"
    nonisolated private static let targetProperty = "fvtg"
    nonisolated private static let urlProperty = "pURL"

    /// The folder of Finder's front window, if that window is the one titled `title`.
    /// Equivalent to `tell application "Finder" to get URL of target of Finder window 1`.
    nonisolated private static func frontWindowFolder(titled title: String, askingPermission: Bool) -> Answer {
        let finder = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = finder.aeDesc else { return .noFolder }
        switch AEDeterminePermissionToAutomateTarget(target, AEEventClass(kAECoreSuite), AEEventID(kAEGetData),
                                                     askingPermission) {
        case noErr: break
        case OSStatus(errAEEventWouldRequireUserConsent): return .askAgain
        default: return .noFolder
        }
        let frontWindow = specifier(class: finderWindowClass, form: "indx", data: NSAppleEventDescriptor(int32: 1),
                                    in: .null())
        guard get(property(nameProperty, of: frontWindow))?.stringValue == title else { return .askAgain }
        guard let urlString = get(property(urlProperty, of: property(targetProperty, of: frontWindow)))?.stringValue,
              let url = URL(string: urlString), let path = DocumentPaths.path(of: url) else { return .noFolder }
        return .folder(path)
    }

    nonisolated private static func get(_ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
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

    /// An object specifier: the `wanted` thing picked by `form` and `data` inside `container`.
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

/// Turns a file URL into the path notes are bound by, so the same place always gives the same string:
/// symlinks resolved, Unicode in one form, and a trailing "/" for folders (not for packages like .pages).
enum DocumentPaths {
    nonisolated static func path(of url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return url.hasDirectoryPath ? path + "/" : path
        }
        let isFolder = isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)
        return isFolder && !path.hasSuffix("/") ? path + "/" : path
    }
}
