import AppKit
import StickyContextCore

/// Tells a click from picking something up: a press that travels a few points becomes a drag.
struct PressTracker {
    enum Event {
        /// Carries where the press started (screen coordinates), so what is carried doesn't lag the pointer.
        case began(from: NSPoint)
        case moved
        case ended
        /// Released without moving; carries the point in window coordinates.
        case click(at: NSPoint)
    }

    /// How far the pointer has to travel before a press becomes a drag.
    private static let threshold: CGFloat = 3
    private var pressPoint: NSPoint?
    private var pressScreenPoint: NSPoint = .zero
    private var isCarrying = false

    mutating func down(_ event: NSEvent) {
        pressPoint = event.locationInWindow
        pressScreenPoint = NSEvent.mouseLocation
        isCarrying = false
    }

    mutating func dragged(_ event: NSEvent) -> [Event] {
        guard let pressPoint else { return [] }
        if !isCarrying {
            let point = event.locationInWindow
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= Self.threshold else { return [] }
            isCarrying = true
            return [.began(from: pressScreenPoint), .moved]
        }
        return [.moved]
    }

    mutating func up() -> Event? {
        defer { pressPoint = nil; isCarrying = false }
        if isCarrying { return .ended }
        return pressPoint.map { .click(at: $0) }
    }
}

/// The island: a small black capsule straddling the middle of the note's top edge, holding the note on
/// like a strip of tape. It names where the note belongs (or, collapsed, shows its first line). A click
/// collapses the note into it or brings it back out; holding it (or a right-click) opens it from its centre
/// into the five colours and delete, with where the note belongs on a second row; dragging it carries the note.
///
/// The view keeps one size, with room for the capsule to overshoot as it springs open; the capsule is a
/// layer inside it, and only the capsule takes the pointer.
@MainActor
final class NoteIslandView: NSView {
    static let size = CGSize(width: 88, height: 26)
    /// What the rows draw across: the dots, the ✨ slot, the hairline and the trash.
    static let rowWidth: CGFloat = 251
    /// Open: two 32pt rows 8pt apart, as wide as the rows, with 12pt all round.
    static let openSize = CGSize(width: rowWidth + 24, height: 96)

    /// Open, the island is two rows tall: a rounded rectangle rather than a capsule, its corners concentric
    /// with the rows' (16pt radius, 12pt in).
    private static let openCornerRadius: CGFloat = 28
    /// The view: the open capsule plus room for its spring to overshoot.
    static let frameSize = CGSize(width: openSize.width + 40, height: openSize.height + 12)

    /// What the island offers about AI notes.
    enum AIControls: Equatable {
        case none
        /// A note that can still become its conversation's AI note: the ✨ button.
        case convert
        /// An AI note: refresh (when a model is there) instead of the colours, and turning it back.
        case aiNote(canRefresh: Bool)
    }
    /// How long a press must last to open the island instead of toggling the note.
    private static let holdDuration: TimeInterval = 0.42

    var onToggle: (() -> Void)?
    var onDrag: ((PressTracker.Event) -> Void)?
    var onPickColor: ((NoteColor) -> Void)?
    var onDelete: (() -> Void)?
    /// The scopes the note can have now, read each time the island opens.
    var scopeOptions: (() -> [ScopeOption])?
    var onPickScope: ((BindingScope) -> Void)?
    /// While open, a press elsewhere on this note closed it; that press shouldn't also act on the paper.
    /// Carries the press's timestamp, which tells that press apart from later ones.
    var onClosedByPressOnNote: ((TimeInterval) -> Void)?
    /// The island opened or closed; the capsule now covers a different part of the note.
    var onOpenChange: (() -> Void)?
    var onMakeAI: (() -> Void)?
    var onRefreshAI: (() -> Void)?
    var onMakeOrdinary: (() -> Void)?
    private var aiControls = AIControls.none
    private let refreshButton = IslandButton()
    /// "轉成 AI 便利貼", after the dots, on every ordinary note: dimmed, as macOS shows a control that can't be
    /// used, until the note is on a conversation that can have an AI note.
    private let aiButton = IslandButton()
    /// On an AI note: "轉成一般便利貼".
    private let ordinaryButton = IslandButton()
    /// On dark paper the black capsule needs its light rim, as on a dark window.
    var isOnDarkPaper = false {
        didSet { if isOnDarkPaper != oldValue { viewDidChangeEffectiveAppearance() } }
    }

    private(set) var isOpen = false
    private let capsule = CALayer()
    /// The capsule's shape again, clipping what each content view shows, so the contents are revealed as
    /// the capsule grows (Y5's `overflow: hidden`).
    private let pillMask = CALayer()
    private let pickerMask = CALayer()
    private let pill = NSStackView()
    private let icon = NSImageView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    /// Both rows of the open island.
    private let picker = NSStackView()
    private let paletteRow = NSStackView()
    private let scopeRow = ScopeSegments()
    private var swatches: [IslandButton] = []
    private let deleteButton = IslandButton()
    private var tracker = PressTracker()
    private var holdTimer: Timer?
    private var didHold = false
    private var outsideMonitors: [Any] = []

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.frameSize))
        layerUsesCoreImageFilters = true
        wantsLayer = true
        layer?.masksToBounds = false
        capsule.backgroundColor = NSColor(white: 0.114, alpha: 1).cgColor
        capsule.cornerCurve = .continuous
        capsule.shadowColor = NSColor.black.cgColor
        capsule.shadowOpacity = 0.22
        capsule.shadowRadius = 3
        capsule.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(capsule)
        for mask in [pillMask, pickerMask] {
            mask.backgroundColor = NSColor.black.cgColor
            mask.cornerCurve = .continuous
        }

        icon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        icon.contentTintColor = NotePalette.islandInk
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NotePalette.islandInk
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.setViews([icon, dot, label], in: .center)
        pill.spacing = 5
        pill.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        for option in NoteColor.paperColors {
            let swatch = IslandButton()
            swatch.configure(tip: NotePalette.of(option).name, action: #selector(pickColor(_:)), target: self)
            swatch.tag = NoteColor.paperColors.firstIndex(of: option)!
            swatches.append(swatch)
        }
        deleteButton.configure(tip: String(localized: "刪除"), action: #selector(delete), target: self)
        let red = NSColor(srgbRed: 1, green: 0.41, blue: 0.38, alpha: 1)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "刪除"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [red])))
        deleteButton.fill = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 0.22)
        deleteButton.hoverFill = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 0.34)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        // 22pt dots 10pt apart (each button is 32pt so the selection ring fits), then a hairline and the
        // trash, 12pt either side. The dots' buttons have room for a ring on both sides, the trash on
        // neither: the row is padded on the right so what is drawn is centred.
        refreshButton.configure(tip: String(localized: "更新 AI 摘要"), action: #selector(refreshAI), target: self)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "更新 AI 摘要"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [NotePalette.islandInk])))
        refreshButton.fill = NSColor(white: 1, alpha: 0.12)
        refreshButton.hoverFill = NSColor(white: 1, alpha: 0.2)
        refreshButton.isHidden = true
        aiButton.configure(tip: String(localized: "轉成 AI 便利貼"), action: #selector(makeAI), target: self)
        aiButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: String(localized: "轉成 AI 便利貼"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(srgbRed: 0.78, green: 0.65, blue: 1, alpha: 1)])))
        aiButton.fill = NSColor(white: 1, alpha: 0.12)
        aiButton.hoverFill = NSColor(white: 1, alpha: 0.2)
        aiButton.alphaValue = IslandButton.dimmed
        aiButton.isEnabled = false
        ordinaryButton.configure(tip: String(localized: "轉成一般便利貼"), action: #selector(makeOrdinary), target: self)
        ordinaryButton.image = Self.symbol("note.text", tip: String(localized: "轉成一般便利貼"))
        ordinaryButton.fill = NSColor(white: 1, alpha: 0.12)
        ordinaryButton.hoverFill = NSColor(white: 1, alpha: 0.2)
        ordinaryButton.isHidden = true
        paletteRow.setViews(swatches + [refreshButton, ordinaryButton, aiButton, divider, deleteButton], in: .center)
        paletteRow.spacing = 0
        paletteRow.setCustomSpacing(7, after: swatches.last!)
        paletteRow.setCustomSpacing(8, after: refreshButton)
        paletteRow.setCustomSpacing(12, after: ordinaryButton)
        paletteRow.setCustomSpacing(12, after: aiButton)
        paletteRow.setCustomSpacing(12, after: divider)
        paletteRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 5)
        scopeRow.onPick = { [weak self] scope in self?.onPickScope?(scope) }
        // Below the dots, as wide and as tall as what the row above draws.
        picker.orientation = .vertical
        picker.alignment = .centerX
        picker.spacing = 8
        picker.setViews([paletteRow, scopeRow], in: .center)
        picker.isHidden = true

        for content in [pill, picker] {
            content.translatesAutoresizingMaskIntoConstraints = false
            content.wantsLayer = true
            content.layerUsesCoreImageFilters = true
            addSubview(content)
        }
        pill.layer?.mask = pillMask
        picker.layer?.mask = pickerMask
        setCapsule(Self.size, animated: false)
        NSLayoutConstraint.activate([
            // The pill fills the closed capsule and truncates.
            pill.widthAnchor.constraint(equalToConstant: Self.size.width),
            pill.heightAnchor.constraint(equalToConstant: Self.size.height),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            scopeRow.widthAnchor.constraint(equalToConstant: Self.rowWidth),
            scopeRow.heightAnchor.constraint(equalToConstant: ScopeSegments.height),
        ])
        setAccessibilityRole(.button)
        viewDidChangeEffectiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What the island says: where the note belongs, or (collapsed) the note's first line.
    func show(scope: ScopeLabel, firstLine: String, color: NoteColor, collapsed: Bool, ai: AIControls = .none) {
        if ai != aiControls { showAIControls(ai) }
        let (symbol, full) = scope.display
        let text = collapsed ? (firstLine.isEmpty ? String(localized: "便利貼") : firstLine) : scope.short
        let changed = label.stringValue != text || icon.isHidden != collapsed
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.isHidden = collapsed
        dot.isHidden = !collapsed
        dot.layer?.backgroundColor = NotePalette.of(color).paperBottom.cgColor
        label.stringValue = text
        // New words come in the way the island's contents do (it is settled already on first showing).
        if changed, !pill.isHidden, window != nil { Self.blurIn(pill, delay: 0, duration: 0.22) }
        toolTip = collapsed ? String(localized: "\(text)：按一下展開，按住設定") : String(localized: "\(full)：按一下收合，按住設定")
        setAccessibilityLabel(toolTip)
        // A scope just picked: the row follows.
        if isOpen { scopeRow.show(scopeOptions?() ?? []) }
        for (index, swatch) in swatches.enumerated() {
            let option = NoteColor.paperColors[index]
            swatch.image = NotePalette.of(option).swatch(diameter: IslandButton.circle, selected: option == color)
            swatch.setAccessibilityValue(option == color ? String(localized: "已選取") : nil)
        }
    }

    /// AI notes have one colour and stay on their conversation, so their colours and scope row make way for
    /// refreshing and turning back into an ordinary note; an ordinary note that can
    /// become its conversation's AI note shows the ✨.
    private func showAIControls(_ ai: AIControls) {
        aiControls = ai
        let isAINote: Bool
        if case .aiNote(let canRefresh) = ai {
            isAINote = true
            refreshButton.isHidden = !canRefresh
        } else {
            isAINote = false
            refreshButton.isHidden = true
        }
        swatches.forEach { $0.isHidden = isAINote }
        scopeRow.isHidden = isAINote
        ordinaryButton.isHidden = !isAINote
        // The ✨ is on every ordinary note, dimmed where the note can't become an AI note.
        aiButton.isHidden = isAINote
        let offersAI = ai == .convert
        aiButton.toolTip = offersAI ? String(localized: "轉成 AI 便利貼")
                                    : String(localized: "貼在 Claude 對話上的便利貼才能轉成 AI 便利貼（每個對話一張）")
        if aiButton.isEnabled != offersAI {
            aiButton.isEnabled = offersAI
            NSAnimationContext.runAnimationGroup { context in
                context.duration = isOpen ? 0.2 : 0
                aiButton.animator().alphaValue = offersAI ? 1 : IslandButton.dimmed
            }
        }
        if isOpen { setCapsule(openSize, animated: true) }
    }

    /// An AI note's island is one row; any other has its scope row too.
    private var openSize: CGSize {
        // An AI note's one row of actions (it has one colour and stays on its conversation), as wide as they draw.
        if case .aiNote = aiControls {
            paletteRow.layoutSubtreeIfNeeded()
            return CGSize(width: paletteRow.fittingSize.width + 24, height: 56)
        }
        return Self.openSize
    }

    /// A symbol in the island's ink, for its round buttons.
    private static func symbol(_ name: String, tip: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [NotePalette.islandInk])))
    }

    /// Where the capsule is (its resting size, not mid-spring), in this view's coordinates.
    var capsuleRect: NSRect {
        let size = isOpen ? openSize : Self.size
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        capsule.position = centre
        pillMask.position = pill.convert(centre, from: self)
        pickerMask.position = picker.convert(centre, from: self)
        CATransaction.commit()
    }

    /// On a dark window the black island would vanish into it; a faint light rim keeps its outline, the way
    /// macOS rims its own dark surfaces.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = isOnDarkPaper || effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        capsule.borderWidth = dark ? 1 : 0
        capsule.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(capsuleRect, cursor: .arrow)
    }

    /// Only the capsule takes the pointer. Closed, it is one control; open, its swatches and trash take
    /// their own clicks. Faded away (as a deleted note leaves) it takes none.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard layer?.opacity != 0, capsuleRect.contains(convert(point, from: superview)) else { return nil }
        return isOpen ? super.hitTest(point) ?? self : self
    }

    // MARK: Pressing

    override func mouseDown(with event: NSEvent) {
        // Open, a click on the island between its controls closes it again.
        guard !isOpen else {
            setOpen(false)
            return
        }
        tracker.down(event)
        didHold = false
        setScale(0.93, settling: false)
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.charge() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isOpen else { return }
        let events = tracker.dragged(event)
        if !events.isEmpty, !didHold {
            holdTimer?.invalidate()
            setScale(1, settling: true)
        }
        events.forEach { onDrag?($0) }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if !didHold { setScale(1, settling: true) }
        // Always ends the press, even one that opened the island, so the next drag starts afresh.
        let release = tracker.up()
        guard !isOpen else { return }
        switch release {
        case .ended: onDrag?(.ended)
        case .click: if !didHold { onToggle?() }
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        setOpen(true)
    }

    /// Held long enough, the island swells a little, then opens and settles.
    private func charge() {
        didHold = true
        setScale(1.06, settling: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            setScale(1, settling: true)
            setOpen(true)
        }
    }

    /// The whole island scales about its centre: pressed it gives, held it swells. `settling` springs.
    private func setScale(_ scale: CGFloat, settling: Bool) {
        guard let layer else { return }
        let target = CATransform3D.scaling(scale, scale, about: CGPoint(x: bounds.midX, y: bounds.midY))
        let animation: CABasicAnimation
        if settling {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping = 14
            spring.stiffness = 420
            spring.duration = spring.settlingDuration
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "transform")
            animation.duration = 0.12
        }
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        layer.add(animation, forKey: "press")
        layer.transform = target
    }

    // MARK: Opening

    /// Opens from the island's centre into the colours and delete; any click outside closes it.
    /// The capsule springs to its new size; what it held goes at once, and what it now holds comes in
    /// from a blur.
    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open { scopeRow.show(scopeOptions?() ?? []) }
        setCapsule(open ? openSize : Self.size, animated: true)
        (open ? pill : picker).isHidden = true
        Self.blurIn(open ? picker : pill, delay: open ? 0.05 : 0, duration: 0.28)
        window?.invalidateCursorRects(for: self)
        onOpenChange?()
        if open { watchOutsideClicks() } else { stopWatchingOutsideClicks() }
    }

    /// The capsule's size (and the masks' with it), springing with a little overshoot when animated, as
    /// the island grows and shrinks.
    private func setCapsule(_ size: CGSize, animated: Bool) {
        for shape in [capsule, pillMask, pickerMask] { Self.set(shape, to: size, animated: animated) }
    }

    private static func set(_ capsule: CALayer, to size: CGSize, animated: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        let radius = min(size.height / 2, openCornerRadius)
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            capsule.bounds = bounds
            capsule.cornerRadius = radius
            CATransaction.commit()
            return
        }
        let grow = CASpringAnimation(keyPath: "bounds")
        let opening = size.width > (capsule.presentation() ?? capsule).bounds.width
        if opening {
            // Opening, Y5's curve: past the target at about 0.11 s, 16% over at 0.17 s.
            grow.damping = 21
            grow.stiffness = 450
        } else {
            // Closing snaps shut without bouncing back out.
            grow.damping = 44
            grow.stiffness = 600
        }
        grow.duration = grow.settlingDuration
        grow.fromValue = capsule.presentation()?.bounds ?? capsule.bounds
        grow.toValue = bounds
        let round = CABasicAnimation(keyPath: "cornerRadius")
        round.fromValue = capsule.presentation()?.cornerRadius ?? capsule.cornerRadius
        round.toValue = radius
        round.duration = opening ? 0.45 : 0.2
        round.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        capsule.add(grow, forKey: "grow")
        capsule.add(round, forKey: "round")
        capsule.bounds = bounds
        capsule.cornerRadius = radius
    }

    /// Comes into view from slightly small and out of focus.
    private static func blurIn(_ view: NSView, delay: CFTimeInterval, duration: CFTimeInterval) {
        view.isHidden = false
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { return }
        let start = CACurrentMediaTime() + delay
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        CATransaction.begin()
        // The filter goes once the blur has cleared, so resting contents aren't drawn through it.
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                if layer.animation(forKey: "filters.blur.inputRadius") == nil { layer.filters = nil }
            }
        }
        layer.filters = [blur]
        let animations: [(String, Any, Any)] = [
            ("opacity", 0, 1),
            ("transform", CATransform3D.scaling(0.86, 0.86, about: centre), CATransform3DIdentity),
            ("filters.blur.inputRadius", 6, 0),
        ]
        for (keyPath, from, to) in animations {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = start
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.fillMode = .backwards
            layer.add(animation, forKey: keyPath)
        }
        CATransaction.commit()
    }

    /// As its note is deleted: the island shrinks, blurs and fades away.
    func vanish(completion: @escaping @MainActor () -> Void) {
        dismiss()
        guard let layer else { return completion() }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(6, forKey: kCIInputRadiusKey)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let animations: [(String, Any, Any)] = [
            ("opacity", 1, 0),
            ("transform", layer.presentation()?.transform ?? layer.transform, CATransform3D.scaling(0.4, 0.4, about: centre)),
            ("filters.blur.inputRadius", 0, 6),
        ]
        layer.filters = [blur]
        for (keyPath, from, to) in animations {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 0.35
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(animation, forKey: keyPath)
        }
        layer.opacity = 0
        layer.transform = CATransform3D.scaling(0.4, 0.4, about: centre)
        CATransaction.commit()
    }

    /// Back in view after `vanish`, for a note shown again.
    func reappear() {
        guard let layer, layer.opacity == 0 else { return }
        layer.removeAllAnimations()
        layer.filters = nil
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
    }

    private func watchOutsideClicks() {
        stopWatchingOutsideClicks()
        let close: () -> Void = { [weak self] in self?.setOpen(false) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.window, point = event.locationInWindow, time = event.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                let local = self.convert(point, from: nil)
                guard window != self.window || !self.capsuleRect.contains(local) else { return }
                close()
                if window == self.window { self.onClosedByPressOnNote?(time) }
            }
            return event
        }) { outsideMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { close() }
        }) { outsideMonitors.append(global) }
    }

    /// Closes the island and drops a pending hold, so no monitor or timer outlives the note on screen.
    func dismiss() {
        holdTimer?.invalidate()
        setOpen(false)
    }

    private func stopWatchingOutsideClicks() {
        outsideMonitors.forEach(NSEvent.removeMonitor)
        outsideMonitors = []
    }

    @objc private func pickColor(_ sender: IslandButton) {
        sender.pop()
        onPickColor?(NoteColor.paperColors[sender.tag])
    }

    @objc private func delete() {
        onDelete?()
    }

    @objc private func refreshAI() {
        setOpen(false)
        onRefreshAI?()
    }

    @objc private func makeAI() {
        setOpen(false)
        onMakeAI?()
    }

    @objc private func makeOrdinary() {
        setOpen(false)
        onMakeOrdinary?()
    }
}

/// A round button on the island, drawn by hand so nothing of a bezel crops it: a colour dot or the trash.
/// Under the pointer it grows a little, the way the island's controls answer.
@MainActor
final class IslandButton: NSControl {
    static let side: CGFloat = 32
    /// Every round thing on the island is this wide: the colour dots and the buttons' backings alike (a
    /// picked dot's ring fills the 32pt button).
    static let circle: CGFloat = 26
    /// How faint a button is while it can't be used.
    static let dimmed: CGFloat = 0.3
    var image: NSImage? { didSet { needsDisplay = true } }
    /// With a title the button is a capsule, its symbol then the words, as wide as they need.
    var title: String? {
        didSet {
            needsDisplay = true
            widthConstraint?.constant = title.map { Self.capsuleWidth($0, image: image) } ?? Self.side
        }
    }
    private var widthConstraint: NSLayoutConstraint?
    private static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    private static func capsuleWidth(_ title: String, image: NSImage?) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: titleFont]).width
        return ceil((image?.size.width ?? 0) + 5 + text + 2 * 10)
    }
    /// A round backing behind the image (the trash's tint); none for colour dots.
    var fill: NSColor? { didSet { needsDisplay = true } }
    var hoverFill: NSColor?
    private var isHovering = false { didSet { needsDisplay = true; grow(isHovering) } }

    func configure(tip: String, action: Selector, target: AnyObject) {
        wantsLayer = true
        self.target = target
        self.action = action
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.side)
        widthConstraint?.isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let backing = NSRect(x: title == nil ? (bounds.width - Self.circle) / 2 : 0, y: (bounds.height - Self.circle) / 2,
                             width: title == nil ? Self.circle : bounds.width, height: Self.circle)
        if let color = isHovering ? hoverFill ?? fill : fill {
            color.setFill()
            NSBezierPath(roundedRect: backing, xRadius: Self.circle / 2, yRadius: Self.circle / 2).fill()
        }
        let imageSize = image?.size ?? .zero
        guard let title else {
            image?.draw(in: NSRect(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2,
                                   width: imageSize.width, height: imageSize.height))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: NotePalette.islandInk]
        let textSize = (title as NSString).size(withAttributes: attributes)
        var x = (bounds.width - (imageSize.width + 5 + textSize.width)) / 2
        image?.draw(in: NSRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        x += imageSize.width + 5
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
    }

    override func accessibilityPerformPress() -> Bool {
        isEnabled && sendAction(action, to: target)
    }

    /// A quick swell as the colour is picked.
    func pop() {
        guard let layer else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let pop = CAKeyframeAnimation(keyPath: "transform")
        pop.values = [layer.transform, CATransform3D.scaling(1.3, 1.3, about: centre), layer.transform]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.35
        layer.add(pop, forKey: "pop")
    }

    private func grow(_ grown: Bool) {
        guard let layer else { return }
        let scale: CGFloat = grown ? (fill == nil ? 1.15 : title == nil ? 1.1 : 1.04) : 1
        let target = CATransform3D.scaling(scale, scale, about: CGPoint(x: bounds.midX, y: bounds.midY))
        let spring = CASpringAnimation(keyPath: "transform")
        spring.damping = 14
        spring.stiffness = 380
        spring.duration = spring.settlingDuration
        spring.fromValue = layer.presentation()?.transform ?? layer.transform
        spring.toValue = target
        layer.add(spring, forKey: "hover")
        layer.transform = target
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // A button that can't be used doesn't answer the pointer.
    override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}

/// The island's second row: where the note belongs, as a segmented control of what the window offers
/// (conversation, folder or document, the whole window) and floating. Each choice is its symbol; the
/// current one widens to say its name too, and the choice slides across when another is picked.
@MainActor
final class ScopeSegments: NSView {
    static let height: CGFloat = 32
    /// An unpicked choice: just its symbol.
    fileprivate static let narrowWidth: CGFloat = 36
    fileprivate static let inset: CGFloat = 2
    var onPick: ((BindingScope) -> Void)?
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        stack.distribution = .fill
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "貼在哪裡"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ options: [ScopeOption]) {
        let segments = stack.arrangedSubviews.compactMap { $0 as? ScopeSegment }
        // The same choices as before: the picked one slides over.
        if segments.map(\.scope) == options.map(\.scope), window != nil, !isHiddenOrHasHiddenAncestor {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.3, 1)
                context.allowsImplicitAnimation = true
                for (segment, option) in zip(segments, options) { segment.configure(option, animated: true) }
                layoutSubtreeIfNeeded()
            }
            return
        }
        stack.setViews(options.map { option in
            let segment = ScopeSegment(scope: option.scope)
            segment.configure(option, animated: false)
            segment.onPick = { [weak self] in self?.onPick?(option.scope) }
            return segment
        }, in: .leading)
        layoutSubtreeIfNeeded()
    }
}

/// One choice in `ScopeSegments`: its symbol, and its name while it is the current one, on a lighter pill.
@MainActor
final class ScopeSegment: NSView {
    let scope: BindingScope
    var onPick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private lazy var narrow = widthAnchor.constraint(equalToConstant: ScopeSegments.narrowWidth)
    private var isCurrent = false
    private var isHovering = false { didSet { paint(animated: true) } }

    init(scope: BindingScope) {
        self.scope = scope
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = (ScopeSegments.height - 2 * ScopeSegments.inset) / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(views: [icon, label])
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
        // The current one takes what the narrow ones leave.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ option: ScopeOption, animated: Bool) {
        let (symbol, full) = option.label.display
        let name = Self.name(of: option.label)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        label.stringValue = name
        toolTip = full
        setAccessibilityLabel(full)
        setAccessibilityValue(option.isCurrent)
        guard option.isCurrent != isCurrent || !animated else { return }
        isCurrent = option.isCurrent
        narrow.isActive = !isCurrent
        label.isHidden = !isCurrent
        if isCurrent, animated {
            // The name comes in as the pill widens.
            label.alphaValue = 0
            label.animator().alphaValue = 1
        } else {
            label.alphaValue = 1
        }
        paint(animated: animated)
    }

    private func paint(animated: Bool) {
        let ink = NotePalette.islandInk.withAlphaComponent(isCurrent || isHovering ? 1 : 0.6)
        icon.contentTintColor = ink
        label.textColor = ink
        let fill = NSColor(white: 1, alpha: isCurrent ? 0.2 : isHovering ? 0.08 : 0).cgColor
        guard let layer else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = fill
            fade.duration = 0.2
            layer.add(fade, forKey: "fill")
        }
        layer.backgroundColor = fill
    }

    /// What the choice is called, in a word or two; the tooltip says which conversation, folder or window.
    private static func name(of label: ScopeLabel) -> String {
        switch label {
        case .conversation: String(localized: "對話")
        case .document(_, _, isFolder: true): String(localized: "資料夾")
        case .document: String(localized: "文件")
        case .webPage: String(localized: "網頁")
        case .window, .windowFallback, .webPageFallback: String(localized: "整個視窗")
        case .floating: String(localized: "浮動")
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole pill is one control; its symbol and name don't take the click. Hidden (on an AI note), none.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHiddenOrHasHiddenAncestor && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)), !isCurrent { onPick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        if !isCurrent { onPick?() }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}

extension ScopeLabel {
    /// A few words for the island: the place's own name.
    var short: String {
        switch self {
        case .floating: String(localized: "浮動")
        case .window(let appName, let title): title.isEmpty ? appName : title
        case .windowFallback, .webPageFallback: String(localized: "整個視窗")
        case .document(_, let name, _): name
        case .webPage(let title, let address): title.isEmpty ? URL(string: address)?.host ?? address : title
        case .conversation(let title): title.isEmpty ? String(localized: "Claude 對話") : title
        }
    }

    /// The SF Symbol and words for what a note is bound to.
    var display: (symbol: String, text: String) {
        switch self {
        case .floating: ("pin", String(localized: "浮動"))
        case .window(let appName, let title):
            ("macwindow", title.isEmpty ? String(localized: "視窗：\(appName)") : String(localized: "視窗：\(appName) — \(title)"))
        case .windowFallback(let appName, let title):
            ("macwindow", title.isEmpty ? String(localized: "視窗（認不出對話）：\(appName)") : String(localized: "視窗（認不出對話）：\(appName) — \(title)"))
        case .document(_, let name, isFolder: true): ("folder", String(localized: "資料夾：\(name)"))
        case .document(_, let name, isFolder: false): ("doc", String(localized: "文件：\(name)"))
        case .conversation(let title): ("bubble.left", title.isEmpty ? String(localized: "Claude 對話") : String(localized: "Claude 對話：\(title)"))
        case .webPage(let title, let address):
            ("globe", title.isEmpty ? String(localized: "網頁：\(address)") : String(localized: "網頁：\(title) — \(address)"))
        case .webPageFallback(let appName, let title):
            ("macwindow", title.isEmpty ? String(localized: "視窗（這一頁不能貼）：\(appName)") : String(localized: "視窗（這一頁不能貼）：\(appName) — \(title)"))
        }
    }
}


extension CATransform3D {
    /// Scales about `point`: AppKit anchors a view's layer at its corner, so a plain scale would pull
    /// toward it.
    static func scaling(_ x: CGFloat, _ y: CGFloat, about point: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(point.x, point.y, 0)
        transform = CATransform3DScale(transform, x, y, 1)
        return CATransform3DTranslate(transform, -point.x, -point.y, 0)
    }
}
