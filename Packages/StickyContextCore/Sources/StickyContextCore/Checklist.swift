import Foundation

/// A change to a note's text: replace `range` with `replacement`, then put the caret at `caret`.
/// Ranges and offsets count UTF-16 units, as NSString and NSTextView do.
public struct TextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let caret: Int
}

/// Checklist items are plain text: a line starting with "☐ " (to do) or "☑ " (done), so notes stay readable
/// wherever their text goes. These rules are what the text view does with them.
public enum Checklist {
    public static let uncheckedMarker = "☐ "
    public static let checkedMarker = "☑ "
    static let unchecked: unichar = 0x2610
    static let checked: unichar = 0x2611
    /// Typed at the start of a line, these become a box.
    static let shorthands = ["[] ", "[ ] "]

    /// A box as drawn: where its character is, and the line it heads (without the line break).
    public struct Box: Equatable, Sendable {
        public let location: Int
        public let isChecked: Bool
        public let lineRange: NSRange

        public init(location: Int, isChecked: Bool, lineRange: NSRange) {
            self.location = location
            self.isChecked = isChecked
            self.lineRange = lineRange
        }
    }

    public static func boxes(in text: String) -> [Box] {
        lines(of: text as NSString).compactMap { line in
            guard let checked = marker(at: line, in: text as NSString) else { return nil }
            return Box(location: line.location, isChecked: checked, lineRange: line)
        }
    }

    /// Clicking the box at `index` ticks it, or unticks it.
    public static func toggle(in text: String, at index: Int) -> TextEdit? {
        let string = text as NSString
        guard index < string.length, let checked = marker(at: line(containing: index, in: string), in: string),
              line(containing: index, in: string).location == index else { return nil }
        let replacement = checked ? String(utf16CodeUnits: [unchecked], count: 1) : String(utf16CodeUnits: [Self.checked], count: 1)
        return TextEdit(range: NSRange(location: index, length: 1), replacement: replacement, caret: index + 1)
    }

    /// Return at `caret` on an item starts the next item; on an empty item it ends the list instead.
    public static func lineBreak(in text: String, at caret: Int) -> TextEdit? {
        let string = text as NSString
        let line = line(containing: caret, in: string)
        // Before the box (it is hidden, but the arrow keys can get there) it is an ordinary line break.
        guard marker(at: line, in: string) != nil, caret >= line.location + 2 else { return nil }
        let markerLength = (uncheckedMarker as NSString).length
        if line.length <= markerLength {
            return TextEdit(range: NSRange(location: line.location, length: line.length), replacement: "",
                            caret: line.location)
        }
        let inserted = "\n" + uncheckedMarker
        return TextEdit(range: NSRange(location: caret, length: 0), replacement: inserted,
                        caret: caret + (inserted as NSString).length)
    }

    /// Delete right after a box (or inside it) takes the whole box away, leaving a plain line.
    public static func deleteBackward(in text: String, at caret: Int) -> TextEdit? {
        let string = text as NSString
        guard caret > 0 else { return nil }
        let line = line(containing: caret, in: string)
        guard marker(at: line, in: string) != nil, caret > line.location, caret <= line.location + 2 else { return nil }
        return TextEdit(range: NSRange(location: line.location, length: 2), replacement: "", caret: line.location)
    }

    /// After typing at `caret`: "[] " or "[ ] " at the very start of a line becomes a box.
    public static func autoformat(in text: String, caret: Int) -> TextEdit? {
        let string = text as NSString
        let line = line(containing: max(caret - 1, 0), in: string)
        let typed = string.substring(with: NSRange(location: line.location, length: caret - line.location))
        guard shorthands.contains(typed) else { return nil }
        return TextEdit(range: NSRange(location: line.location, length: (typed as NSString).length),
                        replacement: uncheckedMarker, caret: line.location + (uncheckedMarker as NSString).length)
    }

    /// ⇧⌘L: the selected lines (or the caret's) become items; if they all are already, plain lines again.
    /// Blank lines are left as they are.
    public static func toggleLines(in text: String, selection: NSRange) -> TextEdit {
        let string = text as NSString
        let covered = string.lineRange(for: selection)
        var parts: [(body: NSRange, ending: NSRange)] = []
        string.enumerateSubstrings(in: covered, options: [.byLines, .substringNotRequired]) { _, body, enclosing, _ in
            parts.append((body, NSRange(location: NSMaxRange(body), length: NSMaxRange(enclosing) - NSMaxRange(body))))
        }
        if parts.isEmpty { parts = [(NSRange(location: covered.location, length: 0), NSRange(location: covered.location, length: 0))] }
        let filled = parts.filter { $0.body.length > 0 }
        let allItems = !filled.isEmpty && filled.allSatisfy { marker(at: $0.body, in: string) != nil }
        let markerLength = (uncheckedMarker as NSString).length
        var result = ""
        for part in parts {
            let body = string.substring(with: part.body)
            if part.body.length == 0 {
                result += body
            } else if allItems {
                result += (body as NSString).substring(from: markerLength)
            } else {
                result += marker(at: part.body, in: string) == nil ? uncheckedMarker + body : body
            }
            result += string.substring(with: part.ending)
        }
        let range = NSRange(location: parts[0].body.location, length: NSMaxRange(parts[parts.count - 1].ending) - parts[0].body.location)
        // The caret stays at the end of the last line, before its line break.
        let lastEnding = (string.substring(with: parts[parts.count - 1].ending) as NSString).length
        return TextEdit(range: range, replacement: result, caret: range.location + (result as NSString).length - lastEnding)
    }

    /// Whether `line` starts with a box, and if so whether it is ticked.
    private static func marker(at line: NSRange, in string: NSString) -> Bool? {
        guard line.length >= 2, string.character(at: line.location + 1) == 0x20 else { return nil }
        switch string.character(at: line.location) {
        case unchecked: return false
        case checked: return true
        default: return nil
        }
    }

    /// The line around `index`, without its line break.
    private static func line(containing index: Int, in string: NSString) -> NSRange {
        var start = 0, end = 0, contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(index, string.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private static func lines(of string: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var location = 0
        repeat {
            let line = line(containing: location, in: string)
            result.append(line)
            location = NSMaxRange(string.lineRange(for: NSRange(location: line.location, length: 0)))
        } while location < string.length
        if string.length > 0, string.character(at: string.length - 1) == 0x0A {
            result.append(NSRange(location: string.length, length: 0))
        }
        return result
    }
}
