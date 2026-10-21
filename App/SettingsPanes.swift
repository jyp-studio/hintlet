import AppKit
import ServiceManagement
import HintletCore
import SwiftUI

// MARK: - General

/// Starting with the Mac, and whether Hintlet shows in the menu bar.
struct GeneralPane: View {
    let showsMenuBarIcon: () -> Bool
    let setShowsMenuBarIcon: (Bool) -> Void
    @State private var opensAtLogin = false
    @State private var needsApproval = false
    @State private var loginProblem: String?
    @State private var showsIcon = true

    var body: some View {
        SettingsForm {
            SettingsSection(String(localized: "啟動")) {
                Toggle(String(localized: "登入時開啟 Hintlet"), isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                if needsApproval {
                    LabeledContent {
                        Button(String(localized: "打開登入項目設定")) { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text(String(localized: "要在「系統設定 › 一般 › 登入項目」允許 Hintlet。"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if let loginProblem {
                    Text(loginProblem).font(.callout).foregroundStyle(.orange)
                }
            }
            SettingsSection(String(localized: "選單列"),
                            footnote: String(localized: "不顯示圖示時，仍可用全域快捷鍵新增便利貼；在 Finder 或 Spotlight 再次打開 Hintlet，會打開所有便利貼。")) {
                Toggle(String(localized: "在選單列顯示 Hintlet 圖示"), isOn: Binding(get: { showsIcon }, set: { on in
                    showsIcon = on
                    setShowsMenuBarIcon(on)
                }))
            }
        }
        .onAppear {
            showsIcon = showsMenuBarIcon()
            readLoginStatus()
        }
    }

    private func readLoginStatus() {
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    private func setOpensAtLogin(_ on: Bool) {
        loginProblem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginProblem = String(localized: "無法變更：\(error.localizedDescription)")
        }
        readLoginStatus()
    }
}

// MARK: - Notes

/// How new notes start out, how big the text is on every note, and the AI notes' colour.
struct NotesPane: View {
    let settings: () -> NoteSettings
    let apply: (NoteSettings) -> Void
    let aiColor: () -> NoteColor
    let setAIColor: (NoteColor) -> Void
    /// False where no model can write AI notes, which hides them.
    let offersAINotes: Bool

    @State private var current = NoteSettings()
    @State private var currentAIColor = NoteColor.blue

    var body: some View {
        SettingsForm(reset: {
            current = NoteSettings()
            customSize = false
            apply(current)
        }, canReset: current != NoteSettings()) {
            SettingsSection(String(localized: "新便利貼"),
                            footnote: String(localized: "新增的便利貼用這個大小與顏色，之後仍可拖曳邊緣調整大小、在動態島換色。已有的便利貼不變。")) {
                Picker(String(localized: "大小"), selection: Binding(get: { sizeChoice }, set: chooseSize)) {
                    ForEach(NoteSettings.SizePreset.allCases, id: \.self) { preset in
                        Text(Self.name(of: preset)).tag(preset)
                    }
                }
                if sizeChoice == .custom {
                    LabeledContent(String(localized: "寬度")) { sizeField(\.noteSize.width, in: NoteSettings.widths) }
                    LabeledContent(String(localized: "高度")) { sizeField(\.noteSize.height, in: NoteSettings.heights) }
                }
                LabeledContent(String(localized: "顏色")) {
                    colorDots(selected: current.noteColor) { color in
                        current.noteColor = color
                        apply(current)
                    }
                }
            }
            SettingsSection(String(localized: "文字"),
                            footnote: String(localized: "所有便利貼的文字都用這個大小，第一行標題大 1 pt。編輯便利貼時也可以用 ⌘+ 與 ⌘− 調整。")) {
                LabeledContent(String(localized: "字體大小")) {
                    HStack(spacing: 10) {
                        Slider(value: binding(\.textSize), in: NoteSettings.textSizes, step: 1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("A").font(.system(size: 11))
                        } maximumValueLabel: {
                            Text("A").font(.system(size: 17))
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text(String(localized: "\(Int(current.textSize)) pt"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent(String(localized: "預覽")) {
                    Text(String(localized: "下一步：補測試"))
                        .font(.system(size: current.textSize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: NotePalette.of(current.noteColor).paperBottom)))
                        .foregroundStyle(Color(nsColor: NotePalette.of(current.noteColor).ink))
                }
            }
            if offersAINotes {
                SettingsSection(String(localized: "AI 便利貼"),
                                footnote: String(localized: "所有 AI 便利貼都用這個顏色，變更後立即套用。")) {
                    Picker(String(localized: "顏色"), selection: Binding(get: { currentAIColor }, set: { color in
                        currentAIColor = color
                        setAIColor(color)
                    })) {
                        ForEach(NoteColor.aiColors, id: \.self) { color in
                            Label {
                                Text(NotePalette.of(color).name)
                            } icon: {
                                Image(nsImage: NotePalette.of(color).swatch(diameter: 12, selected: false))
                            }
                            .tag(color)
                        }
                    }
                }
            }
        }
        .onAppear {
            current = settings()
            currentAIColor = aiColor()
        }
    }

    /// "自訂" stays chosen while its fields are being used, even when they happen to match a named size.
    @State private var customSize = false

    private var sizeChoice: NoteSettings.SizePreset {
        customSize ? .custom : current.sizePreset
    }

    private func chooseSize(_ preset: NoteSettings.SizePreset) {
        customSize = preset == .custom
        guard let size = preset.size else { return }
        current.noteSize = size
        apply(current)
    }

    private static func name(of preset: NoteSettings.SizePreset) -> String {
        switch preset {
        case .small: String(localized: "小（200 × 150）")
        case .medium: String(localized: "中（240 × 180）")
        case .large: String(localized: "大（320 × 240）")
        case .custom: String(localized: "自訂…")
        }
    }

    private func binding(_ path: WritableKeyPath<NoteSettings, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { current[keyPath: path] }, set: { value in
            guard value != current[keyPath: path] else { return }
            current[keyPath: path] = value
            apply(current)
        })
    }

    private func sizeField(_ path: WritableKeyPath<NoteSettings, CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { Double(current[keyPath: path]) },
                                         set: { binding(path).wrappedValue = CGFloat($0) }),
                      format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
            Stepper("", value: binding(path), in: range, step: 10)
                .labelsHidden()
            Text("pt").foregroundStyle(.secondary)
        }
    }

    private func colorDots(selected: NoteColor, pick: @escaping (NoteColor) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(NoteColor.paperColors, id: \.self) { color in
                ColorDot(color: color, selected: selected == color) { pick(color) }
            }
        }
    }
}

struct ColorDot: View {
    let color: NoteColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let palette = NotePalette.of(color)
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: palette.paperBottom))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .frame(width: 22, height: 22)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(palette.name)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shortcuts

extension ShortcutAction {
    var title: String {
        switch self {
        case .newNote: String(localized: "新增便利貼")
        case .showList: String(localized: "便利貼列表")
        case .hideAll: String(localized: "暫時隱藏全部")
        }
    }
}

struct ShortcutsPane: View {
    let hotKeys: HotKeys
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var messages: [ShortcutAction: String] = [:]
    /// Bumped to redraw after `hotKeys` changed, since it isn't observable.
    @State private var revision = 0

    var body: some View {
        SettingsForm(reset: {
            stopRecording()
            hotKeys.resetToDefaults()
            messages = [:]
            revision += 1
        }, canReset: hotKeys.settings != .defaults) {
            SettingsSection(String(localized: "全域快捷鍵"),
                            footnote: String(localized: "在任何 App 裡都能使用。按一下快捷鍵再按下新的組合，按 Esc 取消。")) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button(recording == action ? String(localized: "請按下新的快捷鍵…") : hotKeys.settings[action].displayString) {
                                recording == action ? stopRecording() : startRecording(action)
                            }
                            .frame(minWidth: 140)
                            if let message = message(for: action) {
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .id(revision)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func message(for action: ShortcutAction) -> String? {
        if let message = messages[action] { return message }
        return hotKeys.unavailable.contains(action)
            ? String(localized: "目前無法使用，可能已被其他 App 使用，請換一個。") : nil
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        messages[action] = nil
        hotKeys.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            guard let key = HotKeys.label(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else { return nil }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode),
                                    modifiers: GlobalHotKey.modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask)),
                                    key: key)
            stopRecording()
            if case .failure(let error) = hotKeys.change(action, to: shortcut) {
                messages[action] = Self.explain(error, shortcut: shortcut)
            }
            revision += 1
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { hotKeys.suspend(false) }
        recording = nil
    }

    private static func explain(_ error: HotKeys.ChangeError, shortcut: Shortcut) -> String {
        let keys = shortcut.displayString
        switch error {
        case .problem(.needsModifier):
            return String(localized: "全域快捷鍵需要包含 ⌘、⌥ 或 ⌃。")
        case .problem(.commonInApps):
            return String(localized: "\(keys) 常是其他 App 自己的快捷鍵，請再加上 ⌥ 或 ⌃。")
        case .problem(.usedBy(let other)):
            return String(localized: "\(keys) 已用於「\(other.title)」。")
        case .problem(.usedBySystem):
            return String(localized: "\(keys) 已被系統使用（系統設定 › 鍵盤 › 鍵盤快速鍵）。")
        case .unavailable:
            return String(localized: "無法使用 \(keys)，可能已被其他 App 使用。原本的快捷鍵保留不變。")
        }
    }
}

// MARK: - Backup

struct BackupPane: View {
    /// Each returns what to tell the user, or nil when they cancelled.
    let export: () -> String?
    let importBackup: () -> String?
    @State private var result: String?

    var body: some View {
        SettingsForm {
            SettingsSection(String(localized: "備份與搬家"),
                            footnote: String(localized: "匯出會把所有便利貼（包括垃圾桶裡的）存成一個檔案。在另一台 Mac 或重新安裝後匯入，已有的便利貼不會重複，同一張保留較新的版本。")) {
                LabeledContent(String(localized: "匯出")) {
                    Button(String(localized: "匯出全部便利貼…")) { result = export() ?? result }
                }
                LabeledContent(String(localized: "匯入")) {
                    Button(String(localized: "匯入備份…")) { result = importBackup() ?? result }
                }
                if let result {
                    Text(result)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    let accessibility: AccessibilityPermission
    let onAccessibilityGranted: @MainActor () -> Void
    let claudeConsent: () -> Bool?
    let setClaudeConsent: (Bool) -> Void
    @State private var isGranted = false
    @State private var consent: Bool?

    var body: some View {
        SettingsForm {
            SettingsSection(AccessibilityPermission.permissionName,
                            footnote: String(localized: "用來知道你目前在哪個視窗，讓便利貼在切走時隱藏、回來時出現，並跟著視窗移動。Hintlet 只讀取視窗的位置與標題，不會記錄你的輸入。沒有這個權限時，便利貼只能浮動顯示。")) {
                HStack {
                    StatusLabel(isOn: isGranted, on: String(localized: "已開啟"), off: String(localized: "未開啟"))
                    Spacer()
                    if !isGranted {
                        Button(String(localized: "打開系統設定")) {
                            accessibility.openSystemSettings(onGranted: onAccessibilityGranted)
                        }
                    }
                }
            }
            SettingsSection(String(localized: "Claude 的完整輔助使用資訊"),
                            footnote: String(localized: "開啟後 Hintlet 會請 Claude 提供完整的輔助使用資訊，才能知道目前顯示的是哪個對話，讓便利貼貼在對話上。Claude 會多用一些記憶體與處理器資源。Hintlet 只讀取對話的網址與標題；只有開了 AI 便利貼的 Chat 對話，才會讀取頁面上已載入的訊息。關閉時，Claude 上的便利貼綁在整個視窗。")) {
                Toggle(isOn: Binding(get: { consent == true }, set: { on in
                    setClaudeConsent(on)
                    consent = claudeConsent()
                })) {
                    Text(String(localized: "認得 Claude 的對話"))
                }
                .toggleStyle(.switch)
                Text(consentStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(String(localized: "Hintlet 不需要「輸入監控」或「螢幕錄製」權限，也不會上傳任何內容。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Permissions change in System Settings, without notice: check while the pane is open.
            while !Task.isCancelled {
                isGranted = accessibility.isGranted
                consent = claudeConsent()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var consentStatus: String {
        switch consent {
        case nil: String(localized: "還沒決定：第一次在 Claude 上新增便利貼時會詢問。")
        case true?:
            isGranted ? String(localized: "已開啟。") : String(localized: "已開啟，但要先開啟上面的權限才會生效。")
        case false?: String(localized: "已關閉：Claude 上的便利貼綁在整個視窗。")
        }
    }
}

struct StatusLabel: View {
    let isOn: Bool
    let on: String
    let off: String

    var body: some View {
        Label {
            Text(isOn ? on : off)
        } icon: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isOn ? .green : .orange)
        }
    }
}
