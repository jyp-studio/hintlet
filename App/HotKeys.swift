import AppKit
import Carbon.HIToolbox
import HintletCore

/// The global shortcuts the user chose (kept in UserDefaults), registered for whichever actions the app
/// has handlers for.
@MainActor
final class HotKeys {
    private static let defaultsKey = "globalShortcuts"

    private(set) var settings = ShortcutSettings(data: UserDefaults.standard.data(forKey: HotKeys.defaultsKey))
    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var registered: [ShortcutAction: GlobalHotKey] = [:]
    /// Actions whose shortcut the system wouldn't register, usually because another app holds it.
    private(set) var unavailable: Set<ShortcutAction> = []
    private var isSuspended = false
    /// After any change, e.g. to update the menu's key equivalents.
    var onChange: (() -> Void)?

    enum ChangeError: Error, Equatable {
        case problem(ShortcutProblem)
        /// Refused by the system; the previous shortcut stays.
        case unavailable
    }

    /// Registers the action's shortcut to run `handler`.
    func setHandler(for action: ShortcutAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
        register(action)
    }

    func change(_ action: ShortcutAction, to shortcut: Shortcut) -> Result<Void, ChangeError> {
        if let problem = settings.problem(setting: shortcut, for: action, systemShortcuts: GlobalHotKey.systemShortcuts()) {
            return .failure(.problem(problem))
        }
        let previous = settings[action]
        settings[action] = shortcut
        register(action)
        if handlers[action] != nil, registered[action] == nil, !isSuspended {
            settings[action] = previous
            register(action)
            onChange?()
            return .failure(.unavailable)
        }
        save()
        onChange?()
        return .success(())
    }

    func resetToDefaults() {
        settings = .defaults
        save()
        for action in ShortcutAction.allCases { register(action) }
        onChange?()
    }

    /// While a new shortcut is being recorded, pressing the current one mustn't run it.
    func suspend(_ suspended: Bool) {
        isSuspended = suspended
        for action in ShortcutAction.allCases { register(action) }
    }

    private func register(_ action: ShortcutAction) {
        registered[action] = nil
        guard !isSuspended, let handler = handlers[action] else { return }
        registered[action] = GlobalHotKey(settings[action], action: handler)
        if registered[action] == nil {
            unavailable.insert(action)
            NSLog("Hintlet：無法註冊 \(settings[action].displayString)，可能已被其他 App 使用")
        } else {
            unavailable.remove(action)
        }
    }

    private func save() {
        if let data = try? settings.data() { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    /// Sets a menu item's key equivalent to show the action's shortcut.
    func showShortcut(of action: ShortcutAction, in item: NSMenuItem) {
        let shortcut = settings[action]
        guard let equivalent = Self.keyEquivalent(for: shortcut) else {
            item.keyEquivalent = ""
            return
        }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = GlobalHotKey.flags(shortcut.modifiers)
    }

    private static func keyEquivalent(for shortcut: Shortcut) -> String? {
        if shortcut.keyCode == UInt32(kVK_Space) { return " " }
        return shortcut.key.count == 1 ? shortcut.key.lowercased() : nil
    }

    /// How a key is shown in the shortcut, when its character doesn't say (space, arrows, function keys).
    static func label(forKeyCode code: UInt16, characters: String?) -> String? {
        let named: [Int: String] = [
            kVK_Space: String(localized: "空白鍵"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(code)] { return name }
        guard let characters, let first = characters.first, !first.isWhitespace, !first.isNewline else { return nil }
        return String(first)
    }
}
