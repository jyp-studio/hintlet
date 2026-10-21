import AppKit
import HintletCore

/// The menu bar while Hintlet is in front, as it is while a note is clicked into: the app's own menus,
/// with the 便利貼 menu acting on that note.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    /// What the app does for the menus; the 便利貼 menu goes to the overlay directly.
    struct Actions {
        var showSettings: () -> Void
        var newNote: () -> Void
        var exportNotes: () -> Void
        var importBackup: () -> Void
        var showList: () -> Void
        var toggleHideAll: () -> Void
        var isHidingAll: () -> Bool
        /// By this many points, or back to the default for nil.
        var changeTextSize: (CGFloat?) -> Void
        var toggleWindowNotesHidden: () -> Void
        var deleteWindowNotes: () -> Void
        /// Puts a global shortcut's keys on its item.
        var showShortcut: (ShortcutAction, NSMenuItem) -> Void
    }

    private let engine: NoteEngine
    private let overlay: OverlayController
    private let actions: Actions
    private var shortcutItems: [(ShortcutAction, NSMenuItem)] = []

    init(engine: NoteEngine, overlay: OverlayController, actions: Actions) {
        self.engine = engine
        self.overlay = overlay
        self.actions = actions
    }

    func install() {
        let main = NSMenu()
        main.addItem(submenu(String(localized: "Hintlet"), appMenu()))
        main.addItem(submenu(String(localized: "檔案"), fileMenu()))
        main.addItem(submenu(String(localized: "編輯"), editMenu()))
        main.addItem(submenu(String(localized: "格式"), formatMenu()))
        main.addItem(submenu(String(localized: "顯示方式"), viewMenu()))
        main.addItem(submenu(String(localized: "便利貼"), noteMenu()))
        let window = windowMenu()
        main.addItem(submenu(String(localized: "視窗"), window))
        let help = helpMenu()
        main.addItem(submenu(String(localized: "說明"), help))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        showShortcuts()
    }

    /// The global shortcuts changed: their items say the new keys.
    func showShortcuts() {
        for (action, item) in shortcutItems { actions.showShortcut(action, item) }
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "關於 Hintlet"), #selector(about)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "設定…"), #selector(showSettings), ","))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu(String(localized: "服務"), services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        // No "隱藏 Hintlet" (⌘H): hiding the app would take every note off screen until it is brought back.
        menu.addItem(item(String(localized: "隱藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                          modifiers: [.command, .option], toResponders: true))
        menu.addItem(item(String(localized: "全部顯示"), #selector(NSApplication.unhideAllApplications(_:)), toResponders: true))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "結束 Hintlet"), #selector(NSApplication.terminate(_:)), "q", toResponders: true))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "新增便利貼"), #selector(newNote), "n"))
        menu.addItem(item(String(localized: "關閉視窗"), #selector(closeWindow), "w"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "匯入備份…"), #selector(importBackup)))
        menu.addItem(item(String(localized: "匯出全部便利貼…"), #selector(exportNotes)))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "還原"), Selector(("undo:")), "z", toResponders: true))
        menu.addItem(item(String(localized: "重做"), Selector(("redo:")), "z", modifiers: [.command, .shift], toResponders: true))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "剪下"), #selector(NSText.cut(_:)), "x", toResponders: true))
        menu.addItem(item(String(localized: "拷貝"), #selector(NSText.copy(_:)), "c", toResponders: true))
        menu.addItem(item(String(localized: "貼上"), #selector(NSText.paste(_:)), "v", toResponders: true))
        menu.addItem(item(String(localized: "刪除"), #selector(NSText.delete(_:)), toResponders: true))
        menu.addItem(item(String(localized: "全選"), #selector(NSText.selectAll(_:)), "a", toResponders: true))
        return menu
    }

    private func formatMenu() -> NSMenu {
        let menu = NSMenu()
        let font = NSMenu()
        font.addItem(item(String(localized: "放大"), #selector(biggerText), "+"))
        // ⌘= too, as on keyboards where + needs shift.
        let alternate = item(String(localized: "放大"), #selector(biggerText), "=")
        alternate.isHidden = true
        alternate.allowsKeyEquivalentWhenHidden = true
        font.addItem(alternate)
        font.addItem(item(String(localized: "縮小"), #selector(smallerText), "-"))
        font.addItem(.separator())
        font.addItem(item(String(localized: "預設大小"), #selector(defaultText)))
        menu.addItem(submenu(String(localized: "字體"), font))
        menu.addItem(.separator())
        // ⇧⌘L, as in Notes.
        menu.addItem(item(String(localized: "清單項目"), #selector(NoteTextView.toggleChecklist(_:)), "l",
                          modifiers: [.command, .shift], toResponders: true))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        let hideAll = item(String(localized: "暫時隱藏全部便利貼"), #selector(toggleHideAll))
        shortcutItems.append((.hideAll, hideAll))
        menu.addItem(hideAll)
        menu.addItem(item(String(localized: "隱藏這個視窗的便利貼"), #selector(toggleWindowNotesHidden)))
        return menu
    }

    private func noteMenu() -> NSMenu {
        let menu = NSMenu()
        let colors = NSMenu()
        // ⌘1–⌘5, as in Stickies.
        for (index, color) in NoteColor.paperColors.enumerated() {
            let palette = NotePalette.of(color)
            let colorItem = item(palette.name, #selector(pickColor(_:)), "\(index + 1)")
            colorItem.tag = index
            colorItem.image = palette.swatch(diameter: 12, selected: false)
            colors.addItem(colorItem)
        }
        let colorItem = submenu(String(localized: "顏色"), colors)
        colorItem.identifier = Self.colorsID
        menu.addItem(colorItem)
        // Filled in each time it opens, with where the note can be stuck now.
        let scopeMenu = NSMenu()
        scopeMenu.identifier = Self.scopeMenuID
        scopeMenu.delegate = self
        let scope = submenu(String(localized: "貼在"), scopeMenu)
        scope.identifier = Self.scopeID
        menu.addItem(scope)
        // ⌘M, a note's "minimize"; ahead of the 視窗 menu's, so it wins while a note is in front.
        menu.addItem(item(String(localized: "收合"), #selector(toggleCollapsed), "m"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "轉成 AI 便利貼"), #selector(makeAI)))
        menu.addItem(item(String(localized: "轉成一般便利貼"), #selector(makeOrdinary)))
        menu.addItem(item(String(localized: "立即更新摘要"), #selector(refreshAI), "r"))
        menu.addItem(.separator())
        // ⌘⌫, as moving to the trash is in Finder.
        menu.addItem(item(String(localized: "刪除便利貼"), #selector(deleteNote), "\u{8}"))
        menu.addItem(item(String(localized: "刪除這個視窗的所有便利貼…"), #selector(deleteWindowNotes)))
        return menu
    }

    /// The standard window commands; macOS lists Hintlet's open windows under them (notes aren't listed).
    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m", toResponders: true))
        menu.addItem(item(String(localized: "縮放"), #selector(NSWindow.performZoom(_:)), toResponders: true))
        menu.addItem(.separator())
        let list = item(String(localized: "所有便利貼"), #selector(showList))
        shortcutItems.append((.showList, list))
        menu.addItem(list)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "將全部移至最前"), #selector(NSApplication.arrangeInFront(_:)), toResponders: true))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Hintlet 使用說明"), #selector(showHelp)))
        return menu
    }

    private static let colorsID = NSUserInterfaceItemIdentifier("colors")
    private static let scopeMenuID = NSUserInterfaceItemIdentifier("scopeMenu")

    /// The 便利貼 menu's items, made afresh, for a note's right-click menu (Hintlet shows no menu bar of its
    /// own, so this is where they are).
    func noteMenuItems() -> [NSMenuItem] {
        let menu = noteMenu()
        let items = menu.items
        menu.removeAllItems()
        return items
    }
    private static let scopeID = NSUserInterfaceItemIdentifier("scope")

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command, toResponders: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        // Editing and the app's own commands go to whatever has the keyboard; the rest come here.
        item.target = toResponders ? nil : self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Keeping items current

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == Self.scopeMenuID else { return }
        menu.removeAllItems()
        guard let note = overlay.currentNote else { return }
        for option in engine.scopeOptions(for: note.id) {
            let (symbol, text) = option.label.display
            let item = NSMenuItem(title: text, action: #selector(pickScope(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.state = option.isCurrent ? .on : .off
            item.representedObject = ScopeBox(option.scope)
            menu.addItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let note = overlay.currentNote
        switch item.action {
        case #selector(pickColor(_:)):
            item.state = note.map { NoteColor.paperColors[item.tag] == $0.color } == true ? .on : .off
            return note != nil && note?.ai == nil
        case #selector(toggleCollapsed):
            item.title = note?.isCollapsed == true ? String(localized: "展開") : String(localized: "收合")
            return note != nil
        case #selector(deleteNote):
            return note != nil
        case #selector(makeAI):
            item.isHidden = note?.ai != nil
            return note?.canBecomeAI == true
        case #selector(makeOrdinary):
            item.isHidden = note?.ai == nil
            return note?.ai != nil
        case #selector(refreshAI):
            item.isHidden = note?.ai == nil
            return note?.ai != nil && !engine.aiConversationKinds.isEmpty
        case #selector(toggleHideAll):
            item.title = actions.isHidingAll() ? String(localized: "顯示全部便利貼") : String(localized: "暫時隱藏全部便利貼")
            return true
        case #selector(toggleWindowNotesHidden):
            let hidden = engine.hidesFocusedWindowNotes
            item.title = hidden ? String(localized: "顯示這個視窗的便利貼") : String(localized: "隱藏這個視窗的便利貼")
            return !engine.notesOnFocusedWindow.isEmpty
        case #selector(deleteWindowNotes):
            return !engine.notesOnFocusedWindow.isEmpty
        case #selector(closeWindow):
            return NSApp.keyWindow.map { !($0 is NotePanel) && $0.styleMask.contains(.closable) } ?? false
        default:
            break
        }
        if item.identifier == Self.colorsID { return note != nil && note?.ai == nil }
        if item.identifier == Self.scopeID { return note != nil && note?.ai == nil }
        return true
    }

    // MARK: Actions

    @objc private func about() {
        AppPresence.comeForward()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings() { actions.showSettings() }
    @objc private func toggleHideAll() { actions.toggleHideAll() }
    @objc private func newNote() { actions.newNote() }
    @objc private func exportNotes() { actions.exportNotes() }
    @objc private func importBackup() { actions.importBackup() }
    @objc private func showList() { actions.showList() }
    @objc private func biggerText() { actions.changeTextSize(1) }
    @objc private func smallerText() { actions.changeTextSize(-1) }
    @objc private func defaultText() { actions.changeTextSize(nil) }
    @objc private func toggleWindowNotesHidden() { actions.toggleWindowNotesHidden() }
    @objc private func deleteWindowNotes() { actions.deleteWindowNotes() }

    @objc private func pickColor(_ sender: NSMenuItem) {
        overlay.setColorOfCurrentNote(NoteColor.paperColors[sender.tag])
    }

    @objc private func pickScope(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ScopeBox else { return }
        overlay.setScopeOfCurrentNote(box.scope)
    }

    @objc private func toggleCollapsed() { overlay.toggleCurrentNoteCollapsed() }
    @objc private func deleteNote() { overlay.deleteCurrentNote() }
    @objc private func makeAI() { overlay.makeCurrentNoteAI() }
    @objc private func makeOrdinary() { overlay.makeCurrentNoteOrdinary() }
    @objc private func refreshAI() { overlay.refreshCurrentAINote() }

    @objc private func closeWindow() {
        guard let window = NSApp.keyWindow, !(window is NotePanel) else { return }
        window.performClose(nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Hintlet 使用說明")
        alert.informativeText = String(localized: """
        • 新增便利貼：在任何 App 按全域快捷鍵，便利貼會貼在你正在看的視窗、網頁、資料夾或 Claude 對話上。
        • 點一下便利貼開始輸入，選單列會換成 Hintlet 的選單；按 Esc 回到原本的 App。
        • 便利貼上方的動態島：按一下收合，按住或按右鍵可換顏色、改貼在哪裡、刪除。
        • 切到別的視窗時，便利貼會自動隱藏；回來時再出現。
        • 所有便利貼與垃圾桶都在「視窗 › 所有便利貼」。
        """)
        alert.addButton(withTitle: String(localized: "好"))
        AppPresence.comeForward()
        alert.runModal()
    }
}

/// A scope carried on a menu item.
private final class ScopeBox: NSObject {
    let scope: BindingScope
    init(_ scope: BindingScope) { self.scope = scope }
}
