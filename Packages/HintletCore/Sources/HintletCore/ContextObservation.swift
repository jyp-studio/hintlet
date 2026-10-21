import CoreGraphics
import Foundation

/// Identifies one window for as long as Hintlet runs. The App layer hands these out; they are never
/// derived from a window's title, which is not unique and changes.
public struct WindowID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A window as the window server numbers it, with the run of the app that owns it. Both outlive a restart
/// of Hintlet but not of the app (or the Mac), so a match means it is exactly the same window.
public struct ServerWindowKey: Hashable, Codable, Sendable {
    public var number: UInt32
    public var processID: Int32
    public var appLaunchedAt: Date

    public init(number: UInt32, processID: Int32, appLaunchedAt: Date) {
        self.number = number
        self.processID = processID
        self.appLaunchedAt = appLaunchedAt
    }
}

/// The focused window of the frontmost app, as last observed.
public struct ObservedWindow: Equatable, Sendable {
    public var id: WindowID
    public var appName: String
    /// Shown in the scope label only; never used to match notes.
    public var title: String
    /// AppKit global coordinates.
    public var frame: CGRect
    public var isMinimized: Bool
    /// Notes follow the frame either way; the state tells when the frame is mid-transition.
    public var isFullScreen: Bool
    /// Remembered with the note, to suggest windows of the same app after a relaunch.
    public var bundleID: String?
    /// The file or folder the window shows, when it can be told (a folder's path ends in "/"). Notes made
    /// on such a window belong to that place, whichever window shows it.
    public var documentPath: String?
    /// For a Claude window whose page could be read: which conversation (or other page) it shows.
    public var claudePage: ClaudePage?
    /// For a browser window: which web page it shows, if it can be told.
    public var browserPage: BrowserPage?
    /// When it can be told; lets notes find this window again after Hintlet restarts.
    public var serverKey: ServerWindowKey?

    public init(id: WindowID, appName: String, title: String, frame: CGRect,
                isMinimized: Bool = false, isFullScreen: Bool = false,
                bundleID: String? = nil, documentPath: String? = nil, claudePage: ClaudePage? = nil,
                browserPage: BrowserPage? = nil, serverKey: ServerWindowKey? = nil) {
        self.id = id
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.bundleID = bundleID
        self.documentPath = documentPath
        self.claudePage = claudePage
        self.browserPage = browserPage
        self.serverKey = serverKey
    }
}

/// What the user is working on right now, as far as the system lets us tell.
public enum ContextObservation: Equatable, Sendable {
    /// The frontmost app's focused window.
    case window(ObservedWindow)
    /// Focus is changing or cannot be identified (no window, no permission, the app not answering).
    case unidentified
    /// Hintlet itself is frontmost, e.g. while the user types in a note; the previous context still applies.
    case ownApp
}

/// The scope label on a displayed note: what it is attached to.
public enum ScopeLabel: Equatable, Sendable {
    case floating
    case window(appName: String, title: String)
    case document(appName: String, name: String, isFolder: Bool)
    case conversation(title: String)
    /// On the window only because the page couldn't be told (e.g. Claude's projects page).
    case windowFallback(appName: String, title: String)
    /// A web page, by its title; `address` is for the tooltip.
    case webPage(title: String, address: String)
    /// On a browser window only because its page can't be bound to (the browser's settings, extensions).
    case webPageFallback(appName: String, title: String)
}

/// Where a new note should go.
public enum NoteScope: Sendable {
    /// The finest context that can be told for sure.
    case automatic
    /// The focused window, whatever it shows (e.g. "改貼在這個視窗" on a new Claude conversation).
    case window
}

/// What a note can be bound to, as the scope menu offers it.
public enum BindingScope: Equatable, Sendable {
    /// The Claude conversation the window shows.
    case conversation
    /// The file or folder the window shows, in whichever window shows it.
    case document
    /// The web page the browser shows, in whichever tab or window shows it.
    case webPage
    /// The window itself, whatever it shows.
    case window
    /// No binding: always shown, on every desktop.
    case floating
}

/// One entry of a note's scope menu.
public struct ScopeOption: Equatable, Sendable {
    public let scope: BindingScope
    /// What the note's label would say bound this way.
    public let label: ScopeLabel
    public let isCurrent: Bool

    public init(scope: BindingScope, label: ScopeLabel, isCurrent: Bool) {
        self.scope = scope
        self.label = label
        self.isCurrent = isCurrent
    }
}

/// Why no note can be made on what the user is looking at.
public enum CreationBlock: Equatable, Sendable {
    /// A new Claude conversation, not sent yet: it has no ID to bind to.
    case draftConversation
    /// Claude's settings are open over the conversation.
    case claudeSettings
    /// A browser's new tab or start page: no web page to bind to yet.
    case newBrowserTab
}
