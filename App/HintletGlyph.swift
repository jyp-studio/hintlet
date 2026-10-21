import AppKit

/// The mark inside the app icon: a window left open at its bottom-right corner, where a small note sits.
/// Drawn as vector, so it is sharp at menu-bar and button sizes; the shapes are measured off the icon artwork.
enum HintletGlyph {
    /// The mark's own width and height, in the units below.
    private static let box = CGSize(width: 607, height: 584)
    private static let line: CGFloat = 54
    private static let note = CGRect(x: 390, y: 370, width: 217, height: 214)

    /// A template image for the menu bar: it takes the bar's own colour.
    static func template(pointSize: CGFloat = 16, accessibilityDescription: String? = nil) -> NSImage {
        let image = image(pointSize: pointSize, color: .black)
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// The mark in `color`, fitting a `pointSize` square, the way SF Symbols are sized.
    static func image(pointSize: CGFloat, color: NSColor, accessibilityDescription: String? = nil) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = min(rect.width / box.width, rect.height / box.height)
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - box.width * scale) / 2, yBy: (rect.height - box.height * scale) / 2)
            transform.scale(by: scale)
            transform.concat()
            color.setStroke()
            color.setFill()
            outline().stroke()
            NSBezierPath(roundedRect: note, xRadius: 30, yRadius: 30).fill()
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// The window's edge, along its centre line: from where it stops on the right side, round the top and the
    /// left, to where it stops along the bottom, leaving the corner to the note.
    private static func outline() -> NSBezierPath {
        let left: CGFloat = 27, top: CGFloat = 27, right: CGFloat = 545, bottom: CGFloat = 514, radius: CGFloat = 48
        let path = NSBezierPath()
        path.lineWidth = line
        path.lineCapStyle = .butt
        path.move(to: NSPoint(x: right, y: 347))
        path.line(to: NSPoint(x: right, y: top + radius))
        path.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right - radius, y: top), radius: radius)
        path.line(to: NSPoint(x: left + radius, y: top))
        path.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left, y: top + radius), radius: radius)
        path.line(to: NSPoint(x: left, y: bottom - radius))
        path.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left + radius, y: bottom), radius: radius)
        path.line(to: NSPoint(x: 360, y: bottom))
        return path
    }
}
