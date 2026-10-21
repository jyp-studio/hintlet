import AppKit
import Carbon.HIToolbox
import HintletCore

/// A system-wide hot key registered through Carbon, which needs no Input Monitoring permission.
@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// Returns nil when the system refuses the registration (for example, another app already owns the combination).
    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4358), id: id) // "STCX"
        let status = RegisterEventHotKey(keyCode, Self.carbonModifiers(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { return nil }
        Self.handlers[id] = action
    }

    convenience init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        self.init(keyCode: shortcut.keyCode, modifiers: Self.flags(shortcut.modifiers), action: action)
    }

    static func flags(_ modifiers: Shortcut.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// The shortcuts turned on in System Settings › Keyboard › Keyboard Shortcuts (Spotlight, screenshots,
    /// Mission Control…). Reading them needs no permission.
    static func systemShortcuts() -> [Shortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) ?? false,
                  let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value,
                  let carbon = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value else { return nil }
            var modifiers: Shortcut.Modifiers = []
            if carbon & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
            if carbon & UInt32(optionKey) != 0 { modifiers.insert(.option) }
            if carbon & UInt32(controlKey) != 0 { modifiers.insert(.control) }
            if carbon & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
            return Shortcut(keyCode: code, modifiers: modifiers, key: "")
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
