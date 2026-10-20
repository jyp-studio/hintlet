import ApplicationServices
import CoreGraphics

/// Private but long-standing (used by window managers such as Hammerspoon and yabai): the window server's
/// number for an AX window.
@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindow(_ element: AXUIElement, _ number: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    /// For Swift-bridged values (strings, numbers); CF types like AXUIElement need `elementAttribute`.
    func attribute<T>(_ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func elementAttribute(_ name: String) -> AXUIElement? {
        guard let value: AnyObject = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Top-left-origin global frame, as Accessibility reports it.
    var frame: CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue: AnyObject = attribute(kAXPositionAttribute),
              let sizeValue: AnyObject = attribute(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The window server's number for this window, when the system tells.
    var serverWindowNumber: CGWindowID? {
        var number: CGWindowID = 0
        guard axUIElementGetWindow(self, &number) == .success, number != 0 else { return nil }
        return number
    }
}
