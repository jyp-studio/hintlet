import AppKit
import Combine
import HintletCore
import SwiftUI

/// The first launch's steps: what Hintlet does, the one permission it needs and why, and (once it is on) how to
/// make a note. Shown once by itself; the menu bar menu's 入門指南 shows it again. One thing at a time: skipping the
/// permission ends the guide, and making a note while it is open closes it, so the note and its tip have the
/// screen to themselves.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static let doneKey = "onboardingDone"
    private let accessibility: AccessibilityPermission
    private let shortcut: (ShortcutAction) -> String
    private let onGranted: @MainActor () -> Void
    private var window: NSWindow?
    private let model = OnboardingModel()

    init(accessibility: AccessibilityPermission, shortcut: @escaping (ShortcutAction) -> String,
         onGranted: @escaping @MainActor () -> Void) {
        self.accessibility = accessibility
        self.shortcut = shortcut
        self.onGranted = onGranted
    }

    var isDone: Bool { UserDefaults.standard.bool(forKey: Self.doneKey) }

    func showIfFirstLaunch() {
        if !isDone { show() }
    }

    func show() {
        model.page = 0
        #if DEBUG
        // `-previewOnboardingPage 2`: straight to that step.
        model.page = UserDefaults.standard.integer(forKey: "previewOnboardingPage")
        #endif
        let window = self.window ?? makeWindow()
        self.window = window
        AppPresence.comeForward()
        center(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// The user made a note: the guide has done its job and steps out of the way at once.
    func noteWasMade() {
        guard let window, window.isVisible else { return }
        window.close()
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(
            model: model,
            isGranted: { [accessibility] in accessibility.isGranted },
            openSettings: { [accessibility, onGranted] in accessibility.openSystemSettings(onGranted: onGranted) },
            newNoteShortcut: shortcut(.newNote),
            listShortcut: shortcut(.showList),
            finish: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        // Its size now, not once SwiftUI has laid it out: centring a window that still has no size puts its
        // corner in the middle, and it then grows off towards the top right.
        window.setContentSize(Self.size)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "歡迎使用 Hintlet")
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    static let size = NSSize(width: 560, height: 640)

    /// In the middle of the screen the user is on (the one with the pointer), a little above centre, as macOS
    /// places a new window.
    private func center(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            window.center()
            return
        }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                      y: area.minY + (area.height - size.height) * 0.6))
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window = nil
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page = 0
    /// Which way the last step went: the next page comes in from the right, the previous one from the left.
    @Published var forward = true
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let isGranted: () -> Bool
    let openSettings: () -> Void
    let newNoteShortcut: String
    let listShortcut: String
    let finish: () -> Void

    @State private var granted = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case 0: welcome
                case 1: permission
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 48)
            .padding(.top, 32)
            // Each page fits above the bottom bar, which stays put from page to page.
            .layoutPriority(1)
            .transition(.asymmetric(insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
            .id(model.page)
            footer
                .frame(height: 76)
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .onAppear { granted = isGranted() }
        .onReceive(poll) { _ in granted = isGranted() }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(spacing: 6) {
                Text(String(localized: "歡迎使用 Hintlet"))
                    .font(.system(size: 26, weight: .bold))
                Text(String(localized: "把便利貼貼在你正在做的事上。"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            FollowingNoteScene()
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "macwindow", title: String(localized: "跟著你的工作出現"),
                        text: String(localized: "貼在視窗、資料夾、網頁或 Claude、Codex 對話上。切走就收起來，回來時再出現。"))
                Feature(symbol: "sparkles", title: String(localized: "AI 便利貼"),
                        text: String(localized: "在對話上，讓 AI 幫你記下目標、重點和下一步，切回來一眼就懂。"))
                Feature(symbol: "character.cursor.ibeam", title: String(localized: "不擋你的路"),
                        text: String(localized: "在便利貼底下打字時，它會淡開；按住 ⌥ 可以看穿全部便利貼。"))
            }
        }
    }

    private var permission: some View {
        VStack(spacing: 22) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            VStack(spacing: 8) {
                Text(String(localized: "讓便利貼知道你在哪個視窗"))
                    .font(.system(size: 24, weight: .bold))
                Text(String(localized: "Hintlet 需要「\(AccessibilityPermission.permissionName)」權限，才能在你切換視窗時收起或拿出便利貼，並讓它跟著視窗移動。"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "eye", title: String(localized: "只看位置和名稱"),
                        text: String(localized: "讀的是前景視窗的位置、標題，以及網頁或對話的網址，不讀你寫的內容。"))
                Feature(symbol: "keyboard", title: String(localized: "不記錄打字"),
                        text: String(localized: "不需要「輸入監控」或「螢幕錄製」，也不會上傳任何東西。"))
            }
            if granted {
                Label(String(localized: "已經開啟"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            } else {
                Button(String(localized: "打開系統設定")) { openSettings() }
                    .controlSize(.large)
                    .padding(.top, 4)
                Text(String(localized: "在清單裡打開「Hintlet」，回到這裡就會看到勾勾。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 22) {
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)
            VStack(spacing: 8) {
                Text(String(localized: "貼一張試試看"))
                    .font(.system(size: 24, weight: .bold))
                Text(String(localized: "切到任何一個視窗，按下："))
                    .foregroundStyle(.secondary)
            }
            Keycaps(shortcut: newNoteShortcut)
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "hand.tap", title: String(localized: "按住上方的標籤"),
                        text: String(localized: "可以換顏色、改貼的位置，或刪除。按一下則收合成小標籤。"))
                Feature(symbol: "list.bullet.rectangle", title: String(localized: "所有便利貼：\(listShortcut)"),
                        text: String(localized: "搜尋、找回或還原便利貼。"))
                Feature(symbol: "menubar.rectangle", title: String(localized: "選單列的 Hintlet 圖示"),
                        text: String(localized: "設定都在這裡，也可以再打開這份指南。"))
            }
            .padding(.top, 4)
        }
    }

    // MARK: Footer

    /// The dots stay in the middle whatever the buttons on either side say.
    private var footer: some View {
        HStack {
            if model.page > 0 {
                Button(String(localized: "上一步")) { go(model.page - 1) }
                    .controlSize(.large)
            }
            Spacer()
            if model.page < Self.pages - 1 {
                // Without the permission a note can't follow its window yet: the guide ends here, and the first
                // note made once it is on gets its tip.
                Group {
                    if model.page == 1 && !granted {
                        Button(String(localized: "稍後再說")) { finish() }
                    } else {
                        Button(String(localized: "繼續")) { go(model.page + 1) }
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "開始使用")) { finish() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .overlay {
            HStack(spacing: 7) {
                ForEach(0..<Self.pages, id: \.self) { index in
                    Circle()
                        .fill(index == model.page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .animation(nil, value: model.page)
        }
    }

    private func go(_ page: Int) {
        // Set first, so the page leaving takes the same direction as the one coming.
        model.forward = page > model.page
        DispatchQueue.main.async { withAnimation(.smooth(duration: 0.35)) { model.page = page } }
    }
}

/// A symbol, a bold line and a line of explanation, as Apple's "What's New" screens list features.
private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A shortcut as keys on a keyboard: "⌥⌘N" as ⌥ ⌘ N.
private struct Keycaps: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(shortcut.map(String.init).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
            }
        }
    }
}

/// What Hintlet does, without words: a note on one window; another window comes to the front and the note
/// steps away; the first comes back, and so does its note. Round and round, quietly.
private struct FollowingNoteScene: View {
    @State private var firstInFront = true
    private let size = CGSize(width: 300, height: 130)

    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniWindow(title: String(localized: "企劃書"))
                .frame(width: 190, height: 110)
                .offset(x: 10, y: 10)
                .zIndex(firstInFront ? 1 : 0)
                .overlay(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(red: 1, green: 0.85, blue: 0.35))
                        .frame(width: 54, height: 44)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach([30.0, 22, 26], id: \.self) { width in
                                    Capsule().fill(.black.opacity(0.25)).frame(width: width, height: 3)
                                }
                            }
                            .padding(7)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .offset(x: -4, y: 30)
                        .opacity(firstInFront ? 1 : 0)
                        .scaleEffect(firstInFront ? 1 : 0.92)
                }
                .zIndex(firstInFront ? 2 : 0)
            MiniWindow(title: String(localized: "郵件"))
                .frame(width: 170, height: 100)
                .offset(x: 120, y: 26)
                .zIndex(firstInFront ? 0 : 3)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .task {
            // Long enough on each window to see what happened.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(firstInFront ? 2.2 : 1.6))
                withAnimation(.smooth(duration: 0.45)) { firstInFront.toggle() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "便利貼貼在一個視窗上；切到另一個視窗時它收起來，回來時再出現。"))
    }
}

/// A window drawn small: the title bar's three dots, its name, and a few lines of content.
private struct MiniWindow: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            VStack(alignment: .leading, spacing: 6) {
                ForEach([0.75, 0.55, 0.65, 0.4], id: \.self) { share in
                    GeometryReader { proxy in
                        Capsule().fill(.secondary.opacity(0.25)).frame(width: proxy.size.width * share, height: 4)
                    }
                    .frame(height: 4)
                }
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
