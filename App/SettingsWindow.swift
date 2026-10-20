import AppKit
import SwiftUI

/// One tab of the settings window. Each pane is self-contained: it gets what it needs from AppDelegate
/// when it is made, so adding a pane means adding one view and one entry in `AppDelegate.settingsPanes`.
struct SettingsPane: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let content: AnyView

    init(id: String, title: String, symbol: String, @ViewBuilder content: () -> some View) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.content = AnyView(content())
    }
}

/// The settings window, as macOS apps have it: a row of icons in the toolbar, the window titled after the
/// tab shown and fitting its height to it. Hintlet has no Dock icon or main window, so it brings the app
/// forward while it is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let makePanes: () -> [SettingsPane]
    private var window: NSWindow?
    private static let lastTabKey = "settingsTab"

    init(panes: @escaping () -> [SettingsPane]) {
        makePanes = panes
    }

    func show(tab: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let tab, let tabs = window.contentViewController as? SettingsTabs { tabs.select(tab) }
        AppPresence.comeForward()
        window.makeKeyAndOrderFront(nil)
    }

    var isShown: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabs(panes: makePanes(), selected: UserDefaults.standard.string(forKey: Self.lastTabKey))
        tabs.onSelect = { UserDefaults.standard.set($0, forKey: Self.lastTabKey) }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        // Opens where the user is, also over a full-screen app, instead of taking them to another Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        tabs.fitWindow(animated: false)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Made afresh next time, so every pane shows the current state.
        window = nil
    }
}

/// The tabs, each pane in its own hosting controller so the window can take that pane's height.
private final class SettingsTabs: NSTabViewController {
    private static let width: CGFloat = 520
    var onSelect: ((String) -> Void)?

    init(panes: [SettingsPane], selected: String?) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade]
        for pane in panes {
            let hosting = NSHostingController(rootView: AnyView(pane.content.frame(width: Self.width)))
            // A pane that grows (a section appearing) tells the window, which grows with it.
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.id
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        if let index = panes.firstIndex(where: { $0.id == selected }) { selectedTabViewItemIndex = index }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ id: String) {
        guard let index = tabViewItems.firstIndex(where: { $0.identifier as? String == id }) else { return }
        selectedTabViewItemIndex = index
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let item else { return }
        view.window?.title = item.label
        if let id = item.identifier as? String { onSelect?(id) }
        fitWindow(animated: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        guard viewController === tabViewItems[selectedTabViewItemIndex].viewController else { return }
        fitWindow(animated: true)
    }

    /// The window takes the shown pane's height, keeping its top edge where it is.
    func fitWindow(animated: Bool) {
        guard let window = view.window ?? viewIfLoaded?.window,
              let pane = tabViewItems[selectedTabViewItemIndex].viewController as? NSHostingController<AnyView> else { return }
        let ideal = pane.sizeThatFits(in: NSSize(width: Self.width, height: 10_000)).height
        let height = min(ideal, (window.screen?.visibleFrame.height ?? 900) - 120)
        let content = NSSize(width: Self.width, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// A pane's content as macOS settings lay it out: grouped rows, each group with a header and a note under it.
/// A button for putting the pane back to its defaults sits under the groups, on the right.
struct SettingsForm<Content: View>: View {
    let reset: (() -> Void)?
    let canReset: Bool
    @ViewBuilder let content: Content

    init(reset: (() -> Void)? = nil, canReset: Bool = true, @ViewBuilder content: () -> Content) {
        self.reset = reset
        self.canReset = canReset
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            if let reset {
                HStack {
                    Spacer()
                    Button(String(localized: "回復預設值"), action: reset)
                        .disabled(!canReset)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

/// One group of rows in a `SettingsForm`, with an explanation under it.
struct SettingsSection<Content: View>: View {
    let title: String
    let footnote: String?
    @ViewBuilder let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
