import AppKit
import HintletCore

import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // Notes don't go full screen: AppKit shouldn't add "進入全螢幕" to the 顯示方式 menu.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let store = NoteStore(directory: AppDelegate.notesDirectory)
    private let saved = AppDelegate.loadSavedNotes()
    private lazy var engine = NoteEngine(screens: Self.currentScreens(), document: saved.document)
    private lazy var autosave = Autosave(store: store, engine: engine, isEnabled: saved.canSave)
    private lazy var overlay = OverlayController(
        engine: engine,
        onFinishEditing: { [weak self] in self?.returnToPreviousApp() },
        onNotesChanged: { [weak self] in
            self?.autosave.schedule()
            self?.dismissHintIfItsNoteIsGone()
        }
    )
    /// The app the user was working in before a new note took keyboard focus.
    private var previousApp: NSRunningApplication?
    private var statusItem: NSStatusItem?
    private let hotKeys = HotKeys()
    private var newNoteItem: NSMenuItem?
    private var listItem: NSMenuItem?
    private var hideAllItem: NSMenuItem?
    private lazy var noteList = NoteListWindowController(engine: engine, actions: NoteListActions(
        change: { [unowned self] body in
            body(engine)
            overlay.render()
            dismissHintIfItsNoteIsGone()
            autosave.schedule()
        },
        sessionInfo: { [unowned self] ref in windowContext.claudePages.sessionInfo(for: ref) }
    ))
    private lazy var settingsWindow = SettingsWindowController { [unowned self] in settingsPanes }
    private lazy var mainMenu = MainMenu(engine: engine, overlay: overlay, actions: MainMenu.Actions(
        showSettings: { [unowned self] in showSettings() },
        newNote: { [unowned self] in createNote() },
        exportNotes: { [unowned self] in _ = exportNotes() },
        importBackup: { [unowned self] in
            if let result = importBackup() { tell(result) }
        },
        showList: { [unowned self] in noteList.show() },
        toggleHideAll: { [unowned self] in toggleHideAll() },
        isHidingAll: { [unowned self] in engine.hidesAll },
        changeTextSize: { [unowned self] step in
            var settings = noteSettings
            settings.textSize = step.map { settings.textSize + $0 } ?? NoteSettings.defaultTextSize
            setNoteSettings(settings)
        },
        toggleWindowNotesHidden: { [unowned self] in toggleWindowNotesHidden() },
        deleteWindowNotes: { [unowned self] in deleteWindowNotes() },
        showShortcut: { [unowned self] action, item in hotKeys.showShortcut(of: action, in: item) }
    ))
    private static let showsMenuBarIconKey = "showsMenuBarIcon"
    private let windowContext = WindowContextProvider()
    private let caretWatcher = CaretWatcher()
    private let optionPeek = OptionPeek()
    private let accessibility = AccessibilityPermission()
    private let hint = HintPanel()
    /// Cowork and Code sessions deleted in Claude take their notes to the trash.
    private let deletedSessions = SessionDeletionDetector(files: ClaudePages.sessionFolder)
    private var replyCheckTimer: Timer?
    #if DEBUG
    private var previewSample: NotePanel?
    private var previewMarker: NSWindow?
    #endif
    private var housekeepingTimer: Timer?
    /// Writes AI notes' summaries; nil while no backend can, which hides AI notes.
    private var summaries: SummaryUpdater?
    /// Apple's on-device model, if this Mac has it (checked once at launch).
    private let onDeviceSummaries = AISummaries.onDeviceService()
    /// The user's API keys, in the Keychain.
    private let claudeKeys = KeychainAPIKeyStore.claude()
    private let openAIKeys = KeychainAPIKeyStore.openAI()
    private lazy var claudeAPISummaries: any SummaryService = PromptedSummaryService(model: ClaudeAPISummaryModel(keys: claudeKeys))
    private lazy var openAISummaries: any SummaryService = PromptedSummaryService(model: OpenAISummaryModel(keys: openAIKeys))
    private var aiSettings = AISettings.load(from: .standard)
    private var noteSettings = NoteSettings.load(from: .standard)
    /// Chat conversations with an AI note, read from their pages; no other Chat is ever read.
    private lazy var chatReadings = ChatReadings(
        isTurnedOn: { @MainActor [unowned self] ref in engine.hasAINote(on: ref) },
        readPage: { @MainActor [unowned self] ref in await windowContext.claudePages.chatPage(showing: ref) }
    )
    /// The Chat conversation the focused Claude window shows, if any.
    private var shownChat: ConversationRef?
    private var chatCaptureTimer: Timer?
    /// Often enough that a deleted session's notes are gone within a minute; each check only lists a few folders.
    private static let housekeepingInterval: TimeInterval = 30

    private var isGivingWay = false

    /// Notes slide out of the way of the caret in the app in front, and holding ⌥ sees through them.
    /// Both need Accessibility, so they start once it is granted.
    private func startGivingWay() {
        guard !isGivingWay else { return }
        isGivingWay = true
        caretWatcher.onCaret = { [weak self] caret in
            guard let self else { return }
            // Typing with ⌥ held is for a character, not for peeking.
            if caret != nil { optionPeek.interrupt() }
            overlay.caretMoved(to: caret)
        }
        optionPeek.onPeek = { [weak self] peeking in self?.overlay.peekThrough(peeking) }
        caretWatcher.start()
        optionPeek.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenu.install()
        overlay.noteMenuItems = { [unowned self] in mainMenu.noteMenuItems() }
        BackgroundCursor.enable()
        applyNoteSettings()
        // Notes from the last run: floating ones show again, window ones wait to be found.
        overlay.render()
        installStatusItem()
        hotKeys.onChange = { [weak self] in
            self?.showShortcutsInMenu()
            self?.mainMenu.showShortcuts()
        }
        hotKeys.setHandler(for: .hideAll) { [weak self] in self?.toggleHideAll() }
        hotKeys.setHandler(for: .newNote) { [weak self] in self?.createNote() }
        hotKeys.setHandler(for: .showList) { [weak self] in self?.noteList.toggle() }
        autosave.onSchedule = { [weak self] in self?.noteList.reloadIfShown() }
        windowContext.onChange = { [weak self] observation in
            guard let self else { return }
            if case .window(let window) = observation, window.id != engine.focusedWindowID { hint.dismiss() }
            if observation == .unidentified { hint.dismiss() }
            engine.observe(observation)
            showing(observation)
            overlay.render()
            // Notes remember their window's latest title and place.
            autosave.schedule()
            // Switching away from a conversation brings its AI note up to date.
            updateSummaries()
        }
        startHousekeeping()
        setUpAINotes()
        windowContext.onMotionChange = { [weak self] moving in
            self?.overlay.setWindowInMotion(moving)
        }
        windowContext.onWindowsGone = { [weak self] ids in
            guard let self else { return }
            engine.windowsClosed(ids)
            overlay.windowsGone(ids)
            overlay.render()
            autosave.schedule()
        }
        // Notes left on a desktop that comes back into view get tidied up if they aren't wanted there; once the
        // app in front of that desktop is known, or a note that belongs there would flash off and on.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.overlay.render() }
        }
        if accessibility.isGranted {
            windowContext.start()
            startGivingWay()
        }
        if let problem = saved.problem { explainUnreadableNotes(problem) }
        #if DEBUG
        // `-previewHint draft|settings|fallback` shows a hint at the pointer, to look at its design.
        if let which = UserDefaults.standard.string(forKey: "previewHint") {
            let preview: HintPanel.Hint = switch which {
            case "settings": .claudeSettings
            case "fallback": .fellBackToWindow
            default: .draftConversation
            }
            hint.show(preview, at: NSEvent.mouseLocation) {}
        }
        // `-previewSettings YES` opens the settings at launch, to look at them.
        if UserDefaults.standard.bool(forKey: "previewSettings") { showSettings() }
        // `-previewAINote mist|sunset|glow` shows a sample AI note in that colour, to look at its design.
        if let color = UserDefaults.standard.string(forKey: "previewAINote").flatMap(NoteColor.init(rawValue:)) {
            let summary = AISummary(goal: "修好建置一直失敗的問題", point: "磁碟正常；I/O 錯誤是 Google Drive 在備份 ~/dev",
                                    next: UserDefaults.standard.string(forKey: "previewAINext") ?? "等你：在 Google Drive 排除 ~/dev",
                                    coverage: .complete, backend: .onDevice, updatedAt: .now)
            let sample = NotePanel(onTextChange: { _ in }, onMove: { _ in }, onFinishEditing: {})
            let ai = DisplayedAI(summary: summary,
                                 status: UserDefaults.standard.bool(forKey: "previewAIWriting") ? .updating : .idle)
            // At the default size, then fitted to its text as the engine would (no cap here).
            let frame = CGRect(x: 600, y: 500, width: NoteEngine.defaultNoteSize.width, height: NoteEngine.defaultNoteSize.height)
            let note = { (frame: CGRect, fits: Bool) in
                DisplayedNote(id: UUID(), frame: frame, text: "", scopeLabel: .conversation(title: "登入重構"), color: color,
                              ai: ai, fitsTextHeight: fits)
            }
            sample.onFitHeight = { [weak sample] height in
                let fitted = max(height, NoteEngine.minimumNoteSize.height)
                sample?.update(note(CGRect(x: frame.minX, y: frame.maxY - fitted, width: frame.width, height: fitted), false))
            }
            sample.update(note(frame, true))
            sample.reveal()
            if UserDefaults.standard.bool(forKey: "previewIsland") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sample.debugOpenIsland() }
            }
            previewSample = sample
        }
        // `-previewConvert YES`: a sample yellow note on a conversation becomes an AI note a second later.
        if UserDefaults.standard.bool(forKey: "previewConvert") {
            let sample = NotePanel(onTextChange: { _ in }, onMove: { _ in }, onFinishEditing: {})
            let frame = CGRect(x: 600, y: 450, width: 260, height: 170)
            sample.update(DisplayedNote(id: UUID(), frame: frame, text: "記得問部署時間",
                                        scopeLabel: .conversation(title: "登入重構"), canBecomeAI: true))
            sample.reveal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [engine] in
                sample.update(DisplayedNote(id: UUID(), frame: frame, text: "", scopeLabel: .conversation(title: "登入重構"),
                                            color: engine.aiNoteColor, ai: DisplayedAI(summary: nil, status: .updating)))
            }
            previewSample = sample
        }
        // `-previewIsland YES` shows a sample note on a conversation with its island open.
        if UserDefaults.standard.bool(forKey: "previewIsland"), previewSample == nil {
            let sample = NotePanel(onTextChange: { _ in }, onMove: { _ in }, onFinishEditing: {})
            // `-previewIslandOnWindow YES`: on a window instead, where it can't become an AI note.
            let onWindow = UserDefaults.standard.bool(forKey: "previewIslandOnWindow")
            sample.update(DisplayedNote(id: UUID(), frame: CGRect(x: 600, y: 450, width: 260, height: 170), text: "記得問部署時間",
                                        scopeLabel: onWindow ? .window(appName: "Safari", title: "文件") : .conversation(title: "登入重構"),
                                        canBecomeAI: !onWindow))
            sample.reveal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sample.debugOpenIsland() }
            previewSample = sample
        }
        // `-previewGiveWay fade|peek`: a sample note fades for a pretend caret (drawn in red), or is peeked through as
        // with ⌥ held.
        if let how = UserDefaults.standard.string(forKey: "previewGiveWay") {
            let sample = NotePanel(onTextChange: { _ in }, onMove: { _ in }, onFinishEditing: {})
            let frame = CGRect(x: 600, y: 450, width: 260, height: 170)
            sample.update(DisplayedNote(id: UUID(), frame: frame, text: "記得問部署時間", scopeLabel: .window(appName: "Safari", title: "文件")))
            sample.reveal()
            let caret = CGRect(x: frame.minX + 60, y: frame.minY + 20, width: 2, height: 18)
            let marker = NSWindow(contentRect: caret, styleMask: .borderless, backing: .buffered, defer: false)
            marker.backgroundColor = .systemRed
            marker.level = .statusBar
            marker.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if how == "peek" {
                    sample.peekThrough(true)
                } else {
                    sample.giveWay(GivingWay.fades(frame, forCaret: caret))
                }
            }
            previewSample = sample
            previewMarker = marker
        }
        // `-previewList YES` opens the list of notes at launch.
        if UserDefaults.standard.bool(forKey: "previewList") { noteList.show() }
        #endif
    }

    /// AI notes are offered while a backend can write them: the on-device model, or one that uploads once
    /// the user chose it in the settings.
    private func setUpAINotes() {
        overlay.onSummariesRequested = { [weak self] in self?.updateSummaries() }
        applyAISettings()
        // Each time Claude finishes a reply, its conversation's AI note catches up.
        replyCheckTimer = Self.repeating(every: AISummaries.replyCheckInterval, tolerance: 1 / 4) { [weak self] in
            guard let self, summaries != nil else { return }
            engine.checkForNewReplies()
            updateSummaries()
        }
    }

    /// Puts the AI settings into effect: the colour at once, and the backend for every summary from now on
    /// (including the automatic ones when switching away from a conversation).
    private func applyAISettings() {
        engine.aiNoteColor = aiSettings.noteColor
        let service: (any SummaryService)? = switch aiSettings.backend {
        case .claudeAPI: claudeAPISummaries
        case .openAIAPI: openAISummaries
        case .claudeAccount: AISummaries.accountService(.claudeCode, at: AISummaries.locate(.claudeCode, chosen: aiSettings.claudePath))
        case .codexAccount: AISummaries.accountService(.codex, at: AISummaries.locate(.codex, chosen: aiSettings.codexPath))
        default: onDeviceSummaries
        }
        if let service {
            if let summaries {
                summaries.service = service
            } else {
                let updater = SummaryUpdater(engine: engine, service: service, content: conversationContent)
                updater.onChange = { [weak self] in
                    self?.overlay.render()
                    self?.autosave.schedule()
                }
                summaries = updater
            }
            engine.aiConversationKinds = AISummaries.conversationKinds
        } else {
            NSLog("Hintlet：這台 Mac 沒有可用的裝置端模型，AI 便利貼不提供（可在設定中改用其他後端）")
            summaries = nil
            engine.aiConversationKinds = []
        }
        overlay.render()
        noteList.reloadIfShown()
    }

    /// New notes' size and colour from now on; the text size on every note at once.
    private func applyNoteSettings() {
        engine.newNoteSize = noteSettings.noteSize
        engine.newNoteColor = noteSettings.noteColor
        guard NoteTypography.textSize != noteSettings.textSize else { return }
        NoteTypography.textSize = noteSettings.textSize
        overlay.textSizeChanged()
    }

    private func setNoteSettings(_ settings: NoteSettings) {
        noteSettings = settings
        settings.save(to: .standard)
        applyNoteSettings()
    }

    private func setAISettings(_ settings: AISettings) {
        aiSettings = settings
        settings.save(to: .standard)
        applyAISettings()
    }

    /// Where an AI note's conversation is read from: Code and Cowork from Claude's local transcripts, Chat
    /// from its page (only what it has loaded).
    private var conversationContent: @Sendable (ConversationRef) async throws -> ConversationContent {
        { [chatReadings] ref in
            if ref.kind == .chat { return try await chatReadings.content(of: ref) }
            return try await AISummaries.content(of: ref)
        }
    }

    /// Keeps track of the Chat conversation in front, and reads it now and then while it has an AI note:
    /// once the user switches to another conversation its page is gone, and its note is brought up to
    /// date from the last read.
    private func showing(_ observation: ContextObservation) {
        if case .window(let window) = observation, case .conversation(let ref, _) = window.claudePage, ref.kind == .chat {
            shownChat = ref
        } else {
            shownChat = nil
        }
        captureShownChat()
        guard chatCaptureTimer == nil else { return }
        chatCaptureTimer = Self.repeating(every: AISummaries.chatCaptureInterval, tolerance: 1 / 4) { [weak self] in
            self?.captureShownChat()
        }
    }

    private func captureShownChat() {
        guard summaries != nil, let ref = shownChat, engine.hasAINote(on: ref) else { return }
        Task { [chatReadings] in await chatReadings.capture(ref) }
    }

    private func updateSummaries() {
        guard let summaries else {
            // Nothing can write them here; the requests just go.
            _ = engine.takeSummaryRequests()
            return
        }
        Task { await summaries.run() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autosave.saveNow()
    }

    /// Now and then: notes of deleted Cowork and Code sessions go to the trash (Chat can't be told, so its
    /// notes stay), and notes 30 days in the trash are gone for good.
    private func startHousekeeping() {
        housekeepingTimer = Self.repeating(every: Self.housekeepingInterval, tolerance: 1 / 3) { [weak self] in
            self?.tidyUp()
        }
        tidyUp()
    }

    /// A timer on the main run loop (also while a menu is open or a window is dragged) that runs `action`
    /// every `interval`, give or take `tolerance` of it.
    private static func repeating(every interval: TimeInterval, tolerance: Double,
                                  _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = interval * tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func tidyUp() {
        let before = engine.document
        let sessions = engine.sessionsToWatch
        if !sessions.isEmpty {
            let deleted = deletedSessions.deletedSessions(among: sessions)
            if !deleted.isEmpty {
                NSLog("Hintlet：\(deleted.count) 個 Claude session 已刪除，它們的便利貼移到垃圾桶")
                engine.sessionsDeleted(deleted)
            }
        }
        engine.purgeExpiredTrash()
        guard engine.document != before else { return }
        overlay.render()
        dismissHintIfItsNoteIsGone()
        autosave.schedule()
    }

    private static var notesDirectory: URL {
        #if DEBUG
        // `-notesDirectory <path>`: a preview run beside the real app keeps its notes elsewhere.
        if let path = UserDefaults.standard.string(forKey: "notesDirectory") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Hintlet", isDirectory: true)
    }

    private enum LoadProblem {
        /// Moved out of the way; saving starts afresh.
        case setAside(URL)
        /// Couldn't even be moved: left in place, and nothing is saved this run.
        case leftInPlace(URL)
    }

    private struct SavedNotes {
        var document: NotesDocument?
        var problem: LoadProblem?
        var canSave: Bool {
            if case .leftInPlace = problem { false } else { true }
        }
    }

    private static func loadSavedNotes() -> SavedNotes {
        let store = NoteStore(directory: notesDirectory)
        do {
            return SavedNotes(document: try store.load())
        } catch {
            // Never save over notes we couldn't read (e.g. written by a newer Hintlet): keep them aside.
            NSLog("Hintlet：無法讀取便利貼檔案（\(error)）")
            do {
                return SavedNotes(problem: .setAside(try store.setAsideUnreadableFile()))
            } catch {
                NSLog("Hintlet：無法移開讀不懂的便利貼檔案（\(error)），這次不會儲存")
                return SavedNotes(problem: .leftInPlace(store.fileURL))
            }
        }
    }

    private func explainUnreadableNotes(_ problem: LoadProblem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "無法讀取先前的便利貼")
        let url: URL
        switch problem {
        case .setAside(let keptAt):
            url = keptAt
            alert.informativeText = String(localized: """
            便利貼檔案可能來自較新版本的 Hintlet，或已損壞。原檔沒有刪除，已保留在：

            \(keptAt.path)

            「Backups」資料夾裡也有較早的備份。
            """)
        case .leftInPlace(let file):
            url = file
            alert.informativeText = String(localized: """
            便利貼檔案可能來自較新版本的 Hintlet，或已損壞，而且無法移開。為了不覆蓋它，這次執行期間不會儲存任何便利貼。

            \(file.path)
            """)
        }
        alert.addButton(withTitle: String(localized: "在 Finder 中顯示"))
        alert.addButton(withTitle: String(localized: "好"))
        AppPresence.comeForward()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = HintletGlyph.template(accessibilityDescription: String(localized: "Hintlet"))

        let menu = NSMenu()
        let newNote = NSMenuItem(title: String(localized: "新增便利貼"), action: #selector(createNoteFromMenu), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)
        newNoteItem = newNote
        let list = NSMenuItem(title: String(localized: "所有便利貼…"), action: #selector(showList), keyEquivalent: "")
        list.target = self
        menu.addItem(list)
        listItem = list
        menu.addItem(.separator())
        let hideAll = NSMenuItem(title: String(localized: "暫時隱藏全部"), action: #selector(toggleHideAll), keyEquivalent: "")
        hideAll.target = self
        menu.addItem(hideAll)
        hideAllItem = hideAll
        let claude = NSMenuItem(title: String(localized: "認得 Claude 的對話"), action: #selector(toggleClaudeConversations(_:)), keyEquivalent: "")
        claude.target = self
        menu.addItem(claude)
        menu.delegate = self
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "設定…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: String(localized: "結束 Hintlet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.isVisible = UserDefaults.standard.object(forKey: Self.showsMenuBarIconKey) as? Bool ?? true
        statusItem = item
        showShortcutsInMenu()
    }

    /// Opening Hintlet again (from Finder or Spotlight, the way back when its menu bar icon is hidden) shows
    /// every note.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        noteList.show()
        return false
    }

    private func toggleWindowNotesHidden() {
        engine.setFocusedWindowNotesHidden(!engine.hidesFocusedWindowNotes)
        overlay.render()
        showHidingState()
        if engine.hidesFocusedWindowNotes { returnToPreviousApp() }
    }

    /// Every note on the window the user came from goes to the trash, after asking.
    private func deleteWindowNotes() {
        let ids = engine.notesOnFocusedWindow
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "刪除這個視窗的 \(ids.count) 張便利貼？")
        alert.informativeText = String(localized: "它們會移到垃圾桶，30 天內可在「所有便利貼」中還原。")
        alert.addButton(withTitle: String(localized: "刪除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.deleteNotes(ids)
        overlay.render()
        autosave.schedule()
        returnToPreviousApp()
    }

    private func tell(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }

    private func setShowsMenuBarIcon(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.showsMenuBarIconKey)
        statusItem?.isVisible = on
    }

    private func showShortcutsInMenu() {
        if let newNoteItem { hotKeys.showShortcut(of: .newNote, in: newNoteItem) }
        if let listItem { hotKeys.showShortcut(of: .showList, in: listItem) }
        if let hideAllItem { hotKeys.showShortcut(of: .hideAll, in: hideAllItem) }
    }

    /// While everything is hidden the menu bar icon says so, so notes aren't thought lost.
    private func showHidingState() {
        let hidden = engine.hidesAll || engine.hidesSomeNotes
        statusItem?.button?.image = hidden
            ? NSImage(systemSymbolName: "eye.slash", accessibilityDescription: String(localized: "Hintlet（已隱藏全部）"))
            : HintletGlyph.template(accessibilityDescription: String(localized: "Hintlet"))
        statusItem?.button?.toolTip = hidden ? String(localized: "Hintlet：便利貼已暫時隱藏") : nil
    }

    @objc private func toggleHideAll() {
        engine.hidesAll.toggle()
        if engine.hidesAll { hint.dismiss() }
        overlay.render()
        showHidingState()
    }

    @objc private func showList() {
        noteList.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    /// The tabs of the settings window, in order.
    private var settingsPanes: [SettingsPane] {
        [
            SettingsPane(id: "general", title: String(localized: "一般"), symbol: "gearshape") {
                GeneralPane(showsMenuBarIcon: { [unowned self] in statusItem?.isVisible ?? true },
                            setShowsMenuBarIcon: { [unowned self] in setShowsMenuBarIcon($0) })
            },
            SettingsPane(id: "notes", title: String(localized: "便利貼"), symbol: "note.text") {
                NotesPane(settings: { [unowned self] in noteSettings },
                          apply: { [unowned self] in setNoteSettings($0) },
                          aiColor: { [unowned self] in aiSettings.noteColor },
                          setAIColor: { [unowned self] color in
                              var settings = aiSettings
                              settings.noteColor = color
                              setAISettings(settings)
                          },
                          offersAINotes: !engine.aiConversationKinds.isEmpty)
            },
            SettingsPane(id: "shortcuts", title: String(localized: "快捷鍵"), symbol: "keyboard") {
                ShortcutsPane(hotKeys: hotKeys)
            },
            SettingsPane(id: "ai", title: String(localized: "AI"), symbol: "sparkles") {
                AIPane(onDeviceAvailable: onDeviceSummaries != nil,
                       settings: { [unowned self] in aiSettings },
                       apply: { [unowned self] chosen in
                           // The colour is the Notes tab's.
                           var settings = chosen
                           settings.noteColor = aiSettings.noteColor
                           setAISettings(settings)
                       },
                       locate: { AISummaries.locate($0, chosen: $1) },
                       claudeKey: APIKeyField.Store(keys: claudeKeys),
                       openAIKey: APIKeyField.Store(keys: openAIKeys))
            },
            SettingsPane(id: "backup", title: String(localized: "備份"), symbol: "externaldrive.badge.timemachine") {
                BackupPane(export: { [unowned self] in exportNotes() }, importBackup: { [unowned self] in importBackup() })
            },
            SettingsPane(id: "permissions", title: String(localized: "權限"), symbol: "lock.shield") {
                PermissionsPane(accessibility: accessibility,
                                onAccessibilityGranted: { [weak self] in
                    self?.windowContext.start()
                    self?.startGivingWay()
                },
                                claudeConsent: { [unowned self] in windowContext.claudePages.consent },
                                setClaudeConsent: { [unowned self] on in setClaudeConsent(on) })
            },
        ]
    }

    private func exportNotes() -> String? {
        let panel = NSSavePanel()
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "Hintlet 備份 \(date).json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let document = engine.document
        do {
            try NoteStore.export(document, to: url)
            return String(localized: "已匯出 \(document.noteCount) 張便利貼到「\(url.lastPathComponent)」。")
        } catch {
            NSLog("Hintlet：匯出失敗（\(error)）")
            return String(localized: "無法匯出：\(error.localizedDescription)")
        }
    }

    private func importBackup() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let document: NotesDocument
        do {
            document = try NoteStore.document(at: url)
        } catch NoteStore.LoadError.newerFormat {
            return String(localized: "這個備份來自較新版本的 Hintlet，請先更新 Hintlet 再匯入。")
        } catch {
            return String(localized: "這個檔案不是 Hintlet 的備份，或已損壞，沒有匯入任何東西。")
        }
        engine.updateScreens(Self.currentScreens())
        let summary = engine.importNotes(document)
        overlay.render()
        autosave.schedule()
        return String(localized: "已匯入：新增 \(summary.added) 張，更新 \(summary.updated) 張。")
    }

    /// Turning it on asks Claude for its full tree the next time it is in front; turning it off makes
    /// notes on Claude go to the window (Claude keeps its tree until it restarts).
    @objc private func toggleClaudeConversations(_ item: NSMenuItem) {
        setClaudeConsent(windowContext.claudePages.consent != true)
    }

    private func setClaudeConsent(_ on: Bool) {
        windowContext.claudePages.consent = on
        windowContext.enableClaude()
        windowContext.refresh()
    }

    @objc private func createNoteFromMenu() {
        createNote()
    }

    private func createNote() {
        // Captured before anything can take focus or move the pointer (e.g. the permission alert).
        let cursor = NSEvent.mouseLocation
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        hint.dismiss()
        guard accessibility.isGranted else {
            // Without Accessibility the note can only float; explain once, then carry on.
            let openedSettings = accessibility.requestIfNeeded { [weak self] in
                    self?.windowContext.start()
                    self?.startGivingWay()
                }
            placeNote(at: cursor, scope: .automatic, focus: !openedSettings)
            return
        }
        if frontmost?.bundleIdentifier == ClaudePages.bundleID {
            // The first note on Claude asks before turning on its full tree; then (or whenever Claude has
            // only just been asked for it) the note waits for the tree to fill in.
            if windowContext.claudePages.consent == nil { _ = windowContext.claudePages.askForConsent() }
            windowContext.enableClaude { [weak self] in
                // Unless the user has moved on to another app meanwhile.
                guard let self, NSWorkspace.shared.frontmostApplication.map(Self.isClaudeOrSelf) ?? false else { return }
                windowContext.refresh()
                createNoteOnCurrentContext(at: cursor)
            }
            return
        }
        windowContext.refresh(waitingForFolder: true)
        createNoteOnCurrentContext(at: cursor)
    }

    private static func isClaudeOrSelf(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == ClaudePages.bundleID || app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// A hint about a note that was deleted (or discarded) no longer points at anything.
    private func dismissHintIfItsNoteIsGone() {
        guard let note = hint.note, !engine.displayedNotes.contains(where: { $0.id == note }) else { return }
        hint.dismiss()
    }

    /// Places the note on what the user is looking at, or explains why it can't go there.
    private func createNoteOnCurrentContext(at cursor: CGPoint) {
        switch engine.creationBlock {
        case .draftConversation, .newBrowserTab:
            let window = engine.focusedWindowID
            hint.show(engine.creationBlock == .newBrowserTab ? .newBrowserTab : .draftConversation, at: cursor) { [weak self] in
                // Only on the window it was offered for.
                guard let self, engine.focusedWindowID == window else { return }
                placeNote(at: cursor, scope: .window, focus: true)
            }
        case .claudeSettings:
            hint.show(.claudeSettings, at: cursor)
        case nil:
            let fallsBack = engine.creationFallsBack
            let id = placeNote(at: cursor, scope: .automatic, focus: true)
            if fallsBack, let note = engine.displayedNotes.first(where: { $0.id == id }) {
                let fallback: HintPanel.Hint = if case .webPageFallback = note.scopeLabel { .browserFellBackToWindow } else { .fellBackToWindow }
                // Pointing at the note from below, so it doesn't cover what the user is about to type.
                hint.show(fallback, at: CGPoint(x: note.frame.midX, y: note.frame.minY), about: id)
            }
        }
    }

    @discardableResult
    private func placeNote(at cursor: CGPoint, scope: NoteScope, focus: Bool) -> NoteID {
        engine.updateScreens(Self.currentScreens())
        let id = engine.createNote(at: cursor, scope: scope)
        overlay.render()
        // A new note ends "hide all".
        showHidingState()
        autosave.schedule()
        guard focus else { return id }

        // A non-activating panel only receives typing after the user clicks it, so activate briefly
        // to let the user type right away; Esc hands focus back to the app they came from.
        AppPresence.comeForward()
        // Activation completes asynchronously and resets the key window, so place the caret afterwards.
        DispatchQueue.main.async { [weak self] in self?.overlay.focus(id) }
        return id
    }

    private static func currentScreens() -> [Screen] {
        NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    private func returnToPreviousApp() {
        guard NSApp.isActive, let app = previousApp, !app.isTerminated else { return }
        previousApp = nil
        app.activate()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleClaudeConversations(_:)) {
            item.state = windowContext.claudePages.consent == true ? .on : .off
        }
        for item in menu.items where item.action == #selector(toggleHideAll) {
            item.state = engine.hidesAll ? .on : .off
        }
    }
}
