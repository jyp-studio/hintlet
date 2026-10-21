import Foundation

/// Where Claude keeps its Cowork and Code sessions on this Mac: `<root>/<folder>/<account>/<organisation>/local_<uuid>.json`,
/// with `root` normally `~/Library/Application Support/Claude`. Chat keeps no local file.
public struct ClaudeSessionFolder: Sendable {
    public enum Status: Equatable, Sendable {
        case present
        /// Not there, while the folder holds other sessions: deleted, or (for a moment) being rewritten.
        case missing
        /// Claude left a deletion mark for it (Code does): deleted for sure.
        case deleted
        /// Can't be told: Chat, or no readable session folder with sessions in it.
        case unknown
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The session's file, if it is there.
    public func file(for ref: ConversationRef) -> URL? {
        organisations(for: ref.kind).lazy.map { $0.appendingPathComponent("\(ref.id).json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func status(of ref: ConversationRef) -> Status {
        let organisations = organisations(for: ref.kind)
        let manager = FileManager.default
        var hasOtherSessions = false
        for organisation in organisations {
            if manager.fileExists(atPath: organisation.appendingPathComponent("\(ref.id).json").path) { return .present }
            if let mark = Self.deletionMark(for: ref),
               manager.fileExists(atPath: organisation.appendingPathComponent(mark).path) { return .deleted }
            let names = (try? manager.contentsOfDirectory(atPath: organisation.path)) ?? []
            if names.contains(where: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) { hasOtherSessions = true }
        }
        return hasOtherSessions ? .missing : .unknown
    }

    /// Code renames a deleted `local_<uuid>` session to `deleted_<uuid>`.
    private static func deletionMark(for ref: ConversationRef) -> String? {
        guard ref.kind == .code, ref.id.hasPrefix("local_") else { return nil }
        return "deleted_" + ref.id.dropFirst("local_".count)
    }

    private func organisations(for kind: ConversationKind) -> [URL] {
        let folder: String
        switch kind {
        case .chat, .cli, .codex: return []
        case .cowork: folder = "local-agent-mode-sessions"
        case .code: folder = "claude-code-sessions"
        }
        let manager = FileManager.default
        let accounts = (try? manager.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
        return accounts.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
    }
}

/// Tells which Cowork and Code sessions were deleted in Claude, never guessing: a session counts as deleted
/// when Claude marked it so, or when its file is missing on two checks in a row while other sessions are
/// there. Anything that can't be told (Chat, no session folder) is never deleted.
public final class SessionDeletionDetector {
    private let files: ClaudeSessionFolder
    /// Missing on the last check.
    private var missingLastTime: Set<ConversationRef> = []

    public init(files: ClaudeSessionFolder) {
        self.files = files
    }

    public func deletedSessions(among refs: Set<ConversationRef>) -> Set<ConversationRef> {
        var deleted: Set<ConversationRef> = []
        var missing: Set<ConversationRef> = []
        for ref in refs {
            switch files.status(of: ref) {
            case .deleted: deleted.insert(ref)
            case .missing:
                missing.insert(ref)
                if missingLastTime.contains(ref) { deleted.insert(ref) }
            case .present, .unknown: break
            }
        }
        missingLastTime = missing.subtracting(deleted)
        return deleted
    }
}
