import AppKit
import ApplicationServices
import HintletCore

/// Reports where the text caret is in the app in front, so notes can give way while the user types under them.
///
/// Event-driven: it listens for the app's text and focus changes through Accessibility and reads the caret's
/// bounds only then, at most once per run-loop turn. Apps that don't report a caret (or Hintlet itself, being
/// typed in) report nil, and notes stay where they are.
@MainActor
final class CaretWatcher {
    /// The caret's rect in AppKit coordinates, or nil when there is none to keep clear.
    /// Also whether the text was just typed in: the same field as last time, with a different length. Focus
    /// landing in a field (switching apps, threads or desktops) puts a caret there without anyone typing.
    var onCaret: ((CGRect?, _ typed: Bool) -> Void)?

    /// Electron apps show their text to Accessibility only once asked to. Only apps named here are asked: some
    /// (VS Code among them) take it as a screen reader starting up and change how they behave. Claude is asked by
    /// `ClaudePages`, once the user agrees.
    private static let electronChatApps: Set<String> = ["com.openai.codex"]
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    private static let notifications = [
        kAXSelectedTextChangedNotification, kAXValueChangedNotification, kAXFocusedUIElementChangedNotification,
    ]
    private var observer: AXObserver?
    private var app: NSRunningApplication?
    private var isReadPending = false
    /// The field last read and how long its text was.
    private var lastField: (element: AXUIElement, length: Int?)?
    private var workspaceToken: NSObjectProtocol?

    func start() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.watch(app) }
        }
        watch(NSWorkspace.shared.frontmostApplication)
    }

    private func watch(_ app: NSRunningApplication?) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observer = nil
        }
        self.app = app
        lastField = nil
        onCaret?(nil, false)
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<CaretWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.caretMayHaveMoved() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let id = app.bundleIdentifier, Self.electronChatApps.contains(id) {
            AXUIElementSetAttributeValue(element, Self.manualAccessibilityAttribute as CFString, kCFBooleanTrue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    /// Typing posts several notifications per keystroke; one read is enough.
    private func caretMayHaveMoved() {
        guard !isReadPending else { return }
        isReadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isReadPending = false
            let (caret, typed) = readCaret()
            onCaret?(caret, typed)
        }
    }

    private func readCaret() -> (CGRect?, Bool) {
        guard let app, let primary = NSScreen.screens.first else { return (nil, false) }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = element.elementAttribute(kAXFocusedUIElementAttribute) else {
            lastField = nil
            return (nil, false)
        }
        let length: Int? = focused.attribute(kAXNumberOfCharactersAttribute)
        let typed = lastField.map { CFEqual($0.element, focused) && $0.length != length } ?? false
        lastField = (focused, length)
        guard let range: AnyObject = focused.attribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(range) == AXValueGetTypeID(),
              var rect = Self.caretBounds(in: focused, range: range as! AXValue) else { return (nil, false) }
        // An empty selection often comes back with no width.
        rect.size.width = max(rect.width, 2)
        return (ScreenCoordinates.appKitRect(fromTopLeft: rect, primaryScreenHeight: primary.frame.height), typed)
    }

    /// Apps answer differently. AppKit text gives the caret for the empty selection. Chromium (Claude, browsers)
    /// gives an empty rect at the screen's edge for it, so the character beside the caret is asked for instead,
    /// then the line it is on.
    private static func caretBounds(in element: AXUIElement, range: AXValue) -> CGRect? {
        if let rect = bounds(element, kAXBoundsForRangeParameterizedAttribute, range) { return rect }
        var selection = CFRange()
        if AXValueGetValue(range, .cfRange, &selection), selection.length == 0 {
            let before = selection.location > 0
            var character = CFRange(location: before ? selection.location - 1 : 0, length: 1)
            if let value = AXValueCreate(.cfRange, &character),
               let rect = bounds(element, kAXBoundsForRangeParameterizedAttribute, value) {
                return CGRect(x: before ? rect.maxX : rect.minX, y: rect.minY, width: 2, height: rect.height)
            }
        }
        // An empty field has no character to ask about: its whole line is kept clear.
        if let markers: AnyObject = element.attribute("AXSelectedTextMarkerRange"),
           let line = bounds(element, "AXBoundsForTextMarkerRange", markers), line.height < 120 {
            return line
        }
        return nil
    }

    /// Only a rect with some height counts: an unknown position comes back as an empty one.
    private static func bounds(_ element: AXUIElement, _ attribute: String, _ parameter: AnyObject) -> CGRect? {
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height >= 1 else { return nil }
        return rect
    }
}

/// Holding ⌥ on its own for a moment makes every note see-through and lets clicks go to what is under them.
///
/// Only the modifier keys are watched (no keystrokes), which needs the Accessibility access Hintlet already has.
@MainActor
final class OptionPeek {
    var onPeek: ((Bool) -> Void)?

    /// Long enough that ⌥ pressed as part of a shortcut or a typed character doesn't flash the notes.
    private static let holdDelay: TimeInterval = 0.25
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private(set) var isPeeking = false

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Something was typed while ⌥ was down: it was for a character, not for peeking.
    func interrupt() {
        pending?.cancel()
        pending = nil
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection([.command, .option, .control, .shift, .function])
        interrupt()
        guard held == .option else {
            set(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.set(true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    private func set(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        onPeek?(peeking)
    }
}
