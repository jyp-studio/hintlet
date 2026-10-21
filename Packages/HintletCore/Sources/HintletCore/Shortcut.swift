import Foundation

/// A key combination for a global shortcut: a virtual key code with its modifiers, plus the key as the
/// keyboard showed it when it was recorded (the code alone can't be shown without the keyboard layout).
public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers
    public var key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key.uppercased()
    }

    /// In the order macOS menus show them: ⌃⌥⇧⌘.
    public var displayString: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    /// The same keys pressed, whatever the label.
    public func sameKeys(as other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// What the global shortcuts do. New ones are added here and get a default in `ShortcutSettings.defaults`.
public enum ShortcutAction: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case newNote
    case showList
    case hideAll
}

/// Why a combination can't be used.
public enum ShortcutProblem: Equatable, Sendable {
    /// Without ⌘, ⌥ or ⌃ it would take over ordinary typing.
    case needsModifier
    /// ⌘ (with or without ⇧) is what apps use for their own menus.
    case commonInApps
    case usedBy(ShortcutAction)
    /// One of the shortcuts in System Settings › Keyboard › Keyboard Shortcuts.
    case usedBySystem
}

/// The user's choice of global shortcuts.
public struct ShortcutSettings: Codable, Equatable, Sendable {
    private var shortcuts: [ShortcutAction: Shortcut]

    // Virtual key codes of N, L and H. ⌥⌘H is every app's "Hide Others", so hiding notes takes ⌃⌥H.
    public static let defaults = ShortcutSettings(shortcuts: [
        .newNote: Shortcut(keyCode: 45, modifiers: [.command, .option], key: "N"),
        .showList: Shortcut(keyCode: 37, modifiers: [.command, .option], key: "L"),
        .hideAll: Shortcut(keyCode: 4, modifiers: [.control, .option], key: "H"),
    ])

    private init(shortcuts: [ShortcutAction: Shortcut]) {
        self.shortcuts = shortcuts
    }

    /// What was stored by `data()`; the defaults when there is nothing, or nothing readable.
    public init(data: Data?) {
        guard let data, let stored = try? JSONDecoder().decode(ShortcutSettings.self, from: data) else {
            self = .defaults
            return
        }
        // An action added in a later version keeps its default.
        self = ShortcutSettings(shortcuts: Self.defaults.shortcuts.merging(stored.shortcuts) { _, chosen in chosen })
    }

    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public subscript(action: ShortcutAction) -> Shortcut {
        get { shortcuts[action] ?? Self.defaults.shortcuts[action]! }
        set { shortcuts[action] = newValue }
    }

    /// Why `shortcut` can't be set for `action`, or nil when it can. Clashes with other apps only show
    /// when registering it fails.
    public func problem(setting shortcut: Shortcut, for action: ShortcutAction,
                        systemShortcuts: [Shortcut] = []) -> ShortcutProblem? {
        let modifiers = shortcut.modifiers
        if modifiers.isDisjoint(with: [.command, .option, .control]) { return .needsModifier }
        if modifiers.subtracting(.shift) == .command { return .commonInApps }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self[$0].sameKeys(as: shortcut) }) {
            return .usedBy(other)
        }
        if systemShortcuts.contains(where: { $0.sameKeys(as: shortcut) }) { return .usedBySystem }
        return nil
    }
}
