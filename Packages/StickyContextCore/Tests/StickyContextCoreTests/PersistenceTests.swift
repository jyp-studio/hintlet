import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))

private let downloads = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads",
                                       frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                                       bundleID: "com.apple.finder")
private let report = ObservedWindow(id: WindowID(2), appName: "Pages", title: "報告.pages",
                                    frame: CGRect(x: 200, y: 150, width: 900, height: 700),
                                    bundleID: "com.apple.iWork.Pages", documentPath: "/Users/me/報告.pages")

/// A folder of its own for each test, removed afterwards.
private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("StickyContextTests-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private func relaunched(from engine: NoteEngine, in folder: TemporaryFolder) throws -> NoteEngine {
    try NoteStore(directory: folder.url).save(engine.document)
    let document = try #require(try NoteStore(directory: folder.url).load())
    return NoteEngine(screens: [laptop], document: document)
}

@Suite("儲存與讀回")
struct SavingAndLoading {
    @Test("以新引擎讀回同一資料夾，浮動便利貼的內容與位置都在")
    func floatingNotesComeBack() throws {
        let folder = TemporaryFolder()
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        engine.editText(of: id, to: "下一步：補測試\n第二行")
        engine.moveNote(id, to: CGPoint(x: 500, y: 200))

        let restored = try relaunched(from: engine, in: folder)

        #expect(restored.displayedNotes == engine.displayedNotes)
        #expect(restored.document == engine.document)
    }

    @Test("資料夾裡還沒有檔案時，讀到的是空的")
    func emptyFolderLoadsNothing() throws {
        let folder = TemporaryFolder()

        #expect(try NoteStore(directory: folder.url).load() == nil)
    }

    @Test("寫入後資料夾裡只有正式檔案，沒有留下暫存檔")
    func writesAtomically() throws {
        let folder = TemporaryFolder()
        let store = NoteStore(directory: folder.url)

        try store.save(NoteEngine(screens: [laptop]).document)
        try store.save(NoteEngine(screens: [laptop]).document)

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(files == ["Backups", "notes.json"])
    }

    @Test("每次啟動第一次存檔、之後每小時，備份一次舊檔，只留最近 5 份")
    func keepsFiveBackups() throws {
        let folder = TemporaryFolder()
        let clock = TestClock()
        let engine = NoteEngine(screens: [laptop])
        let id = engine.createNote(at: CGPoint(x: 300, y: 600))
        let store = NoteStore(directory: folder.url, now: { clock.now })

        for version in 1...8 {
            engine.editText(of: id, to: "第 \(version) 版")
            try store.save(engine.document)
            clock.advance(by: 20 * 60)
        }

        // Saves 1–8 are 20 minutes apart: the old file is backed up before saves 2, 5 and 8 (an hour apart),
        // and a new run backs up before its first save.
        #expect(try store.backups().count == 3)
        let nextRun = NoteStore(directory: folder.url, now: { clock.now })
        for version in 9...11 {
            engine.editText(of: id, to: "第 \(version) 版")
            try NoteStore(directory: folder.url, now: { clock.now }).save(engine.document)
        }
        try nextRun.save(engine.document)

        let backups = try nextRun.backups()
        #expect(backups.count == 5)
        let newest = try NoteStore.document(at: try #require(backups.last))
        #expect(NoteEngine(screens: [laptop], document: newest).displayedNotes.map(\.text) == ["第 11 版"])
    }

    @Test("讀不懂的檔案移到一旁保留，不會被新的存檔蓋掉")
    func setsAsideUnreadableFile() throws {
        let folder = TemporaryFolder()
        let store = NoteStore(directory: folder.url)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("不是 JSON".utf8).write(to: folder.url.appendingPathComponent("notes.json"))

        #expect(throws: NoteStore.LoadError.self) { try store.load() }
        let keptAt = try store.setAsideUnreadableFile()
        try store.save(NoteEngine(screens: [laptop]).document)

        #expect(try Data(contentsOf: keptAt) == Data("不是 JSON".utf8))
        #expect(try store.load() != nil)
    }
}

@Suite("格式版本")
struct FormatVersions {
    @Test("舊版本的檔案經過遷移後以目前版本讀入")
    func migratesOlderVersion() throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // A made-up version 0 that kept only the text and the screen position of each note.
        let old = #"{"formatVersion": 0, "items": [{"body": "舊的便利貼", "x": 100, "y": 300}]}"#
        try Data(old.utf8).write(to: folder.url.appendingPathComponent("notes.json"))
        let zeroToOne: NoteStore.Migration = { old in
            let items = old["items"] as? [[String: Any]] ?? []
            return ["notes": items.map { item -> [String: Any] in
                ["id": UUID().uuidString, "text": item["body"] ?? "", "createdAt": 0, "updatedAt": 0,
                 "binding": ["floating": ["frame": [[item["x"] ?? 0, item["y"] ?? 0], [240, 180]]]]]
            }]
        }

        let document = try #require(try NoteStore(directory: folder.url, migrations: NoteStore.migrations.merging([0: zeroToOne]) { current, _ in current }).load())

        let engine = NoteEngine(screens: [laptop], document: document)
        #expect(engine.displayedNotes.map(\.text) == ["舊的便利貼"])
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 100, y: 300, width: 240, height: 180)])
    }

    @Test("版本 1 的檔案（指紋還帶文件路徑）直接讀入")
    func readsVersionOne() throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let v1 = #"""
        {"formatVersion": 1, "notes": [{"id": "22222222-2222-2222-2222-222222222222", "text": "下載", "createdAt": 0,
          "updatedAt": 0, "binding": {"window": {"fingerprint": {"bundleID": "com.apple.finder", "appName": "Finder",
          "title": "Downloads", "documentPath": "/x", "frame": [[100, 200], [800, 600]]},
          "anchor": {"size": [240, 180], "fromRight": true, "fromTop": true, "horizontalInset": 16, "verticalInset": 40}}}}]}
        """#
        try Data(v1.utf8).write(to: folder.url.appendingPathComponent("notes.json"))

        let document = try #require(try NoteStore(directory: folder.url).load())

        #expect(NoteEngine(screens: [laptop], document: document).unmatchedNotes.map(\.title) == ["Downloads"])
    }

    @Test("版本 3 的檔案（還沒有網頁便利貼）直接讀入")
    func readsVersionThree() throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let v3 = #"""
        {"formatVersion": 3, "notes": [{"id": "44444444-4444-4444-4444-444444444444", "text": "報告", "createdAt": 0,
          "updatedAt": 0, "binding": {"document": {"path": "/Users/me/報告.pages",
          "anchor": {"size": [240, 180], "fromRight": true, "fromTop": true, "horizontalInset": 16, "verticalInset": 40}}}}]}
        """#
        try Data(v3.utf8).write(to: folder.url.appendingPathComponent("notes.json"))

        let document = try #require(try NoteStore(directory: folder.url).load())
        let engine = NoteEngine(screens: [laptop], document: document, pathExists: { _ in true })
        engine.observe(.window(report))

        #expect(engine.displayedNotes.map(\.text) == ["報告"])
    }

    @Test("網頁便利貼存檔後讀回，打開同一個網頁就出現")
    func webPageNotesRoundTrip() throws {
        let folder = TemporaryFolder()
        let page = ObservedWindow(id: WindowID(5), appName: "Safari", title: "指南", frame: CGRect(x: 100, y: 200, width: 1000, height: 700),
                                  bundleID: "com.apple.Safari", browserPage: .page(address: "https://example.com/guide", title: "指南"))
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(page))
        engine.editText(of: engine.createNote(at: CGPoint(x: 300, y: 700)), to: "第三步")

        let restored = try relaunched(from: engine, in: folder)
        restored.observe(.window(page))

        #expect(restored.displayedNotes.map(\.text) == ["第三步"])
    }

    @Test("比目前更新的版本不硬讀，回報看不懂")
    func refusesNewerVersion() throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(#"{"formatVersion": 99, "notes": []}"#.utf8).write(to: folder.url.appendingPathComponent("notes.json"))

        #expect(throws: NoteStore.LoadError.newerFormat(99)) { try NoteStore(directory: folder.url).load() }
    }
}

/// The window server's number for Downloads, with its app's process: the same while both are still running.
private let downloadsOnServer = ServerWindowKey(number: 4242, processID: 501, appLaunchedAt: Date(timeIntervalSince1970: 1_800_000_000))

@Suite("只有 Hintlet 重新啟動時")
struct RelaunchWhileWindowsStayOpen {
    @Test("視窗還開著（同一個系統視窗編號、同一次 App 執行），便利貼直接回來，不用確認")
    func comesBackOnTheSameWindow() throws {
        let folder = TemporaryFolder()
        var window = downloads
        window.serverKey = downloadsOnServer
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(window))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: "整理下載")

        let restored = try relaunched(from: engine, in: folder)
        window.id = WindowID(41)
        restored.observe(.window(window))

        #expect(restored.displayedNotes.map(\.text) == ["整理下載"])
        #expect(restored.displayedNotes.map(\.frame) == engine.displayedNotes.map(\.frame))
        #expect(restored.unmatchedNotes.isEmpty)
        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("視窗的 App 重新啟動過（編號相同也不算），仍進待找回")
    func appRelaunchedMeansAnotherWindow() throws {
        let folder = TemporaryFolder()
        var window = downloads
        window.serverKey = downloadsOnServer
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(window))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        let restored = try relaunched(from: engine, in: folder)
        window.id = WindowID(41)
        window.serverKey = ServerWindowKey(number: 4242, processID: 777, appLaunchedAt: Date(timeIntervalSince1970: 1_900_000_000))
        restored.observe(.window(window))

        #expect(restored.displayedNotes.isEmpty)
        #expect(restored.unmatchedNotes.map(\.reason) == [.relaunched])
    }

    @Test("同一次執行中關掉的視窗，不會因編號而自動回來")
    func closedWindowsStayUnmatched() {
        var window = downloads
        window.serverKey = downloadsOnServer
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(window))
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.windowsClosed([window.id])
        window.id = WindowID(41)
        engine.observe(.window(window))

        #expect(engine.displayedNotes.isEmpty)
    }
}

@Suite("重新啟動後的視窗便利貼")
struct RecoveryAfterRelaunch {
    private func engineWithNote(on window: ObservedWindow, text: String) -> (NoteEngine, NoteID) {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.window(window))
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.editText(of: id, to: text)
        return (engine, id)
    }

    @Test("重啟後視窗便利貼進待找回並帶原因，不顯示")
    func windowNotesWaitToBeFound() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")

        let restored = try relaunched(from: engine, in: folder)

        #expect(restored.displayedNotes.isEmpty)
        #expect(restored.unmatchedNotes == [UnmatchedNote(id: id, text: "整理下載", reason: .relaunched,
                                                       appName: "Finder", title: "Downloads")])
    }

    @Test("同一 App、同標題、同位置的視窗也不自動貼上，只提示「可能是這裡？」")
    func neverReattachesByItself() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)

        var reopened = downloads
        reopened.id = WindowID(41)
        restored.observe(.window(reopened))

        #expect(restored.displayedNotes.isEmpty)
        #expect(restored.recoveryCandidates == [RecoveryCandidate(
            noteID: id, windowID: WindowID(41), preview: "整理下載",
            noteFrame: CGRect(x: 300, y: 520, width: 240, height: 180))])
    }

    @Test("確認「可能是這裡？」後，便利貼回到該視窗上原本的相對位置")
    func confirmingReattaches() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)
        var reopened = downloads
        reopened.id = WindowID(41)
        reopened.frame = reopened.frame.offsetBy(dx: 50, dy: -20)
        restored.observe(.window(reopened))

        restored.confirmRecovery(of: id, on: WindowID(41))

        #expect(restored.displayedNotes.map(\.frame) == [CGRect(x: 350, y: 500, width: 240, height: 180)])
        #expect(restored.displayedNotes.map(\.windowID) == [WindowID(41)])
        #expect(restored.unmatchedNotes.isEmpty)
        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("提示所在的視窗已不是焦點時，確認不會貼到別的視窗")
    func confirmingOnALostWindowDoesNothing() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)
        var reopened = downloads
        reopened.id = WindowID(41)
        var other = downloads
        other.id = WindowID(42)
        restored.observe(.window(reopened))
        restored.observe(.window(other))

        restored.confirmRecovery(of: id, on: WindowID(41))

        #expect(restored.displayedNotes.isEmpty)
        #expect(restored.unmatchedNotes.map(\.id) == [id])
    }

    @Test("同一 App 但標題不同的視窗不提示")
    func differentTitleIsNotACandidate() throws {
        let folder = TemporaryFolder()
        let (engine, _) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)

        var desktop = downloads
        desktop.id = WindowID(41)
        desktop.title = "Desktop"
        restored.observe(.window(desktop))

        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("沒有標題的視窗不提示，即使待找回的便利貼也來自沒有標題的視窗")
    func untitledWindowsAreNotCandidates() throws {
        let folder = TemporaryFolder()
        var untitled = downloads
        untitled.title = ""
        let (engine, _) = engineWithNote(on: untitled, text: "沒有標題")
        let restored = try relaunched(from: engine, in: folder)

        untitled.id = WindowID(41)
        restored.observe(.window(untitled))

        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("別的 App 的視窗不會出現提示")
    func otherAppsAreNotCandidates() throws {
        let folder = TemporaryFolder()
        let (engine, _) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)

        restored.observe(.window(report))

        #expect(restored.recoveryCandidates.isEmpty)
    }

    @Test("同標題的多張待找回，原本位置離目前視窗較近的排前面")
    func nearerWindowComesFirst() throws {
        let folder = TemporaryFolder()
        let engine = NoteEngine(screens: [laptop])
        var left = downloads
        left.frame = CGRect(x: 0, y: 200, width: 600, height: 500)
        var right = downloads
        right.id = WindowID(3)
        right.frame = CGRect(x: 800, y: 200, width: 600, height: 500)
        engine.observe(.window(left))
        let onLeft = engine.createNote(at: CGPoint(x: 100, y: 600))
        engine.observe(.window(right))
        let onRight = engine.createNote(at: CGPoint(x: 900, y: 600))
        let restored = try relaunched(from: engine, in: folder)

        var reopened = right
        reopened.id = WindowID(41)
        reopened.frame = right.frame.offsetBy(dx: -30, dy: 10)
        restored.observe(.window(reopened))

        #expect(restored.recoveryCandidates.map(\.noteID) == [onRight, onLeft])
    }

    @Test("按掉提示後，同標題的其他視窗、重啟之後都不再提示這張")
    func dismissingStopsSuggestingTheNote() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)
        var first = downloads
        first.id = WindowID(41)
        var second = downloads
        second.id = WindowID(42)

        restored.observe(.window(first))
        restored.dismissRecovery(of: id, on: WindowID(41))
        #expect(restored.recoveryCandidates.isEmpty)

        restored.observe(.window(second))
        #expect(restored.recoveryCandidates.isEmpty)

        let again = try relaunched(from: restored, in: folder)
        again.observe(.window(second))
        #expect(again.recoveryCandidates.isEmpty)
        #expect(again.unmatchedNotes.map(\.id) == [id])
    }

    @Test("按掉提示的便利貼重新綁定後，視窗再關掉時又會提示")
    func boundAgainItIsSuggestedAgain() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)
        var reopened = downloads
        reopened.id = WindowID(41)
        restored.observe(.window(reopened))
        restored.dismissRecovery(of: id, on: WindowID(41))

        restored.rebindToCurrentContext(id)
        restored.windowsClosed([WindowID(41)])
        var later = downloads
        later.id = WindowID(42)
        restored.observe(.window(later))

        #expect(restored.recoveryCandidates.map(\.noteID) == [id])
    }

    @Test("在別的視窗按掉提示不算數")
    func dismissingOnAnotherWindowIsIgnored() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        let restored = try relaunched(from: engine, in: folder)
        var reopened = downloads
        reopened.id = WindowID(41)
        restored.observe(.window(reopened))

        restored.dismissRecovery(of: id, on: WindowID(99))

        #expect(restored.recoveryCandidates.map(\.noteID) == [id])
    }

    @Test("待找回的便利貼一直留著，再存檔、再重啟都不會消失")
    func unmatchedNotesAreNeverDropped() throws {
        let folder = TemporaryFolder()
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")
        var restored = try relaunched(from: engine, in: folder)
        restored.observe(.window(report))
        restored.observe(.unidentified)

        restored = try relaunched(from: restored, in: folder)
        restored = try relaunched(from: restored, in: folder)

        #expect(restored.unmatchedNotes.map(\.id) == [id])
    }

    @Test("視窗關閉後，它的便利貼這次執行中就進待找回，重新打開時提示")
    func closedWindowNotesWaitToBeFound() {
        let (engine, id) = engineWithNote(on: downloads, text: "整理下載")

        engine.windowsClosed([downloads.id])
        #expect(engine.displayedNotes.isEmpty)
        #expect(engine.unmatchedNotes.map(\.reason) == [.windowClosed])
        #expect(engine.recoveryCandidates.isEmpty)

        var reopened = downloads
        reopened.id = WindowID(41)
        engine.observe(.window(reopened))
        #expect(engine.recoveryCandidates.map(\.noteID) == [id])
    }

    @Test("重啟後讀回的便利貼保留視窗最後的標題與位置，供候選提示")
    func fingerprintFollowsTheWindow() throws {
        let folder = TemporaryFolder()
        let (engine, _) = engineWithNote(on: downloads, text: "整理下載")
        var renamed = downloads
        renamed.title = "下載項目"
        engine.observe(.window(renamed))

        let restored = try relaunched(from: engine, in: folder)

        #expect(restored.unmatchedNotes.map(\.title) == ["下載項目"])
    }
}
