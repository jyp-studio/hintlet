import AppKit
import QuartzCore
import StickyContextCore

/// A sticky note that floats above other apps without activating Hintlet.
///
/// Picking a note up to drag it lifts it the way macOS and iPadOS lift dragged objects: it grows
/// slightly and its shadow deepens; dropping it settles it back. The window is transparent and
/// larger than the note so the shadow has room.
@MainActor
final class NotePanel: NSPanel, NSTextViewDelegate {
    /// Room around the paper for its shadow and for the open island, which is wider than a narrow note.
    private static let margin: CGFloat = 72

    private let lift = NoteLiftView()
    private let card = NoteCardView()
    private let island = NoteIslandView()
    private var shown: DisplayedNote?
    /// Whether the paper is shown collapsed into the island right now (it may lag the model while it
    /// animates).
    private var showsCollapsed = false
    /// Deleting: the paper and island are leaving, and model updates no longer move them.
    private var isDeleting = false
    private var noteSize: CGSize = .zero
    /// The window the note is bound to (nil when floating).
    private(set) var windowID: WindowID?
    private var hasPlacedOnSpaces = false
    private let onTextChange: (String) -> Void
    private let onMove: (CGPoint) -> Void
    private let onFinishEditing: () -> Void
    /// Editing ended, by Esc or by clicking elsewhere.
    var onEndEditing: (() -> Void)?
    /// The user resized the note from one of its edges.
    var onSetFrame: ((CGRect) -> Void)?
    var onSetColor: ((NoteColor) -> Void)?
    var onSetCollapsed: ((Bool) -> Void)?
    var onDelete: (() -> Void)?
    /// The scopes the note can have now, for the island's second row.
    var scopeOptions: (() -> [ScopeOption])? {
        get { island.scopeOptions }
        set { island.scopeOptions = newValue }
    }
    var onSetScope: ((BindingScope) -> Void)?
    /// "✨ 讓 AI 記錄脈絡？" or "轉成 AI 便利貼".
    var onMakeAI: (() -> Void)?
    var onRefreshAI: (() -> Void)?
    var onMakeOrdinary: (() -> Void)?
    /// What the note's right-click menu offers above cutting, copying and pasting.
    var noteMenuItems: (() -> [NSMenuItem])?
    /// Whether an AI note can be refreshed here (a model is available).
    var canRefreshAI: () -> Bool = { false }
    private var isLiveResizing = false
    private var resizeStartMouse: NSPoint = .zero
    private var resizeStartFrame: CGRect = .zero
    private var resizeEdges: NoteCardView.Edges = []
    private var isApplyingModel = false
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero

    init(onTextChange: @escaping (String) -> Void, onMove: @escaping (CGPoint) -> Void,
         onFinishEditing: @escaping () -> Void) {
        self.onTextChange = onTextChange
        self.onMove = onMove
        self.onFinishEditing = onFinishEditing
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        // The note draws its own shadow: the window server's adds a dark hairline rim that makes the
        // paper read as a window.
        hasShadow = false
        // Appearing and disappearing are animated here; the system's own zoom would add a second one.
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        // Notes aren't windows to the user: the 視窗 menu lists only the list and the settings.
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true

        let root = NSView()
        card.autoresizingMask = [.width, .height]
        lift.addSubview(card)
        root.addSubview(lift)
        root.addSubview(island)
        contentView = root
        island.onToggle = { [weak self] in self?.toggleCollapsed() }
        island.onDrag = { [weak self] event in self?.handleDrag(event) }
        island.onPickColor = { [weak self] color in self?.onSetColor?(color) }
        island.onDelete = { [weak self] in self?.delete() }
        island.onPickScope = { [weak self] scope in self?.onSetScope?(scope) }
        island.onOpenChange = { [weak self] in self?.layOutIsland() }
        island.onClosedByPressOnNote = { [weak self] time in self?.card.ignoreClick(ofPressAt: time) }
        island.onMakeAI = { [weak self] in self?.makeAI() }
        island.onRefreshAI = { [weak self] in self?.onRefreshAI?() }
        island.onMakeOrdinary = { [weak self] in self?.onMakeOrdinary?() }
        card.onMakeAI = { [weak self] in self?.makeAI() }

        card.textView.delegate = self
        card.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        card.onClick = { [weak self] point in
            guard let self else { return }
            // An AI note is read-only.
            if shown?.ai == nil { beginEditing(at: point) }
        }
        card.onResize = { [weak self] phase in self?.handleResize(phase) }
        card.setEditing(false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        center.addObserver(self, selector: #selector(didResignKey), name: NSWindow.didResignKeyNotification, object: self)
    }

    #if DEBUG
    /// For looking at the open island's design (`-previewIsland`).
    func debugOpenIsland() { island.setOpen(true) }
    #endif

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A right-click on the paper shows the note's actions; one on the island opens it as before, and one on
    /// text being typed adds them to the text's own menu (`textView(_:menu:for:at:)`).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, !card.isEditing, let contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)),
           !hit.isDescendant(of: island), hit.isDescendant(of: card),
           let items = noteMenuItems?(), !items.isEmpty {
            makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            items.forEach(menu.addItem)
            NSMenu.popUpContextMenu(menu, with: event, for: card)
            return
        }
        super.sendEvent(event)
    }

    /// Lays the panel out for `note`; whether it is on screen is up to `reveal` and `conceal`.
    func update(_ note: DisplayedNote) {
        // Mid-resize the panel follows the pointer; the model catches up when the user lets go.
        guard !isLiveResizing, !isDeleting else { return }
        isApplyingModel = true
        defer { isApplyingModel = false }
        let previous = shown
        shown = note
        let windowFrame = note.frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        if frame != windowFrame {
            setFrame(windowFrame, display: true)
        }
        if noteSize != note.frame.size { layOut(noteSize: note.frame.size) }
        if showsCollapsed != note.isCollapsed || previous == nil {
            // Collapsing into the island and coming back out animate; a note that just appeared doesn't.
            showCollapsed(note.isCollapsed, animated: previous != nil)
        }
        if previous?.color != note.color {
            // A new colour spreads out from the island.
            card.show(note.color, ripplingFrom: previous == nil ? nil : NSPoint(x: noteSize.width / 2, y: noteSize.height))
        }
        card.showAI(note.ai, offering: note.offersAI)
        if note.ai == nil, card.textView.string != note.text { card.setText(note.text) }
        let ai: NoteIslandView.AIControls = if note.ai != nil {
            .aiNote(canRefresh: canRefreshAI())
        } else {
            note.canBecomeAI ? .convert : .none
        }
        island.isOnDarkPaper = NotePalette.of(note.color).isDark
        island.show(scope: note.scopeLabel, firstLine: Self.firstLine(of: note.text), color: note.color,
                    collapsed: note.isCollapsed, ai: ai)
        island.reappear()
        if windowID != note.windowID || !hasPlacedOnSpaces {
            hasPlacedOnSpaces = true
            windowID = note.windowID
            // A floating note is on every desktop, and holds still while they slide past (so switching quickly
            // between full-screen apps doesn't keep waiting for each slide to end before drawing it). A
            // window's note lives on the desktop it is shown on, so it slides away with that desktop on a
            // trackpad swipe instead of hanging over the next one.
            collectionBehavior = note.windowID == nil
                ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                : [.moveToActiveSpace, .fullScreenAuxiliary]
        }
    }

    /// The paper for a note of `size`, with the island centred on its top edge.
    private func layOut(noteSize size: CGSize) {
        noteSize = size
        setLiftFrame(NSRect(x: Self.margin, y: Self.margin, width: size.width, height: size.height))
        layOutIsland()
    }

    /// Centred on the note's top edge, half on the paper and half above it. The paper leaves to the island
    /// whatever its capsule covers, open or closed.
    private func layOutIsland() {
        let size = NoteIslandView.frameSize
        island.frame = NSRect(x: Self.margin + noteSize.width / 2 - size.width / 2,
                              y: Self.margin + noteSize.height - size.height / 2,
                              width: size.width, height: size.height)
        card.islandRect = card.convert(island.convert(island.capsuleRect, to: island.superview), from: island.superview)
    }

    // MARK: Collapsing into the island

    private static let collapseDuration: CFTimeInterval = 0.16

    /// Collapsed, the paper goes into the island: it shrinks toward it, blurring and fading; coming back
    /// out it grows from the island with a spring. `completion` runs only if nothing reversed it meanwhile.
    private func showCollapsed(_ collapsed: Bool, animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        showsCollapsed = collapsed
        card.setCollapsed(collapsed)
        guard let layer = lift.layer else { return }
        // About the middle of the paper's top edge, where the island is (AppKit layers grow upward).
        let top = CGPoint(x: noteSize.width / 2, y: noteSize.height)
        let away = CATransform3DConcat(CATransform3D.scaling(0.3, 0.05, about: top), CATransform3DMakeTranslation(0, 6, 0))
        let toTransform = collapsed ? away : CATransform3DIdentity
        let toOpacity: Float = collapsed ? 0 : 1
        if !collapsed { lift.isHidden = false }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = toTransform
            layer.opacity = toOpacity
            CATransaction.commit()
            lift.isHidden = collapsed
            completion?()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showsCollapsed == collapsed else { return }
                self.lift.isHidden = collapsed
                self.lift.setBlur(0)
                completion?()
            }
        }
        lift.setBlur(collapsed ? 8 : 0, from: collapsed ? 0 : 8,
                     duration: collapsed ? Self.collapseDuration : 0.25)
        let move: CABasicAnimation
        if collapsed {
            move = CABasicAnimation(keyPath: "transform")
            move.duration = Self.collapseDuration
            // Off at once, rather than easing in slowly.
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.3, 1)
        } else {
            let spring = CASpringAnimation(keyPath: "transform")
            // Out quickly, settling without a wobble.
            spring.damping = 30
            spring.stiffness = 400
            spring.duration = spring.settlingDuration
            move = spring
        }
        move.fromValue = layer.presentation()?.transform ?? layer.transform
        move.toValue = toTransform
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = toOpacity
        fade.duration = collapsed ? Self.collapseDuration : 0.14
        layer.add(move, forKey: "collapse")
        layer.add(fade, forKey: "collapseFade")
        layer.transform = toTransform
        layer.opacity = toOpacity
        CATransaction.commit()
    }

    private func setLiftFrame(_ frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.frame = frame
        card.frame = lift.bounds
        lift.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for marker in [Checklist.uncheckedMarker, Checklist.checkedMarker] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return line
    }

    // MARK: AI notes

    /// The note becomes its conversation's AI note; typing in it is over.
    func makeAI() {
        onMakeAI?()
        if card.isEditing {
            endEditing()
            onFinishEditing()
        }
    }

    // MARK: Collapsing and deleting

    func toggleCollapsed() {
        let collapse = !(shown?.isCollapsed ?? false)
        if collapse, card.isEditing { endEditing() }
        onSetCollapsed?(collapse)
    }

    /// The paper goes into the island, then the island itself fades away.
    func delete() {
        guard !isDeleting else { return }
        if card.isEditing {
            endEditing()
            onFinishEditing()
        }
        isDeleting = true
        showCollapsed(true, animated: true) { [weak self] in
            self?.island.vanish { [weak self] in
                guard let self else { return }
                // The panel is kept for the note's return from the trash.
                isDeleting = false
                onDelete?()
            }
        }
    }

    // MARK: Resizing

    private func handleResize(_ phase: NoteCardView.ResizePhase) {
        switch phase {
        case .began(let edges):
            isLiveResizing = true
            resizeEdges = edges
            resizeStartMouse = NSEvent.mouseLocation
            resizeStartFrame = frame.insetBy(dx: Self.margin, dy: Self.margin)
        case .moved:
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - resizeStartMouse.x, dy = mouse.y - resizeStartMouse.y
            let minimum = NoteEngine.minimumNoteSize
            var note = resizeStartFrame
            // Each dragged edge follows the pointer; the opposite edge stays where it is.
            if resizeEdges.contains(.right) { note.size.width = max(resizeStartFrame.width + dx, minimum.width) }
            if resizeEdges.contains(.left) {
                note.size.width = max(resizeStartFrame.width - dx, minimum.width)
                note.origin.x = resizeStartFrame.maxX - note.width
            }
            if resizeEdges.contains(.bottom) {
                note.size.height = max(resizeStartFrame.height - dy, minimum.height)
                note.origin.y = resizeStartFrame.maxY - note.height
            }
            if resizeEdges.contains(.top) { note.size.height = max(resizeStartFrame.height + dy, minimum.height) }
            // Layers follow at once, without the implicit animations that would leave the old paper showing.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isApplyingModel = true
            setFrame(note.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
            isApplyingModel = false
            layOut(noteSize: note.size)
            contentView?.displayIfNeeded()
            CATransaction.commit()
        case .ended:
            isLiveResizing = false
            onSetFrame?(frame.insetBy(dx: Self.margin, dy: Self.margin))
        }
    }

    // MARK: Appearing and disappearing

    private static let fadeInDuration: TimeInterval = 0.15
    private static let stepAsideDuration: TimeInterval = 0.1

    /// Whether the note is meant to be on screen (it may still be fading in or out).
    private(set) var isShown = false
    /// Bumped on every reveal and conceal, so a late animation step from an older one does nothing.
    private var visibilityGeneration = 0

    /// Fades the note in where it belongs.
    func reveal() {
        isShown = true
        visibilityGeneration += 1
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Takes the note off screen: at once when it no longer belongs, or with a quick fade when it is only
    /// stepping aside while its window moves.
    func conceal(animated: Bool) {
        island.dismiss()
        guard isShown else {
            // Left on a desktop that has since come back into view, under a window that isn't focused.
            if !animated, isVisible, isOnActiveSpace { orderOut(nil) }
            return
        }
        isShown = false
        visibilityGeneration += 1
        guard animated else {
            // On a desktop that has slid out of view, the note stays where it is, so a swipe back slides it
            // in together with its window. It's ordered out once that desktop shows and it isn't wanted.
            if isOnActiveSpace { orderOut(nil) }
            return
        }
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.stepAsideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
            }
        })
    }

    /// Starts typing in the note, with the caret where the user clicked (or at the end).
    func beginEditing(at windowPoint: NSPoint? = nil) {
        // An AI note is read-only.
        guard shown?.ai == nil else { return }
        // A new note may be typed in before its fade-in is due; it must count as shown, or it can't be concealed.
        if !isShown {
            isShown = true
        }
        // Cancels a step-aside fade that may be running.
        visibilityGeneration += 1
        alphaValue = 1
        card.setEditing(true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(card.textView)
        if let windowPoint {
            let index = card.textView.characterIndexForInsertion(at: card.textView.convert(windowPoint, from: nil))
            card.textView.setSelectedRange(NSRange(location: index, length: 0))
        }
    }

    private func endEditing() {
        guard card.isEditing else { return }
        makeFirstResponder(nil)
        card.setEditing(false)
        onEndEditing?()
    }

    /// Esc ends editing and gives the keyboard back to the app the user came from.
    /// A right-click on the note: its own actions (they act on the note with the keyboard, so it takes it),
    /// then the text's.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let items = noteMenuItems?(), !items.isEmpty else { return menu }
        makeKeyAndOrderFront(nil)
        let combined = NSMenu()
        items.forEach(combined.addItem)
        if !menu.items.isEmpty {
            combined.addItem(.separator())
            for item in menu.items {
                menu.removeItem(item)
                combined.addItem(item)
            }
        }
        return combined
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endEditing()
        onFinishEditing()
        return true
    }

    /// Clicking anywhere else also ends editing, so the next touch on the note picks it up again.
    @objc private func didResignKey(_ notification: Notification) {
        endEditing()
    }

    func textSizeChanged() {
        card.textSizeChanged()
    }

    func textDidChange(_ notification: Notification) {
        card.applyTypography()
        onTextChange(card.textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        card.updateTypingAttributes()
    }

    @objc private func didMove(_ notification: Notification) {
        guard !isApplyingModel else { return }
        onMove(NSPoint(x: frame.origin.x + Self.margin, y: frame.origin.y + Self.margin))
    }

    // MARK: Carrying the note

    private func handleDrag(_ event: PressTracker.Event) {
        switch event {
        case .began(let pressPoint):
            dragStartMouse = pressPoint
            dragStartOrigin = frame.origin
            if !showsCollapsed {
                card.setSmoothedWhileScaled(true)
                lift.setPickedUp(true)
            }
        case .moved:
            let mouse = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(x: dragStartOrigin.x + mouse.x - dragStartMouse.x,
                                   y: dragStartOrigin.y + mouse.y - dragStartMouse.y))
        case .ended:
            if !showsCollapsed {
                lift.setPickedUp(false) { [weak self] in
                    self?.card.setSmoothedWhileScaled(false)
                }
            }
        case .click:
            break
        }
    }
}

/// Carries the paper together with its shadow, so both lift as one.
///
/// The shadow follows how macOS treats objects rather than windows: a tight contact shadow plus a
/// soft ambient one at rest, and a wider, further-dropped ambient shadow while picked up, when the
/// paper also grows slightly.
@MainActor
private final class NoteLiftView: NSView {
    private struct ShadowPose {
        var contactOpacity: Float, contactRadius: CGFloat, contactDrop: CGFloat
        var ambientOpacity: Float, ambientRadius: CGFloat, ambientDrop: CGFloat
    }

    private static let resting = ShadowPose(contactOpacity: 0.12, contactRadius: 1.5, contactDrop: 1,
                                            ambientOpacity: 0.16, ambientRadius: 10, ambientDrop: 4)
    private static let pickedUp = ShadowPose(contactOpacity: 0.08, contactRadius: 3, contactDrop: 2,
                                             ambientOpacity: 0.26, ambientRadius: 22, ambientDrop: 14)
    private static let cornerRadius: CGFloat = 16

    private let contact = CALayer()

    init() {
        super.init(frame: .zero)
        layerUsesCoreImageFilters = true
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        contact.shadowColor = NSColor.black.cgColor
        layer?.insertSublayer(contact, at: 0)
        apply(Self.resting, duration: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius,
                          transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = path
        contact.frame = bounds
        contact.shadowPath = path
        CATransaction.commit()
    }

    private static let pickedUpScale: CGFloat = 1.03

    /// Blurs the paper as it goes into the island (and clears as it comes out). The filter is there only
    /// while it blurs, so a resting note isn't drawn through it.
    func setBlur(_ radius: CGFloat, from start: CGFloat? = nil, duration: CFTimeInterval = 0) {
        guard let layer else { return }
        guard radius > 0 || start != nil else {
            layer.filters = nil
            return
        }
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        layer.filters = [blur]
        guard let start else { return }
        let animation = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        animation.fromValue = start
        animation.toValue = radius
        animation.duration = duration
        layer.add(animation, forKey: "blur")
    }

    func setPickedUp(_ pickedUp: Bool, completion: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        apply(pickedUp ? Self.pickedUp : Self.resting, duration: pickedUp ? 0.18 : 0.3)
        scale(to: pickedUp ? Self.pickedUpScale : 1, settling: !pickedUp)
        CATransaction.commit()
    }

    /// Scales about the centre (AppKit anchors view layers at the corner). Setting down uses a soft
    /// spring so the paper settles rather than snapping.
    private func scale(to factor: CGFloat, settling: Bool) {
        guard let layer else { return }
        let target = CATransform3D.scaling(factor, factor, about: CGPoint(x: bounds.midX, y: bounds.midY))

        let animation: CABasicAnimation
        if settling {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping = 22
            spring.stiffness = 320
            spring.duration = spring.settlingDuration
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "transform")
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        layer.add(animation, forKey: "transform")
        layer.transform = target
    }

    private func apply(_ pose: ShadowPose, duration: CFTimeInterval) {
        guard let ambient = layer else { return }
        // y grows upward in AppKit layers, so a drop is a negative offset.
        set(ambient, opacity: pose.ambientOpacity, radius: pose.ambientRadius, drop: pose.ambientDrop, duration: duration)
        set(contact, opacity: pose.contactOpacity, radius: pose.contactRadius, drop: pose.contactDrop, duration: duration)
    }

    private func set(_ layer: CALayer, opacity: Float, radius: CGFloat, drop: CGFloat, duration: CFTimeInterval) {
        let targets: [(String, Any)] = [("shadowOpacity", opacity), ("shadowRadius", radius),
                                        ("shadowOffset", CGSize(width: 0, height: -drop))]
        for (key, value) in targets where duration > 0 {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: -drop)
    }
}

/// The paper: one continuous, softly lit yellow surface. The first line reads as the title.
@MainActor
private final class NoteCardView: NSView {
    enum ResizePhase { case began(Edges), moved, ended }

    /// Which edges a resize moves; a corner moves two.
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    /// Along the edges, how far in a press resizes the note.
    private static let edgeGrip: CGFloat = 8
    /// Above the text: room for the half of the island that sits on the paper.
    private static let topMargin: CGFloat = 14

    private var color: NoteColor = .yellow
    private var palette = NotePalette.of(.yellow)
    /// A faint inner rim of light that defines the edge without outlining it.
    private static let edge = NSColor.white.withAlphaComponent(0.45)
    private static let cornerRadius: CGFloat = 16
    /// The corners where two edges resize at once.
    private static let cornerGrip: CGFloat = 12
    private static var bodyFont: NSFont { .systemFont(ofSize: NoteTypography.textSize) }
    private static var titleFont: NSFont { .systemFont(ofSize: NoteTypography.textSize + 1, weight: .semibold) }

    /// TextKit 1: checklist boxes are drawn over its glyph layout.
    let textView = NoteTextView(usingTextLayoutManager: false)
    private var isCollapsed = false
    /// The paper's gradient, drawn by Core Animation so it keeps up with live resizing.
    private let paper = CAGradientLayer()
    /// A hairline of light along the top edge, the way macOS lights its own surfaces.
    private let sheen = CALayer()
    /// The palette's soft patches of colour over the paper.
    private var patches: [CAGradientLayer] = []
    /// Frosted glass in place of the paper, for an AI note in that colour.
    private let material = NSVisualEffectView()
    /// While an AI note is being written: colour glowing in from its edges, turning slowly, over everything.
    /// No outline of its own, as Apple Intelligence glows.
    private let glow = GlowView()
    private let haze = GlowRing(width: 0, softness: 44, opacity: 0.75)
    /// A thin, soft, brighter band right at the edge, the way Siri's glow is brightest there: lit, not drawn.
    private let edgeLight = GlowRing(width: 0, softness: 7, opacity: 0.9, falloff: .band)
    /// Carrying the note; `began` carries where the press started, so the note doesn't lag the pointer.
    var onDrag: ((PressTracker.Event) -> Void)?
    /// A press released without moving: the user wants to type. Carries the point in window coordinates.
    var onClick: ((NSPoint) -> Void)?
    var onResize: ((ResizePhase) -> Void)?
    /// The offer on a new, empty note was taken.
    var onMakeAI: (() -> Void)?
    private(set) var isEditing = false
    /// An AI note's lines, shown instead of editable text.
    private var aiState: DisplayedAI?
    /// "✨ 讓 AI 記錄脈絡？", faint, on a new conversation note until the user types.
    private let offer = NSButton(title: "", target: nil, action: nil)
    /// The island over the top edge, in this view's coordinates: the paper leaves that part to it, for
    /// both pressing and the pointer's shape.
    var islandRect: NSRect = .zero {
        didSet { if islandRect != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// The press that closed the open island; its click shouldn't also start typing or tick a box.
    private var ignoredPressTime: TimeInterval?
    private var pressOnlyClosesIsland = false
    private var tracker = PressTracker()
    private var isResizing = false
    /// Holds the text; rasterized while the note is carried so scaled glyphs are resampled smoothly.
    private let scrollView = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = Self.edge.cgColor
        layer?.allowsEdgeAntialiasing = true
        layer?.addSublayer(paper)
        layer?.addSublayer(sheen)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.isHidden = true
        material.autoresizingMask = [.width, .height]
        addSubview(material, positioned: .below, relativeTo: nil)
        glow.wantsLayer = true
        glow.layerUsesCoreImageFilters = true
        glow.autoresizingMask = [.width, .height]
        glow.alphaValue = 0
        glow.layer?.addSublayer(haze)
        glow.layer?.addSublayer(edgeLight)
        sheen.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true

        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.bodyFont
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        addSubview(scrollView)
        offer.isBordered = false
        offer.translatesAutoresizingMaskIntoConstraints = false
        offer.target = self
        offer.action = #selector(takeOffer)
        offer.alphaValue = 0
        offer.isHidden = true
        offer.setAccessibilityLabel(String(localized: "讓 AI 記錄脈絡？"))
        addSubview(offer)
        // The margin around the text is where the note is picked up.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.topMargin),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            offer.centerXAnchor.constraint(equalTo: centerXAnchor),
            offer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        show(.yellow)
    }

    override func layout() {
        super.layout()
        // Without implicit animations, so the paper never lags behind a resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.frame = bounds
        layOutPatches()
        haze.fit(bounds, cornerRadius: Self.cornerRadius)
        edgeLight.fit(bounds, cornerRadius: Self.cornerRadius)
        material.frame = bounds
        glow.frame = bounds
        if glow.superview == nil { addSubview(glow) }
        sheen.frame = NSRect(x: Self.cornerRadius, y: bounds.maxY - 1, width: max(bounds.width - 2 * Self.cornerRadius, 0), height: 0.5)
        CATransaction.commit()
    }

    /// Collapsed, the paper is tucked into the island and takes no part.
    /// Called as a press on this note closes the open island, before the press arrives here.
    func ignoreClick(ofPressAt time: TimeInterval) { ignoredPressTime = time }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        if collapsed, isEditing { setEditing(false) }
        window?.invalidateCursorRects(for: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glass's shape: the note's rounded corners, stretching with it.
    private static let roundedMask: NSImage = {
        let radius = cornerRadius
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()

    /// One radial layer per patch, just above the paper.
    private func showPatches() {
        while patches.count < palette.patches.count {
            let patch = CAGradientLayer()
            patch.type = .radial
            layer?.insertSublayer(patch, above: paper)
            patches.append(patch)
        }
        for (index, patch) in patches.enumerated() {
            guard palette.patches.indices.contains(index), !palette.usesMaterial else {
                patch.isHidden = true
                continue
            }
            let color = palette.patches[index].color
            patch.isHidden = false
            patch.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        layOutPatches()
    }

    /// Each patch fades out over most of the note from its point, so they blend into each other.
    private func layOutPatches() {
        let reach = max(bounds.width, bounds.height) * 1.1
        for (patch, spec) in zip(patches, palette.patches) {
            patch.frame = CGRect(x: bounds.minX + spec.center.x * bounds.width - reach, y: bounds.minY + spec.center.y * bounds.height - reach,
                                 width: 2 * reach, height: 2 * reach)
            patch.startPoint = CGPoint(x: 0.5, y: 0.5)
            patch.endPoint = CGPoint(x: 1, y: 1)
        }
    }

    /// The glow comes in while the AI writes, turning, and fades when it is done.
    private func showGlow(_ shown: Bool) {
        guard shown != (glow.alphaValue > 0) else { return }
        if shown {
            haze.setTurning(true)
            edgeLight.setTurning(true)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shown ? 0.3 : 0.5
            glow.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !shown, self.glow.alphaValue == 0 else { return }
                self.haze.setTurning(false)
                self.edgeLight.setTurning(false)
            }
        })
    }

    /// `ripplingFrom` (in this view) spreads the new colour out from that point, as a ripple.
    func show(_ color: NoteColor, ripplingFrom origin: NSPoint? = nil) {
        self.color = color
        palette = NotePalette.of(color)
        // Glass follows the system's light or dark; paper keeps its own.
        appearance = palette.usesMaterial ? nil : NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        material.isHidden = !palette.usesMaterial
        material.maskImage = palette.usesMaterial ? Self.roundedMask : nil
        layer?.borderColor = (palette.isDark || palette.usesMaterial ? NSColor.white.withAlphaComponent(palette.usesMaterial ? 0.3 : 0.12)
                                                                     : Self.edge).cgColor
        sheen.backgroundColor = NSColor.white.withAlphaComponent(palette.isDark ? 0.22 : 0.85).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.isHidden = palette.usesMaterial
        sheen.isHidden = palette.usesMaterial
        // Layer gradients run bottom to top in AppKit's unflipped layers: top-left is (0, 1).
        paper.startPoint = palette.diagonal == nil ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 1)
        paper.endPoint = palette.diagonal == nil ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0)
        showPatches()
        CATransaction.commit()
        textView.textColor = palette.ink
        textView.insertionPointColor = palette.ink
        textView.ink = palette.ink
        applyTypography()
        // Layer gradients run bottom to top in AppKit's unflipped layers.
        let colors = palette.diagonal?.map(\.cgColor) ?? [palette.paperBottom.cgColor, palette.paperTop.cgColor]
        guard let origin, let layer else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            paper.colors = colors
            CATransaction.commit()
            return
        }
        let wash = CAGradientLayer()
        wash.frame = bounds
        wash.colors = colors
        layer.insertSublayer(wash, above: paper)
        let mask = CAShapeLayer()
        let reach = hypot(max(origin.x, bounds.width - origin.x), max(origin.y, bounds.height - origin.y))
        let from = CGPath(ellipseIn: CGRect(x: origin.x, y: origin.y, width: 0, height: 0), transform: nil)
        let to = CGPath(ellipseIn: CGRect(x: origin.x - reach, y: origin.y - reach, width: 2 * reach, height: 2 * reach), transform: nil)
        mask.path = to
        wash.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.paper.colors = colors
                wash.removeFromSuperlayer()
                CATransaction.commit()
            }
        }
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = from
        grow.toValue = to
        grow.duration = 0.6
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.3, 1)
        mask.add(grow, forKey: "ripple")
        CATransaction.commit()
    }

    func setText(_ text: String) {
        textView.string = text
        applyTypography()
    }

    /// An AI note shows its summary, read-only; a note that can still become one shows the offer.
    func showAI(_ ai: DisplayedAI?, offering: Bool) {
        defer { showOffer(offering && ai == nil) }
        showGlow(ai?.status == .updating)
        guard ai != aiState else { return }
        let wasAI = aiState != nil
        aiState = ai
        if ai != nil {
            if isEditing { setEditing(false) }
            applyTypography()
        } else if wasAI {
            // Back to an ordinary note: its text comes in through `setText`.
            textView.string = ""
        }
    }

    private var offerWanted = false
    /// Bumped by each change of the offer, so a late step of an earlier one doesn't act.
    private var offerGeneration = 0

    /// The offer comes in once the island has closed (picking a scope closes it), rising a few points as it
    /// fades in, so the two never move at once; it goes at once, quickly.
    private func showOffer(_ shown: Bool) {
        guard shown != offerWanted else { return }
        offerWanted = shown
        offerGeneration += 1
        let generation = offerGeneration
        offer.wantsLayer = true
        guard let layer = offer.layer else { return }
        if !shown {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = 0.12
            layer.opacity = 0
            layer.add(fade, forKey: "offer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, offerGeneration == generation else { return }
                offer.isHidden = true
            }
            return
        }
        offer.attributedTitle = NSAttributedString(string: String(localized: "✨ 讓 AI 記錄脈絡？"), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: palette.ink,
        ])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "offer")
        layer.opacity = 0
        CATransaction.commit()
        offer.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, offerGeneration == generation, let layer = offer.layer else { return }
            let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 0.5
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -4
            rise.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.duration = 0.24
            group.timingFunction = ease
            layer.opacity = 0.5
            layer.add(group, forKey: "offer")
        }
    }

    @objc private func takeOffer() {
        onMakeAI?()
    }

    /// The settings' text size changed: everything is set again at the new size.
    func textSizeChanged() {
        textView.font = Self.bodyFont
        applyTypography()
        updateTypingAttributes()
    }

    /// Body text throughout, with the first line set as the title. Checklist markers are hidden (the text
    /// view draws a box over them) and done items are struck through and faded.
    func applyTypography() {
        guard let storage = textView.textStorage else { return }
        if let aiState {
            storage.setAttributedString(AINoteText.attributed(aiState, ink: palette.ink, accent: palette.accent))
            textView.needsDisplay = true
            return
        }
        let titleRange = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: NSRange(location: 0, length: storage.length))
        if titleRange.length > 0 { storage.addAttribute(.font, value: Self.titleFont, range: titleRange) }
        for box in Checklist.boxes(in: storage.string) {
            storage.addAttributes([.foregroundColor: NSColor.clear, .font: Self.boxFont],
                                  range: NSRange(location: box.location, length: 1))
            let body = NSRange(location: box.location + 2, length: max(box.lineRange.length - 2, 0))
            if box.isChecked, body.length > 0 {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: palette.ink.withAlphaComponent(0.45)], range: body)
            }
        }
        storage.endEditing()
        updateTypingAttributes()
        textView.needsDisplay = true
    }

    /// New text takes the title style while the caret is still on the first line.
    func updateTypingAttributes() {
        let string = textView.string as NSString
        let titleRange = string.paragraphRange(for: NSRange(location: 0, length: 0))
        var titleEnd = NSMaxRange(titleRange)
        if titleRange.length > 0, string.character(at: titleEnd - 1) == 0x0A { titleEnd -= 1 }
        textView.typingAttributes = textView.selectedRange().location <= titleEnd ? titleAttributes : bodyAttributes
    }

    /// Text in a scaled layer is resampled; a supersampled bitmap keeps it smooth while carried.
    /// Editing needs live text, so this is only on for the drag.
    func setSmoothedWhileScaled(_ on: Bool) {
        guard let layer = scrollView.layer else { return }
        layer.rasterizationScale = (window?.backingScaleFactor ?? 2) * 2
        layer.minificationFilter = .trilinear
        layer.shouldRasterize = on
    }

    // MARK: Picking up the note

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// While not editing, the whole note is one thing to grab; the text only takes clicks while editing.
    func setEditing(_ editing: Bool) {
        isEditing = editing
        // Turning selection off also turns editing off, so both are set together.
        textView.isEditable = editing
        textView.isSelectable = editing
        window?.invalidateCursorRects(for: self)
    }

    /// Not typing, the paper takes the pointer, so a long note (an AI note's summary, say) still scrolls.
    override func scrollWheel(with event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Collapsed (even while it is still shrinking away) the paper takes nothing. While typing, the text
        // takes clicks; the edges still resize the note.
        guard !isCollapsed else { return nil }
        let local = convert(point, from: superview)
        if !offer.isHidden, offer.frame.contains(local) { return offer }
        if isEditing, !isCollapsed, edges(at: local).isEmpty { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    /// The edges a press at `point` would resize: the sides and bottom along their length, and all four
    /// corners.
    private func edges(at point: NSPoint) -> Edges {
        guard !isCollapsed, bounds.contains(point), !islandRect.contains(point) else { return [] }
        let grip = Self.edgeGrip, corner = Self.cornerGrip
        let nearLeft = point.x < grip, nearRight = point.x > bounds.maxX - grip
        let nearBottom = point.y < grip, nearTop = point.y > bounds.maxY - grip
        let inLeftCorner = point.x < corner, inRightCorner = point.x > bounds.maxX - corner
        let inBottomCorner = point.y < corner, inTopCorner = point.y > bounds.maxY - corner
        var edges: Edges = []
        if nearLeft || (inLeftCorner && (inTopCorner || inBottomCorner)) { edges.insert(.left) }
        if nearRight || (inRightCorner && (inTopCorner || inBottomCorner)) { edges.insert(.right) }
        if nearBottom || (inBottomCorner && (inLeftCorner || inRightCorner)) { edges.insert(.bottom) }
        if nearTop || (inTopCorner && (inLeftCorner || inRightCorner)) { edges.insert(.top) }
        return edges
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressOnlyClosesIsland = event.timestamp == ignoredPressTime
        ignoredPressTime = nil
        let grabbed = edges(at: point)
        isResizing = !grabbed.isEmpty
        if isResizing {
            onResize?(.began(grabbed))
        } else {
            tracker.down(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            onResize?(.moved)
            return
        }
        tracker.dragged(event).forEach { onDrag?($0) }
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            onResize?(.ended)
            return
        }
        switch tracker.up() {
        case .ended:
            onDrag?(.ended)
        case .click(let point):
            // Collapsed into the island, the paper takes no clicks; the island opens it.
            guard !isCollapsed, !pressOnlyClosesIsland else { return }
            if aiState != nil {
                // Read-only: a click on an AI note does nothing but pick it up.
                return
            } else if let box = textView.box(at: textView.convert(point, from: nil)) {
                // A box can be ticked without starting to type.
                textView.toggle(box)
            } else {
                onClick?(point)
            }
        default:
            break
        }
    }

    /// The pointer follows the edges whether or not the note is the key window: cursor rects only work in
    /// the key window, and a note is key only while it is being typed in.
    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { showPointer(for: event) }
    override func mouseMoved(with event: NSEvent) { showPointer(for: event) }

    private func showPointer(for event: NSEvent) {
        guard !isResizing, !isCollapsed else { return }
        let point = convert(event.locationInWindow, from: nil)
        let grabbed = edges(at: point)
        if !grabbed.isEmpty {
            Self.cursor(grabbed).set()
        } else if islandRect.contains(point) {
            NSCursor.arrow.set()
        } else {
            (isEditing ? NSCursor.iBeam : NSCursor.openHand).set()
        }
    }

    override func resetCursorRects() {
        let grip = Self.edgeGrip, corner = Self.cornerGrip
        let b = bounds
        if isCollapsed {
            add(b, cursor: .openHand)
            return
        }
        if !isEditing {
            // Inside the edges and corners only, so no two rects overlap.
            add(NSRect(x: grip, y: corner, width: b.width - 2 * grip, height: b.height - 2 * corner), cursor: .openHand)
            add(NSRect(x: corner, y: grip, width: b.width - 2 * corner, height: corner - grip), cursor: .openHand)
            add(NSRect(x: corner, y: b.maxY - corner, width: b.width - 2 * corner, height: corner - grip), cursor: .openHand)
        }
        add(NSRect(x: 0, y: corner, width: grip, height: b.height - 2 * corner), cursor: Self.cursor(.left))
        add(NSRect(x: b.maxX - grip, y: corner, width: grip, height: b.height - 2 * corner), cursor: Self.cursor(.right))
        add(NSRect(x: corner, y: 0, width: b.width - 2 * corner, height: grip), cursor: Self.cursor(.bottom))
        add(NSRect(x: corner, y: b.maxY - grip, width: b.width - 2 * corner, height: grip), cursor: Self.cursor(.top))
        add(NSRect(x: 0, y: 0, width: corner, height: corner), cursor: Self.cursor([.left, .bottom]))
        add(NSRect(x: b.maxX - corner, y: 0, width: corner, height: corner), cursor: Self.cursor([.right, .bottom]))
        add(NSRect(x: 0, y: b.maxY - corner, width: corner, height: corner), cursor: Self.cursor([.left, .top]))
        add(NSRect(x: b.maxX - corner, y: b.maxY - corner, width: corner, height: corner), cursor: Self.cursor([.right, .top]))
    }

    /// A cursor rect, less whatever of it lies under the island.
    private func add(_ rect: NSRect, cursor: NSCursor) {
        let hole = rect.intersection(islandRect)
        guard !hole.isEmpty else {
            addCursorRect(rect, cursor: cursor)
            return
        }
        let pieces = [
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: hole.minY - rect.minY),
            NSRect(x: rect.minX, y: hole.maxY, width: rect.width, height: rect.maxY - hole.maxY),
            NSRect(x: rect.minX, y: hole.minY, width: hole.minX - rect.minX, height: hole.height),
            NSRect(x: hole.maxX, y: hole.minY, width: rect.maxX - hole.maxX, height: hole.height),
        ]
        for piece in pieces where piece.width > 0 && piece.height > 0 { addCursorRect(piece, cursor: cursor) }
    }

    /// The system's resize pointer for an edge or corner.
    private static func cursor(_ edges: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case .left: .left
            case .right: .right
            case .bottom: .bottom
            case .top: .top
            case [.left, .bottom]: .bottomLeft
            case [.right, .bottom]: .bottomRight
            case [.left, .top]: .topLeft
            default: .topRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return edges == .left || edges == .right ? .resizeLeftRight : edges == .bottom || edges == .top ? .resizeUpDown : .crosshair
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        return style
    }

    /// Sized so the drawn box has room, with the marker's space as the gap after it.
    private static var boxFont: NSFont { .systemFont(ofSize: NoteTypography.textSize + 2) }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.bodyFont, .foregroundColor: palette.ink, .paragraphStyle: Self.paragraphStyle]
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.titleFont, .foregroundColor: palette.ink, .paragraphStyle: Self.paragraphStyle]
    }
}

/// A ring of colour around the paper's edge, as Apple Intelligence glows: a conic gradient seen through
/// a mask of the note's outline. A soft one fades from the edge inward to nothing, with no edge of its
/// own; a hard one is a crisp line. It turns while asked to.
@MainActor
private final class GlowRing: CALayer {
    private let gradient = CAGradientLayer()
    /// The gradient seen through the mask.
    private let band = CALayer()
    /// The mask, drawn as an image: full at the edge, fading inward over `softness`.
    private let fade = CALayer()
    /// Stronger and fainter stretches around the edge, turning the other way to the colours, so the glow
    /// reaches further in here and less there, as Siri's does, instead of tracing an even inner frame.
    private let lobes = CAGradientLayer()
    private let lobesMask = CALayer()
    private let width: CGFloat
    private let softness: CGFloat
    private let falloff: Falloff
    private var drawnFor: CGSize = .zero

    /// How the glow fades going in from the edge.
    enum Falloff {
        /// Light spreading far: fastest at the edge, ever more slowly inward.
        case spread
        /// A soft, narrow band of light along the edge (a Gaussian a few points wide).
        case band
    }

    /// `width` is the full-strength band at the edge; `softness` how far in from there it fades out.
    init(width: CGFloat, softness: CGFloat, opacity: Float, falloff: Falloff = .spread) {
        self.width = width
        self.softness = softness
        self.falloff = falloff
        super.init()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = NotePalette.glowColors.map(\.cgColor)
        band.addSublayer(gradient)
        band.mask = fade
        addSublayer(band)
        lobes.type = .conic
        lobes.startPoint = CGPoint(x: 0.5, y: 0.5)
        lobes.endPoint = CGPoint(x: 0.5, y: 0)
        lobes.colors = [1, 0.35, 0.85, 0.25, 0.95, 0.4, 1].map { NSColor.black.withAlphaComponent($0).cgColor }
        lobesMask.addSublayer(lobes)
        mask = lobesMask
        self.opacity = opacity
    }

    override init(layer: Any) {
        width = (layer as? GlowRing)?.width ?? 0
        softness = (layer as? GlowRing)?.softness ?? 0
        falloff = (layer as? GlowRing)?.falloff ?? .spread
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func fit(_ bounds: CGRect, cornerRadius: CGFloat) {
        frame = bounds
        band.frame = bounds
        fade.frame = bounds
        if bounds.size != drawnFor, bounds.width > 0, bounds.height > 0 {
            drawnFor = bounds.size
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            fade.contentsScale = scale
            fade.contents = Self.fadeImage(size: bounds.size, width: width, softness: softness, falloff: falloff,
                                           cornerRadius: cornerRadius, scale: scale)
        }
        // Squares around the note, so turning them never shows a corner.
        let side = hypot(bounds.width, bounds.height)
        lobesMask.frame = bounds
        for square in [gradient, lobes] {
            square.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            square.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Each pixel by how far it is inside the note's outline: solid across `width` at the edge, then
    /// fading over `softness` as `falloff` says, so the glow never shows where it stops.
    private static func fadeImage(size: CGSize, width: CGFloat, softness: CGFloat, falloff: Falloff,
                                  cornerRadius: CGFloat, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }
        // Black, premultiplied: only the alpha matters to a mask.
        var pixels = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let radius = min(cornerRadius, half.width, half.height)
        // Fading fastest at the edge and ever more slowly inward (no shoulder, where a Gaussian drops
        // steepest and the eye sees a line), gone by `softness`.
        let decay = max(softness / 4.5, 0.5)
        let sigma = max(softness / 3, 0.5)
        for row in 0..<pixelsHigh {
            let y = (CGFloat(row) + 0.5) / scale - half.height
            for column in 0..<pixelsWide {
                let x = (CGFloat(column) + 0.5) / scale - half.width
                // How far inside the rounded rectangle's edge this point is.
                let qx = abs(x) - (half.width - radius), qy = abs(y) - (half.height - radius)
                let outside = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                let inside = -outside
                let value: CGFloat
                if inside < 0 {
                    value = 0
                } else if inside <= width {
                    value = 1
                } else if softness > 0 {
                    let distance = inside - width
                    switch falloff {
                    case .spread:
                        // The last stretch eases to exactly nothing, so there is no cut-off either.
                        let tail = max(0, 1 - distance / softness)
                        value = exp(-distance / decay) * tail * tail
                    case .band:
                        value = exp(-(distance * distance) / (2 * sigma * sigma))
                    }
                } else {
                    value = 0
                }
                pixels[(row * pixelsWide + column) * 4 + 3] = UInt8((value * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func setTurning(_ turning: Bool) {
        let key = "turn"
        guard turning != (gradient.animation(forKey: key) != nil) else { return }
        guard turning else {
            gradient.removeAnimation(forKey: key)
            lobes.removeAnimation(forKey: key)
            return
        }
        // The colours one way, the stronger stretches the other and slower, so the glow keeps changing shape.
        for (layer, toValue, duration) in [(gradient, -2 * CGFloat.pi, 4.0), (lobes, 2 * CGFloat.pi, 7.0)] {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = toValue
            turn.duration = duration
            turn.repeatCount = .infinity
            layer.add(turn, forKey: key)
        }
    }
}

/// Shows the glow and lets every press through to the note under it.
private final class GlowView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
