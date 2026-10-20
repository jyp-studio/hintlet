import CoreGraphics
import Foundation
import Testing
import StickyContextCore

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

private func scratchDefaults() -> UserDefaults {
    let name = "StickyContextCoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("便利貼設定")
struct NoteSettingsTests {
    @Test("預設 240×180、13 pt、黃色")
    func defaults() {
        let settings = NoteSettings.load(from: scratchDefaults())
        #expect(settings == NoteSettings(noteSize: CGSize(width: 240, height: 180), textSize: 13, noteColor: .yellow))
    }

    @Test("改過的大小、文字大小與顏色會記住")
    func roundTrip() {
        let defaults = scratchDefaults()
        var settings = NoteSettings.load(from: defaults)
        settings.noteSize = CGSize(width: 320, height: 260)
        settings.textSize = 16
        settings.noteColor = .green
        settings.save(to: defaults)

        #expect(NoteSettings.load(from: defaults) == settings)
    }

    @Test("超出範圍的值被拉回範圍內")
    func clamps() {
        var settings = NoteSettings()
        settings.noteSize = CGSize(width: 20, height: 5000)
        settings.textSize = 40
        #expect(settings.noteSize == CGSize(width: NoteSettings.widths.lowerBound, height: NoteSettings.heights.upperBound))
        #expect(settings.textSize == NoteSettings.textSizes.upperBound)
    }

    @Test("新便利貼用設定的大小與顏色，已有的便利貼不變")
    func newNotesUseTheSettings() {
        let engine = NoteEngine(screens: [Screen(frame: screen, visibleFrame: screen)])
        let old = engine.createNote(at: CGPoint(x: 100, y: 800))

        engine.newNoteSize = CGSize(width: 300, height: 200)
        engine.newNoteColor = .pink
        let new = engine.createNote(at: CGPoint(x: 600, y: 800))

        let notes = Dictionary(uniqueKeysWithValues: engine.displayedNotes.map { ($0.id, $0) })
        #expect(notes[old]?.frame.size == CGSize(width: 240, height: 180))
        #expect(notes[old]?.color == .yellow)
        #expect(notes[new]?.frame == CGRect(x: 600, y: 600, width: 300, height: 200))
        #expect(notes[new]?.color == .pink)
    }
}

@Suite("便利貼設定：大小選項")
struct NoteSizePresetTests {
    @Test("小、中、大對應固定大小，其他都算自訂")
    func presets() {
        var settings = NoteSettings()
        #expect(settings.sizePreset == .medium)
        settings.noteSize = NoteSettings.SizePreset.large.size!
        #expect(settings.sizePreset == .large)
        settings.noteSize = CGSize(width: 250, height: 180)
        #expect(settings.sizePreset == .custom)
    }
}
