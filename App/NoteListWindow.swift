import AppKit
import HintletCore
import SwiftUI

/// What the central list can do to notes. AppDelegate supplies these, so the list never touches the
/// overlay or saving itself.
@MainActor
struct NoteListActions {
    /// Makes a change to the notes, then shows and saves it.
    var change: (_ body: (NoteEngine) -> Void) -> Void
    /// A Cowork or Code session's current name and whether it is archived.
    var sessionInfo: (ConversationRef) -> ClaudeSessionInfo?
}

/// The central list (⌘⌥L): every note, searchable, grouped by app and context, with the notes waiting to be
/// found again and the trash. A plain window that brings Hintlet forward while it is open.
@MainActor
final class NoteListWindowController: NSObject, NSWindowDelegate {
    /// Spike 04: `claude://` opens a given conversation, so the list offers "前往".
    static let offersGoTo = true

    private let model: NoteListModel
    private var window: NSWindow?
    /// The app the user was in when the list opened; it comes back to the front when the list closes.
    private var previousApp: NSRunningApplication?

    init(engine: NoteEngine, actions: NoteListActions) {
        model = NoteListModel(engine: engine, actions: actions)
        super.init()
        model.onGoTo = { [weak self] ref in self?.goTo(ref) }
    }

    var isShown: Bool { window?.isVisible == true }

    /// Opens the list, or closes it if it is already in front (the shortcut toggles it).
    func toggle() {
        if let window, window.isKeyWindow, NSApp.isActive {
            window.close()
        } else {
            show()
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
        let window = self.window ?? makeWindow()
        self.window = window
        model.reload()
        AppPresence.comeForward()
        window.makeKeyAndOrderFront(nil)
        model.focusSearch()
    }

    /// The notes changed elsewhere (typing in a note, a session deleted, the focus moved on).
    func reloadIfShown() {
        guard isShown else { return }
        model.reload()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: NoteListView(model: model, close: { [weak self] in self?.window?.close() }))
        // The list's toolbar (search, its buttons) and title go to the window's, as in a SwiftUI app.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "所有便利貼")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        // Opens where the user is, also over a full-screen app, instead of taking them to another Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 980, height: 580))
        window.contentMinSize = NSSize(width: 760, height: 440)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NoteList3")
        window.delegate = self
        if !window.setFrameUsingName("NoteList3") { window.center() }
        return window
    }

    private func goTo(_ ref: ConversationRef) {
        // Claude comes to the front on its own; the list isn't needed in the way.
        previousApp = nil
        window?.close()
        guard let url = ref.deepLink else { return }
        NSWorkspace.shared.open(url)
    }

    func windowWillClose(_ notification: Notification) {
        model.query = ""
        guard let app = previousApp, !app.isTerminated else { return }
        previousApp = nil
        app.activate()
    }
}

@MainActor
final class NoteListModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    @Published private(set) var list = NoteList.empty
    /// What "重新綁定" binds to now, if anything.
    @Published private(set) var rebindContext: ScopeLabel?
    @Published var searchFocusRequest = 0
    var onGoTo: ((ConversationRef) -> Void)?

    private let engine: NoteEngine
    private let actions: NoteListActions

    init(engine: NoteEngine, actions: NoteListActions) {
        self.engine = engine
        self.actions = actions
    }

    func reload() {
        let fresh = engine.list(searching: query, sessions: actions.sessionInfo)
        if fresh != list { list = fresh }
        let context = engine.rebindContext
        if context != rebindContext { rebindContext = context }
    }

    func focusSearch() { searchFocusRequest += 1 }

    func canRebind(_ id: NoteID) -> Bool { engine.canRebindToCurrentContext(id) }

    func rebind(_ id: NoteID) { change { $0.rebindToCurrentContext(id) } }
    func makeFloating(_ ids: Set<NoteID>) { change { engine in ids.forEach(engine.makeFloating) } }
    func delete(_ ids: Set<NoteID>) { change { $0.deleteNotes(Array(ids)) } }
    /// Typing in the preview writes to the note itself.
    func edit(_ id: NoteID, to text: String) { change { $0.editText(of: id, to: text) } }
    func restore(_ ids: Set<NoteID>) { change { engine in ids.forEach(engine.restoreNote) } }

    func deleteForever(_ ids: Set<NoteID>) {
        guard !ids.isEmpty else { return }
        let message = ids.count == 1 ? String(localized: "要永久刪除這張便利貼嗎？") : String(localized: "要永久刪除這 \(ids.count) 張便利貼嗎？")
        guard confirm(message, button: String(localized: "永久刪除")) else { return }
        change { engine in ids.forEach(engine.deleteForever) }
    }

    func emptyTrash() {
        let count = engine.trashedNotes.count
        guard count > 0,
              confirm(String(localized: "要清空垃圾桶嗎？"), button: String(localized: "清空"),
                      detail: String(localized: "垃圾桶裡的 \(count) 張便利貼會永久刪除。")) else { return }
        change { $0.emptyTrash() }
    }

    func goTo(_ ref: ConversationRef) { onGoTo?(ref) }

    private func change(_ body: (NoteEngine) -> Void) {
        actions.change(body)
        reload()
    }

    /// Deleting for good can't be undone, so it asks first.
    private func confirm(_ message: String, button: String, detail: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? String(localized: "這個動作無法復原。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Views

/// What the sidebar shows, as in Notes: everything, each place notes are on, then the ones waiting to be
/// found again and the trash.
private enum ListPlace: Hashable {
    case all
    case app(ListedApp)
    case waiting
    case trash
}

private struct NoteListView: View {
    @ObservedObject var model: NoteListModel
    let close: () -> Void
    @State private var place: ListPlace? = .all
    /// ⌘-click adds or takes away one note, ⇧-click the ones in between, as in Finder.
    @State private var selection: Set<NoteID> = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            noteList
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 400)
        } detail: {
            if selection.count == 1, let id = selection.first, let note = note(id) {
                NoteDetail(note: note, group: group(of: id), model: model)
                    .id(id)
            } else if selection.count > 1 {
                VStack(spacing: 22) {
                    NoteStack(notes: notes.filter { selection.contains($0.id) })
                    Text(String(localized: "已選取 \(selection.count) 張便利貼"))
                        .font(.title3.weight(.semibold))
                    HStack {
                        BulkActions(ids: selection, inTrash: place == .trash, waiting: place == .waiting, model: model)
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup {
                        BulkActions(ids: selection, inTrash: place == .trash, waiting: place == .waiting, model: model)
                    }
                }
            } else {
                ContentUnavailableView(String(localized: "選一張便利貼"), systemImage: "note.text",
                                       description: Text(String(localized: "在這裡看它的全文、改它的字，或前往它所在的地方。")))
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: String(localized: "搜尋"))
        .frame(minWidth: 760, minHeight: 440)
        .onExitCommand(perform: close)
        .onChange(of: place) { selection = Set(notes.prefix(1).map(\.id)) }
        #if DEBUG
        // `-previewListSelect 4`: that many notes selected, to look at the stack.
        .onAppear {
            let count = UserDefaults.standard.integer(forKey: "previewListSelect")
            guard count > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selection = Set(notes.prefix(count).map(\.id)) }
        }
        #endif
        .onChange(of: model.list) {
            // A place that has emptied out goes back to everything; a note that went, to the first one left.
            if case .app(let app) = place, !apps.contains(where: { $0.app == app }) { place = .all }
            let shown = Set(notes.map(\.id))
            selection.formIntersection(shown)
            if selection.isEmpty { selection = Set(notes.prefix(1).map(\.id)) }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $place) {
            Section {
                SidebarRow(title: String(localized: "所有便利貼"), icon: .symbol("note.text"), count: allCount)
                    .tag(ListPlace.all)
            }
            if !apps.isEmpty {
                Section(String(localized: "位置")) {
                    ForEach(apps, id: \.app) { entry in
                        SidebarRow(title: Self.name(of: entry.app), icon: Self.icon(of: entry.app), count: entry.count)
                            .tag(ListPlace.app(entry.app))
                    }
                }
            }
            Section {
                SidebarRow(title: String(localized: "待找回"), icon: .symbol("questionmark.app.dashed"),
                           count: model.list.waiting.count)
                    .tag(ListPlace.waiting)
                SidebarRow(title: String(localized: "最近刪除"), icon: .symbol("trash"), count: model.list.trash.count)
                    .tag(ListPlace.trash)
            }
        }
        .listStyle(.sidebar)
    }

    private var allCount: Int { model.list.groups.reduce(0) { $0 + $1.notes.count } }

    /// The apps notes are on, in the order their most recent note puts them, each with how many.
    private var apps: [(app: ListedApp, count: Int)] {
        var apps: [(app: ListedApp, count: Int)] = []
        for group in model.list.groups {
            if let index = apps.firstIndex(where: { $0.app == group.app }) {
                apps[index].count += group.notes.count
            } else {
                apps.append((group.app, group.notes.count))
            }
        }
        return apps
    }

    // MARK: Notes

    /// The notes of the chosen place, newest first.
    private var notes: [ListedNote] {
        switch place ?? .all {
        case .all: model.list.groups.flatMap(\.notes).sorted { $0.updatedAt > $1.updatedAt }
        case .app(let app): model.list.groups.filter { $0.app == app }.flatMap(\.notes).sorted { $0.updatedAt > $1.updatedAt }
        case .waiting: model.list.waiting
        case .trash: model.list.trash
        }
    }

    private func note(_ id: NoteID) -> ListedNote? {
        model.list.groups.lazy.flatMap(\.notes).first { $0.id == id }
            ?? model.list.waiting.first { $0.id == id } ?? model.list.trash.first { $0.id == id }
    }

    private func group(of id: NoteID) -> NoteListGroup? {
        model.list.groups.first { $0.notes.contains { $0.id == id } }
    }

    @ViewBuilder private var noteList: some View {
        if notes.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(notes, id: \.id) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: NoteID.self) { ids in
                if ids.count == 1, let id = ids.first, let note = note(id) {
                    NoteActions(note: note, group: group(of: id), model: model)
                } else if !ids.isEmpty {
                    BulkActions(ids: ids, inTrash: place == .trash, waiting: place == .waiting, model: model)
                }
            }
            .onDeleteCommand {
                place == .trash ? model.deleteForever(selection) : model.delete(selection)
            }
            .navigationTitle(title)
            .navigationSubtitle(String(localized: "\(notes.count) 張便利貼"))
        }
    }

    private var title: String {
        switch place ?? .all {
        case .all: String(localized: "所有便利貼")
        case .app(let app): Self.name(of: app)
        case .waiting: String(localized: "待找回")
        case .trash: String(localized: "最近刪除")
        }
    }

    @ViewBuilder private var emptyState: some View {
        Group {
            if !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                switch place ?? .all {
                case .waiting:
                    ContentUnavailableView(String(localized: "沒有待找回的便利貼"), systemImage: "checkmark.circle",
                                           description: Text(String(localized: "視窗關閉或認不出來時，它的便利貼會在這裡等你重新綁定。")))
                case .trash:
                    ContentUnavailableView(String(localized: "沒有最近刪除的便利貼"), systemImage: "trash",
                                           description: Text(String(localized: "刪除的便利貼會在這裡保留 30 天。")))
                default:
                    ContentUnavailableView(String(localized: "還沒有便利貼"), systemImage: "note.text",
                                           description: Text(String(localized: "按 ⌥⌘N 在目前的工作內容上貼一張。")))
                }
            }
        }
        .navigationTitle(title)
    }

    static func name(of app: ListedApp) -> String {
        switch app {
        case .app(let name): name
        case .documents: String(localized: "資料夾與文件")
        case .webPages: String(localized: "網頁")
        case .claudeCodeTerminal: String(localized: "Claude Code（終端機）")
        case .floating: String(localized: "浮動")
        }
    }

    private static func icon(of app: ListedApp) -> SidebarIcon {
        switch app {
        case .app(let name):
            if let path = NSWorkspace.shared.fullPath(forApplication: name) { return .image(NSWorkspace.shared.icon(forFile: path)) }
            return .symbol("macwindow")
        case .documents: return .symbol("folder")
        case .webPages: return .symbol("globe")
        case .claudeCodeTerminal: return .symbol("terminal")
        case .floating: return .symbol("pin")
        }
    }
}

/// What can be done with a note where it is listed: on the preview's toolbar and in a row's context menu.
private struct NoteActions: View {
    let note: ListedNote
    let group: NoteListGroup?
    @ObservedObject var model: NoteListModel

    var body: some View {
        if note.deletedAt != nil {
            Button(String(localized: "復原"), systemImage: "arrow.uturn.backward") { model.restore([note.id]) }
            Button(String(localized: "永久刪除"), systemImage: "trash.slash", role: .destructive) { model.deleteForever([note.id]) }
        } else {
            if note.waitingReason != nil {
                Button(rebindTitle, systemImage: "link") { model.rebind(note.id) }
                    .disabled(!model.canRebind(note.id))
                Button(String(localized: "改為浮動"), systemImage: "pin") { model.makeFloating([note.id]) }
            } else if NoteListWindowController.offersGoTo, let ref = group?.conversation, ref.deepLink != nil {
                Button(String(localized: "前往對話"), systemImage: "arrow.up.forward.app") { model.goTo(ref) }
            }
            Button(String(localized: "刪除"), systemImage: "trash", role: .destructive) { model.delete([note.id]) }
        }
    }

    private var rebindTitle: String {
        guard let context = model.rebindContext else { return String(localized: "重新綁定") }
        return String(localized: "綁到「\(context.short)」")
    }
}

/// What can be done to several selected notes at once.
/// Several notes picked at once, shown the way Finder shows several files: a small stack of them, a little
/// fanned, the most recent on top, each on its own paper with its first lines.
private struct NoteStack: View {
    let notes: [ListedNote]
    private static let shown = 5
    /// How each card lies in the stack, from the top one down.
    private static let tilts: [Double] = [0, -5, 4, -8, 7]
    private static let shifts: [CGSize] = [.zero, CGSize(width: -14, height: 6), CGSize(width: 14, height: 4),
                                          CGSize(width: -22, height: 12), CGSize(width: 22, height: 10)]

    var body: some View {
        let top = Array(notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.shown))
        ZStack {
            ForEach(Array(top.enumerated().reversed()), id: \.element.id) { index, note in
                Card(note: note)
                    .rotationEffect(.degrees(Self.tilts[index]))
                    .offset(Self.shifts[index])
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(width: 260, height: 190)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: top.map(\.id))
        .accessibilityHidden(true)
    }

    private struct Card: View {
        let note: ListedNote

        var body: some View {
            let palette = NotePalette.of(note.color)
            let ink = Color(nsColor: palette.ink)
            let lines = (note.aiLines ?? note.text.split(whereSeparator: \.isNewline).map(String.init)).prefix(3)
            VStack(alignment: .leading, spacing: 5) {
                if let first = lines.first {
                    Text(first).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                ForEach(Array(lines.dropFirst()), id: \.self) { line in
                    Text(line).font(.system(size: 11)).lineLimit(1).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .padding(12)
            .frame(width: 170, height: 130, alignment: .topLeading)
            .background(paper(palette), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }

        private func paper(_ palette: NotePalette) -> LinearGradient {
            if let diagonal = palette.diagonal {
                return LinearGradient(colors: diagonal.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            return LinearGradient(colors: [Color(nsColor: palette.paperTop), Color(nsColor: palette.paperBottom)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct BulkActions: View {
    let ids: Set<NoteID>
    let inTrash: Bool
    let waiting: Bool
    @ObservedObject var model: NoteListModel

    var body: some View {
        if inTrash {
            Button(String(localized: "復原"), systemImage: "arrow.uturn.backward") { model.restore(ids) }
            Button(String(localized: "永久刪除"), systemImage: "trash.slash", role: .destructive) { model.deleteForever(ids) }
        } else {
            if waiting {
                Button(String(localized: "改為浮動"), systemImage: "pin") { model.makeFloating(ids) }
            }
            Button(String(localized: "刪除"), systemImage: "trash", role: .destructive) { model.delete(ids) }
        }
    }
}

/// The selected note in full, on its own paper: where it is, when it changed, and its text, which can be
/// edited here (an AI note's lines can't).
private struct NoteDetail: View {
    let note: ListedNote
    let group: NoteListGroup?
    @ObservedObject var model: NoteListModel
    @State private var text = ""
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    let (symbol, context) = note.context.display
                    Label(context, systemImage: symbol)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(note.updatedAt, format: .dateTime.year().month().day().hour().minute())
                        if group?.isArchived == true { Text("·"); Text(String(localized: "已封存")) }
                        if let detail { Text("·"); Text(detail) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                paper
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                NoteActions(note: note, group: group, model: model)
            }
        }
        .onAppear { text = note.text }
    }

    private var palette: NotePalette { NotePalette.of(note.color) }

    @ViewBuilder private var paper: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if let lines = note.aiLines {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text(String(localized: "還沒有摘要")).foregroundStyle(Color(nsColor: palette.ink).opacity(0.6))
                    }
                    if let goal = lines.first {
                        Text(goal)
                            .font(.system(size: NoteTypography.textSize + 4, weight: .semibold))
                            .foregroundStyle(Color(nsColor: palette.ink))
                    }
                    if lines.count > 1 {
                        Text(lines[1]).foregroundStyle(Color(nsColor: palette.ink))
                    }
                    if lines.count > 2 {
                        let (state, rest) = SummaryState.split(lines[2])
                        if let look = AINoteText.look(of: state) {
                            (Text(Image(systemName: look.symbol)) + Text(" " + look.name + "  ").fontWeight(.semibold))
                                .foregroundStyle(Color(nsColor: palette.ink).opacity(0.6))
                            + Text(rest).foregroundStyle(Color(nsColor: palette.ink))
                        } else {
                            Text(lines[2]).foregroundStyle(Color(nsColor: palette.ink).opacity(0.6))
                        }
                    }
                }
                .font(.system(size: NoteTypography.textSize + 1))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else {
                TextEditor(text: Binding(get: { text }, set: { new in
                    text = new
                    model.edit(note.id, to: new)
                }))
                .font(.system(size: NoteTypography.textSize + 1))
                .foregroundStyle(Color(nsColor: palette.ink))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .disabled(note.deletedAt != nil)
                .frame(minHeight: 180, alignment: .topLeading)
                .padding(12)
            }
        }
        .background {
            if palette.usesMaterial {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(LinearGradient(colors: [Color(nsColor: palette.paperTop), Color(nsColor: palette.paperBottom)],
                                          startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
        // Paper keeps its own light or dark; glass follows the system's.
        .environment(\.colorScheme, palette.usesMaterial ? systemScheme : palette.isDark ? .dark : .light)
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    private var detail: String? {
        if let deletedAt = note.deletedAt {
            let left = deletedAt.addingTimeInterval(NoteEngine.trashRetention).timeIntervalSinceNow
            let days = max(1, Int((left / 86_400).rounded(.up)))
            return String(localized: "\(days) 天後永久刪除")
        }
        switch note.waitingReason {
        case .relaunched: return String(localized: "App 重新開啟後，認不出原本的視窗")
        case .windowClosed: return String(localized: "原本的視窗已關閉")
        case .documentMissing: return String(localized: "找不到原本的資料夾或檔案")
        case nil: return nil
        }
    }
}

private enum SidebarIcon {
    case symbol(String)
    case image(NSImage)
}

private struct SidebarRow: View {
    let title: String
    let icon: SidebarIcon
    let count: Int

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            switch icon {
            case .symbol(let name): Image(systemName: name)
            case .image(let image): Image(nsImage: image).resizable().frame(width: 16, height: 16)
            }
        }
        .badge(count)
    }
}

/// One note, as Notes lists them: its first line as the title, then when it changed and how it goes on,
/// then where it is; a strip of its colour along the edge.
private struct NoteRow: View {
    let note: ListedNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stripe)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.aiLines != nil {
                        Image(systemName: "sparkles").foregroundStyle(.secondary).font(.caption)
                    }
                    Text(heading)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    Text(note.updatedAt, format: Self.dateStyle(note.updatedAt))
                        .foregroundStyle(.primary.opacity(0.75))
                    Text(rest)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                Label(note.context.short, systemImage: note.context.display.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var stripe: AnyShapeStyle {
        let palette = NotePalette.of(note.color)
        return palette.usesMaterial ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color(nsColor: palette.paperBottom))
    }

    private var lines: [String] {
        let text = note.aiLines?.joined(separator: "\n") ?? note.text
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var heading: String {
        if let first = lines.first { return first }
        return note.aiLines != nil ? String(localized: "AI 便利貼") : String(localized: "（空白）")
    }

    private var rest: String {
        lines.count > 1 ? lines.dropFirst().joined(separator: " ") : String(localized: "沒有其他內容")
    }

    /// The time today, the weekday this week, or else the date, as Notes shows it.
    private static func dateStyle(_ date: Date) -> Date.FormatStyle {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .dateTime.hour().minute() }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return .dateTime.weekday(.wide) }
        return .dateTime.year().month(.defaultDigits).day()
    }
}
