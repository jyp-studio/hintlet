import AppKit
import StickyContextCore

/// The note's text, with checklist items drawn the way Notes draws them: the "☐ "/"☑ " markers in the text
/// are invisible and an open circle, or a filled check, is drawn in their place.
final class NoteTextView: NSTextView {
    /// How far around a box still counts as clicking it.
    private static let boxSlop: CGFloat = 4
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let configuration = NSImage.SymbolConfiguration(pointSize: NoteTypography.textSize, weight: .regular)
        for box in Checklist.boxes(in: string) {
            guard let rect = boxRect(at: box.location) else { continue }
            let symbol = box.isChecked ? "checkmark.circle.fill" : "circle"
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration.applying(.init(paletteColors: [ink.withAlphaComponent(box.isChecked ? 0.75 : 0.55)])))
            else { continue }
            let size = image.size
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }

    /// Where the box at character `location` is drawn, in view coordinates.
    private func boxRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// The box under `point` (view coordinates), if any.
    func box(at point: NSPoint) -> Checklist.Box? {
        Checklist.boxes(in: string).first { box in
            boxRect(at: box.location)?.insetBy(dx: -Self.boxSlop, dy: -Self.boxSlop).contains(point) == true
        }
    }

    /// Clicking a box ticks it instead of moving the caret.
    override func mouseDown(with event: NSEvent) {
        if let box = box(at: convert(event.locationInWindow, from: nil)) {
            toggle(box)
            return
        }
        super.mouseDown(with: event)
    }

    /// Ticking a box while typing can be undone with the text; outside editing there is no ⌘Z to undo it with,
    /// and an undo step left behind would later run against text that can't be edited.
    func toggle(_ box: Checklist.Box) {
        guard let edit = Checklist.toggle(in: string, at: box.location) else { return }
        if isEditable {
            apply(edit, movingCaret: false)
        } else {
            undoManager?.disableUndoRegistration()
            apply(edit, movingCaret: false)
            undoManager?.enableUndoRegistration()
        }
    }

    /// Return continues a checklist, or ends it on an empty item.
    override func insertNewline(_ sender: Any?) {
        if let edit = Checklist.lineBreak(in: string, at: selectedRange().location), selectedRange().length == 0 {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    /// Delete right after a box takes the box away, as in Notes.
    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), selectedRange().length == 0, let edit = Checklist.deleteBackward(in: string, at: selectedRange().location) {
            apply(edit)
        } else {
            super.deleteBackward(sender)
        }
    }

    /// "[] " typed at the start of a line becomes a box.
    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        guard !hasMarkedText(), (text as? String) == " " || (text as? NSAttributedString)?.string == " " else { return }
        if let edit = Checklist.autoformat(in: string, caret: selectedRange().location) { apply(edit) }
    }

    /// 編輯 › 清單項目 (⇧⌘L).
    @objc func toggleChecklist(_ sender: Any?) {
        apply(Checklist.toggleLines(in: string, selection: selectedRange()))
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleChecklist(_:)) { return isEditable }
        return super.validateMenuItem(menuItem)
    }

    /// Makes the change as typing would, so it can be undone with ⌘Z.
    func apply(_ edit: TextEdit, movingCaret: Bool = true) {
        let wasEditable = isEditable
        isEditable = true
        defer { isEditable = wasEditable }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        if movingCaret { setSelectedRange(NSRange(location: edit.caret, length: 0)) }
        needsDisplay = true
    }
}
