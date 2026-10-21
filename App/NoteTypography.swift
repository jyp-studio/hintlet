import CoreGraphics
import HintletCore

/// The text size every note is drawn at, from the settings (`NoteSettings.textSize`).
@MainActor
enum NoteTypography {
    static var textSize: CGFloat = NoteSettings.defaultTextSize
}
