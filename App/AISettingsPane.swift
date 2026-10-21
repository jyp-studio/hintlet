import AppKit
import HintletCore
import SwiftUI

/// The AI tab: who writes AI notes (the on-device model; the user's Claude or Codex account through its
/// CLI; or the Claude or OpenAI API with the user's own key; each one that uploads chosen only after the
/// user agrees to where it goes), where the CLIs are, and the keys. The AI notes' colour is on the Notes tab.
struct AIPane: View {
    let onDeviceAvailable: Bool
    let settings: () -> AISettings
    let apply: (AISettings) -> Void
    /// Where a CLI is, with the path the user picked (if any) tried first.
    let locate: (SummaryTool, String?) -> URL?
    let claudeKey: APIKeyField.Store
    let openAIKey: APIKeyField.Store

    @State private var current = AISettings()
    @State private var confirming: SummaryBackend?
    @State private var claudeFound: URL?
    @State private var codexFound: URL?
    @State private var pathMessage: String?
    @State private var account: AccountState?
    @State private var isSigningIn = false

    var body: some View {
        SettingsForm {
            SettingsSection(String(localized: "由誰寫 AI 便利貼"), footnote: Self.footnote(for: current.backend)) {
                Picker(String(localized: "由誰寫 AI 便利貼"), selection: Binding(get: { current.backend }, set: choose)) {
                    ForEach(Self.backends, id: \.self) { backend in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(of: backend))
                            Text(subtitle(of: backend))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(backend)
                        .disabled(backend == .onDevice && !onDeviceAvailable)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            switch current.backend {
            case .claudeAccount: accountSection(.claudeCode)
            case .codexAccount: accountSection(.codex)
            case .claudeAPI:
                SettingsSection(String(localized: "Claude API key"), footnote: Self.keyFootnote) {
                    APIKeyField(store: claudeKey)
                    Link(String(localized: "到 Anthropic Console 取得 API key"),
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                }
            case .openAIAPI:
                SettingsSection(String(localized: "OpenAI API key"), footnote: Self.keyFootnote) {
                    APIKeyField(store: openAIKey)
                    Link(String(localized: "到 OpenAI 取得 API key"),
                         destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.callout)
                }
            default:
                EmptyView()
            }
        }
        .onAppear {
            current = settings()
            relocate()
        }
        .task(id: current.backend) { await checkAccount() }
        .alert(confirming.map(Self.confirmTitle) ?? "", isPresented: Binding(get: { confirming != nil },
                                                                           set: { if !$0 { confirming = nil } }),
               presenting: confirming) { backend in
            Button(String(localized: "改用並上傳")) {
                current.backend = backend
                apply(current)
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: { backend in
            Text(Self.confirmMessage(backend))
        }
    }

    private static let backends: [SummaryBackend] = [.onDevice, .claudeAccount, .codexAccount, .claudeAPI, .openAIAPI]

    private static func title(of backend: SummaryBackend) -> String {
        switch backend {
        case .claudeAccount: String(localized: "Claude 帳號")
        case .codexAccount: String(localized: "ChatGPT 帳號（Codex）")
        case .claudeAPI: String(localized: "Claude API key")
        case .openAIAPI: String(localized: "OpenAI API key")
        default: String(localized: "裝置端模型")
        }
    }

    private func subtitle(of backend: SummaryBackend) -> String {
        switch backend {
        case .claudeAccount: String(localized: "用你的 Claude 方案，免 API key；會上傳到 Anthropic")
        case .codexAccount: String(localized: "用你的 ChatGPT 方案，免 API key；會上傳到 OpenAI")
        case .claudeAPI: String(localized: "按用量付費；會上傳到 Anthropic")
        case .openAIAPI: String(localized: "按用量付費；會上傳到 OpenAI")
        default:
            onDeviceAvailable ? String(localized: "在這台 Mac 上執行，不上傳") : String(localized: "這台 Mac 無法使用（需要 Apple Intelligence）")
        }
    }

    /// The account: whether it is installed and signed in, and the one step that gets it there.
    @ViewBuilder private func accountSection(_ tool: SummaryTool) -> some View {
        let name = tool == .claudeCode ? String(localized: "Claude 帳號") : String(localized: "ChatGPT 帳號")
        SettingsSection(name, footnote: String(localized: "Hintlet 只在背景用它寫摘要，不給它任何工具，也不留下對話紀錄。")) {
            LabeledContent(String(localized: "狀態")) {
                HStack(spacing: 8) {
                    if isSigningIn || account == nil { ProgressView().controlSize(.small) }
                    Text(statusText(tool)).foregroundStyle(statusIsGood ? .primary : .secondary)
                    if statusIsGood {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Button(String(localized: "重新檢查")) { Task { await checkAccount() } }
                            .controlSize(.small)
                    }
                }
            }
            switch account {
            case .notInstalled?:
                LabeledContent {
                    HStack {
                        Button(String(localized: "已安裝在其他位置…")) { pick(tool) }
                        Link(tool == .claudeCode ? String(localized: "取得 Claude Code") : String(localized: "取得 ChatGPT"),
                             destination: URL(string: tool == .claudeCode ? "https://claude.com/product/claude-code"
                                                                         : "https://openai.com/chatgpt/download/")!)
                    }
                } label: {
                    Text(tool == .claudeCode ? String(localized: "需要 Claude Code 才能用帳號登入。")
                                             : String(localized: "需要 ChatGPT App（內含 Codex）才能用帳號登入。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .signedOut?, .unknown?:
                LabeledContent {
                    if isSigningIn {
                        Button(String(localized: "取消")) { isSigningIn = false }
                    } else {
                        Button(String(localized: "登入…")) { Task { await signIn(tool) } }
                            .keyboardShortcut(.defaultAction)
                    }
                } label: {
                    Text(isSigningIn ? String(localized: "請在瀏覽器完成登入，完成後會自動回到這裡。")
                                     : String(localized: "會打開瀏覽器，登入後授權 Hintlet 使用。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .signedIn?, nil:
                EmptyView()
            }
            if let pathMessage {
                Text(pathMessage).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var statusIsGood: Bool {
        if case .signedIn? = account { true } else { false }
    }

    private func statusText(_ tool: SummaryTool) -> String {
        switch account {
        case nil: String(localized: "檢查中…")
        case .notInstalled?: tool == .claudeCode ? String(localized: "找不到 Claude Code") : String(localized: "找不到 Codex")
        case .signedOut?: isSigningIn ? String(localized: "等待登入…") : String(localized: "尚未登入")
        case .unknown?: String(localized: "無法確認是否已登入")
        case .signedIn(let email)?: email.map { String(localized: "已登入：\($0)") } ?? String(localized: "已登入")
        }
    }

    private func signIn(_ tool: SummaryTool) async {
        isSigningIn = true
        let state = await AISummaries.account(tool, at: found(tool)).signIn()
        guard isSigningIn else { return }
        isSigningIn = false
        account = state
    }

    private func checkAccount() async {
        let tool: SummaryTool
        switch current.backend {
        case .claudeAccount: tool = .claudeCode
        case .codexAccount: tool = .codex
        default:
            account = nil
            return
        }
        account = nil
        relocate()
        account = await AISummaries.account(tool, at: found(tool)).state()
    }

    private func found(_ tool: SummaryTool) -> URL? {
        tool == .claudeCode ? claudeFound : codexFound
    }

    private func choose(_ backend: SummaryBackend) {
        guard backend != current.backend else { return }
        if backend.uploadsContent {
            // Only once the user has read where it goes and agreed.
            confirming = backend
        } else {
            current.backend = backend
            apply(current)
        }
    }

    private func relocate() {
        claudeFound = locate(.claudeCode, current.claudePath)
        codexFound = locate(.codex, current.codexPath)
    }

    private func pick(_ tool: SummaryTool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // So the codex inside ChatGPT.app can be picked.
        panel.treatsFilePackagesAsDirectories = true
        panel.message = tool == .claudeCode ? String(localized: "選擇 claude 執行檔") : String(localized: "選擇 codex 執行檔")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            pathMessage = String(localized: "這個檔案不能執行，請選 claude 或 codex 本身。")
            return
        }
        pathMessage = nil
        switch tool {
        case .claudeCode: current.claudePath = url.path
        case .codex: current.codexPath = url.path
        }
        apply(current)
        Task { await checkAccount() }
    }

    private static let keyFootnote = String(localized: "key 只存在 macOS 鑰匙圈，不會寫進便利貼的資料檔、備份或匯出檔。")

    private static func footnote(for backend: SummaryBackend) -> String {
        switch backend {
        case .claudeAccount:
            String(localized: "使用 Claude 帳號時，Hintlet 在背景執行這台 Mac 上的 Claude Code，AI 便利貼所在對話的內容會上傳到 Anthropic，用量算在你登入的 Claude 方案裡，不需要 API key。")
        case .codexAccount:
            String(localized: "使用 Codex 帳號時，Hintlet 在背景執行這台 Mac 上的 Codex，AI 便利貼所在對話的內容會上傳到 OpenAI，用量算在你登入 Codex 的 ChatGPT 方案裡，不需要 API key。")
        case .claudeAPI:
            String(localized: "使用 Claude API 時，AI 便利貼所在對話的內容會上傳到 Anthropic，費用由你的 API key 支付。")
        case .openAIAPI:
            String(localized: "使用 OpenAI API 時，AI 便利貼所在對話的內容會上傳到 OpenAI，費用由你的 API key 支付。")
        default:
            String(localized: "裝置端模型在這台 Mac 上執行，對話內容不會離開這台 Mac。")
        }
    }

    private static func confirmTitle(_ backend: SummaryBackend) -> String {
        switch backend {
        case .claudeAccount: String(localized: "改用 Claude 帳號？")
        case .codexAccount: String(localized: "改用 Codex 帳號？")
        case .openAIAPI: String(localized: "改用 OpenAI API？")
        default: String(localized: "改用 Claude API？")
        }
    }

    private static func confirmMessage(_ backend: SummaryBackend) -> String {
        switch backend {
        case .claudeAccount:
            String(localized: "AI 便利貼要寫摘要時，Hintlet 會在背景執行這台 Mac 上的 Claude Code，把它所在對話的內容（你的要求與 Claude 的回覆）交給 Claude Code 上傳到 Anthropic，用你登入的 Claude 帳號的用量。之後切走對話時的自動更新也會上傳。只有 AI 便利貼的對話會上傳，其他便利貼與對話不會。")
        case .codexAccount:
            String(localized: "AI 便利貼要寫摘要時，Hintlet 會在背景執行這台 Mac 上的 Codex，把它所在對話的內容（你的要求與 Claude 的回覆）交給 Codex 上傳到 OpenAI，用你登入 Codex 的 ChatGPT 帳號的用量。之後切走對話時的自動更新也會上傳。只有 AI 便利貼的對話會上傳，其他便利貼與對話不會。")
        case .openAIAPI:
            String(localized: "AI 便利貼要寫摘要時，它所在對話的內容（你的要求與 Claude 的回覆）會上傳到 OpenAI API，使用你的 OpenAI API key 並由你付費。之後切走對話時的自動更新也會上傳。只有 AI 便利貼的對話會上傳，其他便利貼與對話不會。")
        default:
            String(localized: "AI 便利貼要寫摘要時，它所在對話的內容（你的要求與 Claude 的回覆）會上傳到 Anthropic 的 Claude API，使用你的 API key 並由你付費。之後切走對話時的自動更新也會上傳。只有 AI 便利貼的對話會上傳，其他便利貼與對話不會。")
        }
    }
}

/// An API key: saved in the Keychain or not, entering and removing it.
struct APIKeyField: View {
    /// The Keychain item behind the field, with errors put into words.
    struct Store {
        let hasKey: () -> Bool
        /// Return an error to show, or nil when done.
        let save: (String) -> String?
        let remove: () -> String?

        init(keys: any APIKeyStore) {
            hasKey = { ((try? keys.read()) ?? nil)?.isEmpty == false }
            save = { key in
                do {
                    try keys.save(key)
                    return nil
                } catch {
                    return String(localized: "無法存進鑰匙圈。")
                }
            }
            remove = {
                do {
                    try keys.remove()
                    return nil
                } catch {
                    return String(localized: "無法從鑰匙圈移除。")
                }
            }
        }
    }

    let store: Store

    @State private var saved = false
    @State private var field = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if saved {
                HStack {
                    StatusLabel(isOn: true, on: String(localized: "已儲存在鑰匙圈"), off: "")
                    Spacer()
                    Button(String(localized: "移除 key")) {
                        message = store.remove()
                        saved = store.hasKey()
                    }
                }
            } else {
                HStack {
                    SecureField(String(localized: "貼上 API key"), text: $field)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "儲存")) {
                        message = store.save(field.trimmingCharacters(in: .whitespacesAndNewlines))
                        field = ""
                        saved = store.hasKey()
                    }
                    .disabled(field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
        }
        .onAppear { saved = store.hasKey() }
    }
}
