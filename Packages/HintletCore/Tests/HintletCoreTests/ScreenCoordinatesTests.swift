import CoreGraphics
import Testing
@testable import HintletCore

/// Accessibility and Core Graphics measure from the primary screen's top-left with y growing down;
/// AppKit measures from its bottom-left with y growing up.
@Suite("座標換算")
struct ScreenCoordinatesTests {
    // A 1512×982 laptop as the primary screen.
    let primaryHeight: CGFloat = 982

    @Test("主螢幕上的視窗")
    func windowOnPrimaryScreen() {
        let window = CGRect(x: 100, y: 33, width: 800, height: 600)
        let converted = ScreenCoordinates.appKitRect(fromTopLeft: window, primaryScreenHeight: primaryHeight)
        #expect(converted == CGRect(x: 100, y: 349, width: 800, height: 600))
    }

    @Test("位在主螢幕上方的副螢幕：y 為負")
    func secondaryScreenAbove() {
        // A 2560×1440 display placed above the laptop.
        let window = CGRect(x: 200, y: -1400, width: 1000, height: 700)
        let converted = ScreenCoordinates.appKitRect(fromTopLeft: window, primaryScreenHeight: primaryHeight)
        #expect(converted == CGRect(x: 200, y: 1682, width: 1000, height: 700))
    }

    @Test("位在主螢幕左側、底部較低的副螢幕：x 為負")
    func secondaryScreenToTheLeft() {
        // A 1920×1080 display to the left whose top lines up with the laptop's top.
        let window = CGRect(x: -1800, y: 900, width: 600, height: 150)
        let converted = ScreenCoordinates.appKitRect(fromTopLeft: window, primaryScreenHeight: primaryHeight)
        #expect(converted == CGRect(x: -1800, y: -68, width: 600, height: 150))
    }
}
