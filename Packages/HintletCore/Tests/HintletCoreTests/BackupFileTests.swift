import CoreGraphics
import Foundation
import Testing
import HintletCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let downloads = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads",
                                       frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                                       bundleID: "com.apple.finder")

/// A file of its own for each test, removed afterwards.
private final class TemporaryFile {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HintletExport-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Hintlet 備份.json")
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

@Suite("匯出與匯入備份")
struct ExportAndImport {
    @Test("匯出後在另一台（新的引擎）匯入，便利貼全部回來")
    func roundTrip() throws {
        let file = TemporaryFile()
        let engine = NoteEngine(screens: [laptop])
        let floating = engine.createNote(at: CGPoint(x: 1200, y: 900))
        engine.editText(of: floating, to: "浮動的")
        engine.setColor(of: floating, to: .pink)
        engine.observe(.window(downloads))
        let onWindow = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: onWindow, to: "整理下載")
        let trashed = engine.createNote(at: CGPoint(x: 400, y: 700))
        engine.editText(of: trashed, to: "丟掉的")
        engine.deleteNote(trashed)

        try NoteStore.export(engine.document, to: file.url)
        let elsewhere = NoteEngine(screens: [laptop])
        let backup = try NoteStore.document(at: file.url)
        let summary = elsewhere.importNotes(backup)

        #expect(backup.noteCount == 3)
        #expect(summary == ImportSummary(added: 3, updated: 0))
        #expect(elsewhere.document == NoteEngine(screens: [laptop], document: engine.document).document)
        #expect(elsewhere.displayedNotes.map(\.text) == ["浮動的"])
        #expect(elsewhere.unmatchedNotes.map(\.text) == ["整理下載"])
        #expect(elsewhere.trashedNotes.map(\.text) == ["丟掉的"])
    }

    @Test("匯入到已有便利貼的地方：新的加入，同一張只留較新的版本，不會重複")
    func mergesWithExistingNotes() throws {
        let file = TemporaryFile()
        let clock = TestClock()
        let engine = NoteEngine(screens: [laptop], now: { clock.now })
        let shared = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: shared, to: "舊內容")
        try NoteStore.export(engine.document, to: file.url)

        clock.advance(by: 60)
        engine.editText(of: shared, to: "新內容")
        let onlyHere = engine.createNote(at: CGPoint(x: 600, y: 600))
        engine.editText(of: onlyHere, to: "只有這裡有")
        let backup = try NoteStore.document(at: file.url)

        // The backup's version of the shared note is older: it is left as it is.
        #expect(engine.importNotes(backup) == ImportSummary(added: 0, updated: 0))
        #expect(engine.displayedNotes.map(\.text).sorted() == ["只有這裡有", "新內容"])

        // The other way round, the newer version wins.
        let older = NoteEngine(screens: [laptop], document: backup)
        #expect(older.importNotes(engine.document) == ImportSummary(added: 1, updated: 1))
        #expect(older.displayedNotes.map(\.text).sorted() == ["只有這裡有", "新內容"])
    }

    @Test("匯入舊版本的備份檔，先遷移再讀入")
    func importsOlderFormat() throws {
        let file = TemporaryFile()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let v1 = #"""
        {"formatVersion": 1, "notes": [{"id": "22222222-2222-2222-2222-222222222222", "text": "下載", "createdAt": 0,
          "updatedAt": 0, "binding": {"floating": {"frame": [[100, 300], [240, 180]]}}}]}
        """#
        try Data(v1.utf8).write(to: file.url)

        let engine = NoteEngine(screens: [laptop])
        engine.importNotes(try NoteStore.document(at: file.url))

        #expect(engine.displayedNotes.map(\.text) == ["下載"])
    }

    @Test("較新版本或讀不懂的備份檔不匯入")
    func refusesNewerOrBrokenFiles() throws {
        let file = TemporaryFile()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(#"{"formatVersion": 99, "notes": []}"#.utf8).write(to: file.url)
        #expect(throws: NoteStore.LoadError.newerFormat(99)) { try NoteStore.document(at: file.url) }

        try Data("不是 JSON".utf8).write(to: file.url)
        #expect(throws: NoteStore.LoadError.unreadable) { try NoteStore.document(at: file.url) }
    }

    @Test("匯出檔帶有格式版本")
    func exportCarriesFormatVersion() throws {
        let file = TemporaryFile()

        try NoteStore.export(NoteEngine(screens: [laptop]).document, to: file.url)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == NotesDocument.currentVersion)
    }
}
