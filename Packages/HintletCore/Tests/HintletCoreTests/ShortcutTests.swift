import Foundation
import Testing
import HintletCore

// Virtual key codes of a US layout, as macOS reports them.
private let keyN: UInt32 = 45
private let keyL: UInt32 = 37
private let keyK: UInt32 = 40
private let keySpace: UInt32 = 49

@Suite("全域快捷鍵設定")
struct ShortcutSettingsTests {
    @Test("預設是 ⌘⌥N 新增、⌘⌥L 列表，照 macOS 的順序顯示")
    func defaults() {
        let settings = ShortcutSettings.defaults

        #expect(settings[.newNote] == Shortcut(keyCode: keyN, modifiers: [.command, .option], key: "N"))
        #expect(settings[.showList] == Shortcut(keyCode: keyL, modifiers: [.command, .option], key: "L"))
        #expect(settings[.hideAll] == Shortcut(keyCode: 4, modifiers: [.control, .option], key: "H"))
        #expect(settings[.newNote].displayString == "⌥⌘N")
        #expect(Shortcut(keyCode: keyK, modifiers: [.command, .shift, .control, .option], key: "k").displayString == "⌃⌥⇧⌘K")
    }

    @Test("沒有修飾鍵、只有 ⇧，或只有 ⌘（很多 App 自己在用）的組合不能當全域快捷鍵")
    func needsAModifier() {
        let settings = ShortcutSettings.defaults

        #expect(settings.problem(setting: Shortcut(keyCode: keyK, modifiers: [], key: "K"), for: .newNote) == .needsModifier)
        #expect(settings.problem(setting: Shortcut(keyCode: keyK, modifiers: [.shift], key: "K"), for: .newNote) == .needsModifier)
        #expect(settings.problem(setting: Shortcut(keyCode: keyK, modifiers: [.command], key: "K"), for: .newNote) == .commonInApps)
        #expect(settings.problem(setting: Shortcut(keyCode: keyK, modifiers: [.command, .shift], key: "K"), for: .newNote) == .commonInApps)
        #expect(settings.problem(setting: Shortcut(keyCode: keyK, modifiers: [.control, .option], key: "K"), for: .newNote) == nil)
    }

    @Test("和 Hintlet 另一個快捷鍵相同時提示衝突；設回自己目前的不算")
    func clashesWithTheOtherAction() {
        let settings = ShortcutSettings.defaults
        let list = settings[.showList]

        #expect(settings.problem(setting: list, for: .newNote) == .usedBy(.showList))
        #expect(settings.problem(setting: list, for: .showList) == nil)
    }

    @Test("和系統快捷鍵（例如 Spotlight）相同時提示衝突")
    func clashesWithTheSystem() {
        let spotlight = Shortcut(keyCode: keySpace, modifiers: [.command, .option], key: "Space")
        let settings = ShortcutSettings.defaults

        #expect(settings.problem(setting: Shortcut(keyCode: keySpace, modifiers: [.command, .option], key: "␣"),
                                 for: .newNote, systemShortcuts: [spotlight]) == .usedBySystem)
    }

    @Test("比較快捷鍵只看按鍵與修飾鍵，不看顯示的字")
    func comparesKeysNotLabels() {
        #expect(Shortcut(keyCode: keyN, modifiers: [.command, .option], key: "N")
            .sameKeys(as: Shortcut(keyCode: keyN, modifiers: [.option, .command], key: "ñ")))
        #expect(!Shortcut(keyCode: keyN, modifiers: [.command, .option], key: "N")
            .sameKeys(as: Shortcut(keyCode: keyN, modifiers: [.command, .control], key: "N")))
    }

    @Test("設定存成資料後原樣讀回；讀不懂時用預設")
    func persists() throws {
        var settings = ShortcutSettings.defaults
        settings[.newNote] = Shortcut(keyCode: keyK, modifiers: [.control, .option], key: "K")

        #expect(ShortcutSettings(data: try settings.data()) == settings)
        #expect(ShortcutSettings(data: Data("壞掉".utf8)) == .defaults)
        #expect(ShortcutSettings(data: nil) == .defaults)
    }
}
