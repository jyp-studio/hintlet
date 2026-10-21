import Foundation

/// The AI settings the user picks: which model writes AI notes and what colour they are. Kept in the
/// app's preferences, never in the notes file; the API keys aren't here either (they are in the Keychain).
public struct AISettings: Equatable, Sendable {
    /// One that uploads only once the user has agreed to that.
    public var backend: SummaryBackend
    public var noteColor: NoteColor
    /// The `claude` and `codex` the user picked, when they aren't where Hintlet looks (`CommandLocator`).
    public var claudePath: String?
    public var codexPath: String?

    public init(backend: SummaryBackend = .onDevice, noteColor: NoteColor = .mist,
                claudePath: String? = nil, codexPath: String? = nil) {
        self.backend = backend
        self.noteColor = noteColor
        self.claudePath = claudePath
        self.codexPath = codexPath
    }

    static let backendKey = "aiBackend"
    static let colorKey = "aiNoteColor"
    static let claudePathKey = "aiClaudePath"
    static let codexPathKey = "aiCodexPath"

    public static func load(from defaults: UserDefaults) -> AISettings {
        AISettings(backend: defaults.string(forKey: backendKey).map(SummaryBackend.init(rawValue:)) ?? .onDevice,
                   // An ordinary note's colour (which earlier versions offered) gives way to the default.
                   noteColor: defaults.string(forKey: colorKey).flatMap(NoteColor.init(rawValue:))
                       .flatMap { NoteColor.aiColors.contains($0) ? $0 : nil } ?? .mist,
                   claudePath: defaults.string(forKey: claudePathKey), codexPath: defaults.string(forKey: codexPathKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(backend.rawValue, forKey: Self.backendKey)
        defaults.set(noteColor.rawValue, forKey: Self.colorKey)
        defaults.set(claudePath, forKey: Self.claudePathKey)
        defaults.set(codexPath, forKey: Self.codexPathKey)
    }
}
