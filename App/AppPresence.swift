import AppKit

/// Hintlet lives in the menu bar only, with no Dock icon or menu bar of its own, like a desktop pet: its
/// notes never take focus from the app the user is in, so they show over full-screen apps and on every
/// Space without delay. It comes forward only for its own windows (the list, the settings) and, briefly,
/// for typing in a note just made.
@MainActor
enum AppPresence {
    static func comeForward() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
