import CoreGraphics
import Foundation

/// How new notes start out and how big their text is, as the user sets them. Kept in the app's
/// preferences, never in the notes file. Notes already made keep their own size and colour.
public struct NoteSettings: Equatable, Sendable {
    public static let defaultTextSize: CGFloat = 13
    public static let textSizes: ClosedRange<CGFloat> = 11...20
    /// As small as a note can be resized to, up to about a third of a laptop screen.
    public static let widths: ClosedRange<CGFloat> = NoteEngine.minimumNoteSize.width...600
    public static let heights: ClosedRange<CGFloat> = NoteEngine.minimumNoteSize.height...500

    /// The sizes offered by name; any other size is `custom`.
    public enum SizePreset: String, CaseIterable, Sendable {
        case small, medium, large, custom

        public var size: CGSize? {
            switch self {
            case .small: CGSize(width: 200, height: 150)
            case .medium: NoteEngine.defaultNoteSize
            case .large: CGSize(width: 320, height: 240)
            case .custom: nil
            }
        }
    }

    /// Which named size `noteSize` is, or `custom`.
    public var sizePreset: SizePreset {
        SizePreset.allCases.first { $0.size == noteSize } ?? .custom
    }

    /// The size a new note is made at.
    public var noteSize: CGSize {
        didSet { noteSize = Self.clamped(noteSize) }
    }
    /// The body text's size, in points, on every note (the first line is a point bigger).
    public var textSize: CGFloat {
        didSet { textSize = Self.clamped(textSize) }
    }
    /// The colour a new note is made in.
    public var noteColor: NoteColor

    public init(noteSize: CGSize = NoteEngine.defaultNoteSize, textSize: CGFloat = defaultTextSize,
                noteColor: NoteColor = .yellow) {
        self.noteSize = Self.clamped(noteSize)
        self.textSize = Self.clamped(textSize)
        self.noteColor = noteColor
    }

    static let widthKey = "noteWidth"
    static let heightKey = "noteHeight"
    static let textSizeKey = "noteTextSize"
    static let colorKey = "noteColor"

    public static func load(from defaults: UserDefaults) -> NoteSettings {
        let fallback = NoteSettings()
        func number(_ key: String) -> CGFloat? {
            (defaults.object(forKey: key) as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        return NoteSettings(noteSize: CGSize(width: number(widthKey) ?? fallback.noteSize.width,
                                             height: number(heightKey) ?? fallback.noteSize.height),
                            textSize: number(textSizeKey) ?? fallback.textSize,
                            noteColor: defaults.string(forKey: colorKey).flatMap(NoteColor.init(rawValue:)) ?? fallback.noteColor)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(Double(noteSize.width), forKey: Self.widthKey)
        defaults.set(Double(noteSize.height), forKey: Self.heightKey)
        defaults.set(Double(textSize), forKey: Self.textSizeKey)
        defaults.set(noteColor.rawValue, forKey: Self.colorKey)
    }

    private static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width.rounded(), widths.lowerBound), widths.upperBound),
               height: min(max(size.height.rounded(), heights.lowerBound), heights.upperBound))
    }

    private static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), textSizes.lowerBound), textSizes.upperBound)
    }
}
