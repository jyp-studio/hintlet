import AppKit
import HintletCore

/// The paper and ink of each note colour: soft pastels like Stickies, each with a dark ink of its own hue
/// so text stays easy to read; and the AI notes' own: pastel mist, sunset and frosted glass.
struct NotePalette {
    let paperTop: NSColor
    let paperBottom: NSColor
    let ink: NSColor
    let name: String
    /// Dark paper: its rim and highlight are fainter, and its scroller light.
    var isDark = false
    /// Frosted glass instead of paper, light or dark with the system, as macOS shows its own summaries.
    var usesMaterial = false
    /// Paper running diagonally through these, top-left to bottom-right, instead of top to bottom.
    var diagonal: [NSColor]?
    /// Soft patches of colour over the paper, each fading out from a point (in unit coordinates, y up).
    var patches: [(color: NSColor, center: CGPoint)] = []

    /// One flat paper colour, which a ripple can carry; patches, a diagonal or glass can't be.
    var isPlainPaper: Bool { !usesMaterial && diagonal == nil && patches.isEmpty }
    /// The AI note's "✦ 摘要" heading; the ink, faded, when nil.
    var accent: NSColor?

    /// The glow around an AI note while it is being written, as Apple Intelligence shows its work.
    static let glowColors = [rgb(0.31, 0.55, 1.0), rgb(0.70, 0.42, 1.0), rgb(1.0, 0.37, 0.64), rgb(1.0, 0.62, 0.26),
                             rgb(0.31, 0.55, 1.0)]

    static func of(_ color: NoteColor) -> NotePalette {
        switch color {
        case .yellow:
            NotePalette(paperTop: rgb(1.0, 0.922, 0.561), paperBottom: rgb(1.0, 0.878, 0.439),
                        ink: rgb(0.227, 0.173, 0.0, 0.92), name: String(localized: "黃色"))
        case .green:
            NotePalette(paperTop: rgb(0.835, 0.957, 0.725), paperBottom: rgb(0.749, 0.922, 0.612),
                        ink: rgb(0.106, 0.235, 0.039, 0.92), name: String(localized: "綠色"))
        case .blue:
            NotePalette(paperTop: rgb(0.784, 0.898, 1.0), paperBottom: rgb(0.678, 0.839, 0.988),
                        ink: rgb(0.051, 0.161, 0.302, 0.92), name: String(localized: "藍色"))
        case .pink:
            NotePalette(paperTop: rgb(1.0, 0.851, 0.894), paperBottom: rgb(0.988, 0.769, 0.835),
                        ink: rgb(0.329, 0.051, 0.141, 0.92), name: String(localized: "粉紅色"))
        case .purple:
            NotePalette(paperTop: rgb(0.906, 0.859, 1.0), paperBottom: rgb(0.843, 0.776, 0.988),
                        ink: rgb(0.188, 0.086, 0.345, 0.92), name: String(localized: "紫色"))
        case .mist:
            NotePalette(paperTop: rgb(0.984, 0.984, 0.992), paperBottom: rgb(0.984, 0.984, 0.992),
                        ink: rgb(0.114, 0.114, 0.122), name: String(localized: "粉霧"),
                        patches: [(rgb(0.890, 0.863, 1.0), CGPoint(x: 0, y: 1)), (rgb(1.0, 0.878, 0.925), CGPoint(x: 1, y: 0)),
                                  (rgb(0.875, 0.945, 1.0), CGPoint(x: 1, y: 1))],
                        accent: rgb(0.490, 0.361, 0.961))
        case .sunset:
            NotePalette(paperTop: rgb(1.0, 0.906, 0.722), paperBottom: rgb(0.976, 0.659, 0.769),
                        ink: rgb(0.227, 0.165, 0.063), name: String(localized: "夕陽"),
                        diagonal: [rgb(1.0, 0.906, 0.722), rgb(1.0, 0.788, 0.663), rgb(0.976, 0.659, 0.769)],
                        accent: rgb(0.690, 0.271, 0.173))
        case .glow:
            NotePalette(paperTop: rgb(0.97, 0.97, 0.98), paperBottom: rgb(0.86, 0.86, 0.89),
                        ink: .labelColor, name: String(localized: "毛玻璃"), usesMaterial: true)
        }
    }

    /// The island's light text and marks on its dark surface.
    static let islandInk = NSColor(white: 0.96, alpha: 1)

    /// A round swatch for the island; `selected` adds a light ring around it, as macOS colour pickers mark
    /// the current choice.
    func swatch(diameter: CGFloat, selected: Bool) -> NSImage {
        // The ring sits 1.5pt clear of the dot.
        let side = diameter + (selected ? 6 : 0)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dot = NSRect(x: (side - diameter) / 2, y: (side - diameter) / 2, width: diameter, height: diameter)
            NSGradient(starting: paperBottom, ending: paperTop)?.draw(in: NSBezierPath(ovalIn: dot), angle: 90)
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                NotePalette.islandInk.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
