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
    /// Backends that upload, which the user has agreed to once; switching back to one doesn't ask again.
    public var agreedUploads: Set<SummaryBackend>

    public init(backend: SummaryBackend = .onDevice, noteColor: NoteColor = .mist,
                claudePath: String? = nil, codexPath: String? = nil, agreedUploads: Set<SummaryBackend> = []) {
        self.backend = backend
        self.noteColor = noteColor
        self.claudePath = claudePath
        self.codexPath = codexPath
        self.agreedUploads = agreedUploads
    }

    /// Whether switching to `backend` must first say where the conversation goes and ask.
    public func needsAgreement(for backend: SummaryBackend) -> Bool {
        backend.uploadsContent && !agreedUploads.contains(backend)
    }

    /// Switches to `backend`, which the user has agreed to if it uploads.
    public mutating func choose(_ backend: SummaryBackend) {
        if backend.uploadsContent { agreedUploads.insert(backend) }
        self.backend = backend
    }

    static let backendKey = "aiBackend"
    static let colorKey = "aiNoteColor"
    static let claudePathKey = "aiClaudePath"
    static let codexPathKey = "aiCodexPath"
    static let agreedKey = "aiAgreedUploads"

    public static func load(from defaults: UserDefaults) -> AISettings {
        let backend = defaults.string(forKey: backendKey).map(SummaryBackend.init(rawValue:)) ?? .onDevice
        // Before this was kept, the backend in use was the only one known to be agreed to.
        let agreed = defaults.stringArray(forKey: agreedKey).map { Set($0.map(SummaryBackend.init(rawValue:))) }
            ?? (backend.uploadsContent ? [backend] : [])
        return AISettings(backend: backend,
                   // An ordinary note's colour (which earlier versions offered) gives way to the default.
                   noteColor: defaults.string(forKey: colorKey).flatMap(NoteColor.init(rawValue:))
                       .flatMap { NoteColor.aiColors.contains($0) ? $0 : nil } ?? .mist,
                   claudePath: defaults.string(forKey: claudePathKey), codexPath: defaults.string(forKey: codexPathKey),
                   agreedUploads: agreed)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(backend.rawValue, forKey: Self.backendKey)
        defaults.set(noteColor.rawValue, forKey: Self.colorKey)
        defaults.set(claudePath, forKey: Self.claudePathKey)
        defaults.set(codexPath, forKey: Self.codexPathKey)
        defaults.set(agreedUploads.map(\.rawValue).sorted(), forKey: Self.agreedKey)
    }
}
