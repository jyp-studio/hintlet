import CoreGraphics

/// Whether a note gives way to the caret while the user types under it in another app.
///
/// A note that gives way fades where it is, the way the pointer hides while you type: it never moves, so it is
/// still where the user left it, and nothing slides about at the edge of their sight while they type.
public enum GivingWay {
    /// The room kept clear around the caret: a little above and below its line, and more to its right,
    /// where the next words go.
    public static func clearZone(around caret: CGRect) -> CGRect {
        CGRect(x: caret.minX - 16, y: caret.minY - 8, width: caret.width + 16 + 64, height: caret.height + 16)
    }

    /// Both rects in AppKit coordinates.
    public static func fades(_ note: CGRect, forCaret caret: CGRect) -> Bool {
        note.intersects(clearZone(around: caret))
    }
}
