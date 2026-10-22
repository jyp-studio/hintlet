import AppKit
import HintletCore

/// A short note by the pointer when ⌘⌥N can't do what it usually does, e.g. on a new Claude conversation
/// that has no ID yet. A system popover pointing at where the note would have gone, laid out like a
/// macOS alert: symbol, bold title, secondary explanation, buttons on the right.
@MainActor
final class HintPanel {
    struct Hint {
        var symbol: String
        var title: String
        var message: String
        /// The way out, as the default button; without one the hint goes away by itself.
        var actionTitle: String?
        /// How long it stays, when it is worth more than the usual few seconds.
        var lifetime: TimeInterval?
    }

    private static let textWidth: CGFloat = 260
    /// Hints without buttons fade on their own; ones that offer a choice wait longer.
    private static let lifetime: TimeInterval = 5
    private static let lifetimeWithAction: TimeInterval = 12

    /// An invisible, click-through window at the pointer for the popover to point at.
    private let anchor: NSPanel
    private var popover: NSPopover?
    private var onAction: (() -> Void)?
    private var dismissTimer: Timer?
    /// The note the hint is about, if any; it goes when that note does.
    private(set) var note: NoteID?

    init() {
        anchor = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.level = .floating
        anchor.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.animationBehavior = .none
        anchor.isReleasedWhenClosed = false
    }

    func show(_ hint: Hint, at point: CGPoint, about note: NoteID? = nil, onAction: (() -> Void)? = nil) {
        dismiss()
        self.note = note
        self.onAction = onAction
        anchor.setFrameOrigin(NSPoint(x: point.x - 1, y: point.y - 1))
        anchor.orderFrontRegardless()

        let controller = NSViewController()
        let view = content(for: hint)
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        controller.view = view
        controller.preferredContentSize = view.fittingSize
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        self.popover = popover

        let lifetime = hint.lifetime ?? (hint.actionTitle == nil ? Self.lifetime : Self.lifetimeWithAction)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        onAction = nil
        note = nil
        popover?.close()
        popover = nil
        anchor.orderOut(nil)
    }

    private func content(for hint: Hint) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: hint.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            .applying(.preferringHierarchical())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: hint.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: hint.message)
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = Self.textWidth
        message.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        let text = NSStackView(views: [title, message])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 12

        let column = NSStackView(views: [top])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        if let actionTitle = hint.actionTitle {
            let cancel = NSButton(title: String(localized: "好"), target: self, action: #selector(dismissClicked))
            cancel.keyEquivalent = "\u{1b}"
            let action = NSButton(title: actionTitle, target: self, action: #selector(actionClicked))
            action.keyEquivalent = "\r"
            // Clicked, not tabbed to: no focus ring on a hint the user didn't ask for.
            cancel.refusesFirstResponder = true
            action.refusesFirstResponder = true
            let buttons = NSStackView(views: [cancel, action])
            buttons.spacing = 8
            column.addArrangedSubview(buttons)
        }
        return container
    }

    @objc private func actionClicked() {
        let run = onAction
        dismiss()
        run?()
    }

    @objc private func dismissClicked() {
        dismiss()
    }
}

extension HintPanel.Hint {
    static let firstNote = HintPanel.Hint(
        symbol: "hand.tap", title: String(localized: "你的第一張便利貼"),
        message: String(localized: "直接打字就好，按 Esc 結束。按住上方的標籤可以換顏色、改貼的位置或刪除。"),
        lifetime: 10)
    static let draftConversation = HintPanel.Hint(
        symbol: "bubble.left.and.text.bubble.right", title: String(localized: "新對話還沒建立"),
        message: String(localized: "送出第一則訊息後，就能把便利貼貼在這個對話上。也可以先貼在整個 Claude 視窗。"),
        actionTitle: String(localized: "改貼在這個視窗"))
    static let claudeSettings = HintPanel.Hint(
        symbol: "gearshape", title: String(localized: "Claude 的設定開著"),
        message: String(localized: "關掉設定、回到對話後再貼。"))
    static let fellBackToWindow = HintPanel.Hint(
        symbol: "macwindow", title: String(localized: "貼在整個 Claude 視窗"),
        message: String(localized: "認不出這一頁是哪個對話，所以這張便利貼綁在視窗上，任何頁面都會看到。"))
    static let newBrowserTab = HintPanel.Hint(
        symbol: "globe", title: String(localized: "這個分頁還沒有網頁"),
        message: String(localized: "打開網頁後，就能把便利貼貼在那個網頁上。也可以先貼在整個視窗。"),
        actionTitle: String(localized: "改貼在這個視窗"))
    static let browserFellBackToWindow = HintPanel.Hint(
        symbol: "macwindow", title: String(localized: "貼在整個視窗"),
        message: String(localized: "這一頁是瀏覽器自己的頁面，或讀不到網址，所以這張便利貼綁在視窗上，換到任何網頁都會看到。"))
}
