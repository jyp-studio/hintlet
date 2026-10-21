import CoreGraphics

/// Converts between the two global coordinate spaces macOS uses.
///
/// Accessibility (`AXPosition`) and Core Graphics window lists measure from the primary screen's
/// top-left corner with y growing down. AppKit (`NSWindow`, `NSScreen`) measures from the primary
/// screen's bottom-left corner with y growing up. Both spaces span every display, so the primary
/// screen's height is the only thing needed to convert, whatever the arrangement of other displays.
/// The primary screen is `NSScreen.screens[0]` (the one with the menu bar in Displays settings), not
/// `NSScreen.main`, which follows keyboard focus and gives wrong results on a secondary display.
public enum ScreenCoordinates {
    public static func appKitRect(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

}
