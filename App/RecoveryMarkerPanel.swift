import AppKit
import QuartzCore
import StickyContextCore

/// "可能是這裡？": a small tag where a waiting note would go on the focused window. Clicking it brings the
/// note back there; the × turns the suggestion down for this window. Never binds anything by itself.
@MainActor
final class RecoveryMarkerPanel: NSPanel {
    static let height: CGFloat = 28
    private static let maxWidth: CGFloat = 280
    private static let fadeInDuration: TimeInterval = 0.15

    private let tag = RecoveryTagView()
    /// The window the suggestion is for, as last shown.
    private(set) var windowID: WindowID?
    private(set) var isShown = false

    init(onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        tag.onConfirm = onConfirm
        tag.onDismiss = onDismiss
        contentView = tag
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ candidate: RecoveryCandidate) {
        windowID = candidate.windowID
        tag.show(preview: candidate.preview)
    }

    /// The frame the tag, as last shown, takes with its top-left corner at `point`.
    func fittingFrame(topLeftAt point: CGPoint) -> CGRect {
        let width = min(tag.fittingSize.width, Self.maxWidth)
        return CGRect(x: point.x, y: point.y - Self.height, width: width, height: Self.height)
    }

    func place(at frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: true) }
    }

    func reveal() {
        isShown = true
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func conceal() {
        isShown = false
        tag.resetHover()
        orderOut(nil)
    }
}

private final class RecoveryTagView: NSView {
    private static let paper = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.72, alpha: 0.97)
    private static let paperHover = NSColor(srgbRed: 1.0, green: 0.91, blue: 0.56, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.42, green: 0.33, blue: 0, alpha: 1)
    private static let closeWidth: CGFloat = 24

    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSImageView()
    private let border = CAShapeLayer()
    private var isHovering = false
    private var pressedOnClose: Bool?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = Self.paper.cgColor
        layer?.cornerCurve = .continuous
        // Dashed, like the outline of something that isn't there yet.
        border.fillColor = nil
        border.strokeColor = Self.ink.withAlphaComponent(0.55).cgColor
        border.lineWidth = 1
        border.lineDashPattern = [3, 2]
        layer?.addSublayer(border)

        icon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = Self.ink
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Self.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "不是這裡"))
        close.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        close.contentTintColor = Self.ink.withAlphaComponent(0.7)
        close.widthAnchor.constraint(equalToConstant: Self.closeWidth - 10).isActive = true

        let row = NSStackView(views: [icon, label, close])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(preview: String) {
        let text = preview.isEmpty ? String(localized: "可能是這裡？（空白便利貼）") : String(localized: "可能是這裡？「\(preview)」")
        label.stringValue = text
        toolTip = String(localized: "按一下，把這張便利貼貼回這個視窗")
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: bounds.height / 2 - 0.5,
                             cornerHeight: bounds.height / 2 - 0.5, transform: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func isOnClose(_ event: NSEvent) -> Bool {
        convert(event.locationInWindow, from: nil).x > bounds.maxX - Self.closeWidth - 4
    }

    override func mouseDown(with event: NSEvent) {
        pressedOnClose = isOnClose(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedOnClose = nil }
        guard let pressedOnClose, bounds.contains(convert(event.locationInWindow, from: nil)),
              isOnClose(event) == pressedOnClose else { return }
        if pressedOnClose { onDismiss?() } else { onConfirm?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func resetHover() { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        layer?.backgroundColor = (hovering ? Self.paperHover : Self.paper).cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
