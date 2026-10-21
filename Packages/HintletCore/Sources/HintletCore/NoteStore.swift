import Foundation

/// Keeps the notes in a single JSON file in `directory`, written atomically, with up to five backups of
/// earlier versions in `Backups`.
public final class NoteStore {
    /// Turns a file of one format version into the next: `migrations[n]` takes version n to n + 1.
    public typealias Migration = @Sendable ([String: Any]) throws -> [String: Any]

    public static let migrations: [Int: Migration] = [
        // Versions 2 and 3 only added kinds of binding; older files read as they are.
        1: { $0 },
        2: { $0 },
        // Version 4 only added web page notes.
        3: { $0 },
        // Version 5 only added a kind of conversation (Claude Code in a terminal).
        4: { $0 },
        // Version 6 only added AI notes (`StoredNote.ai`); every older note is handwritten.
        5: { $0 },
        // Version 7 only added a kind of conversation (Codex threads).
        6: { $0 },
    ]
    static let backupsToKeep = 5
    /// Autosave writes often; a backup an hour (and one per run) keeps the backups far enough apart to help.
    static let backupInterval: TimeInterval = 60 * 60

    public enum LoadError: Error, Equatable {
        /// Written by a newer Hintlet; reading it could lose what this version doesn't know about.
        case newerFormat(Int)
        case unreadable
    }

    private let directory: URL
    private let migrations: [Int: Migration]
    private let now: () -> Date
    private var lastBackup: Date?

    public init(directory: URL, migrations: [Int: Migration] = NoteStore.migrations,
                now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.migrations = migrations
        self.now = now
    }

    public var fileURL: URL { directory.appendingPathComponent("notes.json") }
    private var backupsURL: URL { directory.appendingPathComponent("Backups") }

    /// Nil when nothing has been saved yet.
    public func load() throws -> NotesDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Self.document(at: fileURL, migrations: migrations)
    }

    public static func document(at url: URL, migrations: [Int: Migration] = NoteStore.migrations) throws -> NotesDocument {
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var version = object["formatVersion"] as? Int else { throw LoadError.unreadable }
        guard version <= NotesDocument.currentVersion else { throw LoadError.newerFormat(version) }
        while version < NotesDocument.currentVersion {
            guard let migrate = migrations[version], let migrated = try? migrate(object) else { throw LoadError.unreadable }
            object = migrated
            version += 1
            object["formatVersion"] = version
        }
        do {
            let current = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(NotesDocument.self, from: current)
        } catch {
            throw LoadError.unreadable
        }
    }

    /// Writes every note to a single backup file, in the same format as the notes file itself, so
    /// `document(at:)` reads it back (migrating it if it comes from an older Hintlet).
    public static func export(_ document: NotesDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    public func save(_ document: NotesDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path),
           lastBackup.map({ now().timeIntervalSince($0) >= Self.backupInterval }) ?? true {
            // A backup that fails mustn't stop the notes themselves being saved.
            try? backUpCurrentFile()
            lastBackup = now()
        }
        try Self.encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    /// Backups, oldest first.
    public func backups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)
            .filter { Self.backupNumber(of: $0) != nil }
            .sorted { Self.backupNumber(of: $0)! < Self.backupNumber(of: $1)! }
    }

    /// Moves a file that couldn't be loaded out of the way, so saving afresh never overwrites it.
    /// Returns where it now is.
    public func setAsideUnreadableFile() throws -> URL {
        var number = 1
        var destination: URL
        repeat {
            destination = directory.appendingPathComponent("notes.unreadable-\(number).json")
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func backUpCurrentFile() throws {
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let existing = try backups()
        let next = (existing.last.flatMap(Self.backupNumber) ?? 0) + 1
        try FileManager.default.copyItem(at: fileURL,
                                         to: backupsURL.appendingPathComponent(String(format: "notes-%06d.json", next)))
        for old in try backups().dropLast(Self.backupsToKeep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func backupNumber(of url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", name.hasPrefix("notes-") else { return nil }
        return Int(name.dropFirst("notes-".count))
    }

    /// Both keep dates as seconds since 2001 (Foundation's own reference date), which read back exactly.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
