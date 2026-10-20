import AppKit
import ApplicationServices
import StickyContextCore

/// Reads which web page Safari or Chrome shows, from the address (AXURL) of the page's web area, without
/// any Automation permission (report 0005). Only reads: the browser's own Accessibility settings are left alone.
@MainActor
final class BrowserPages {
    nonisolated static let bundleIDs: Set = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
    ]
    private static let webAreaRole = "AXWebArea"
    /// Bounds the search for the page, so a window with many tabs can't stall the main thread. The search
    /// doesn't go into pages, so only the toolbar and tab bar count.
    private static let searchBudget = 800
    /// A busy browser mustn't hold up the main thread.
    private static let messagingTimeout: Float = 0.25
    /// The page last read and its address then: polling reads just that address.
    private var watched: (area: AXUIElement, address: String?)?
    private var blindChecks = 0

    nonisolated static func isBrowser(_ bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }

    /// The page shown in `window`. A single page filling the window is read by its address; with none, an
    /// empty address field is a new tab or start page; anything else (several pages, no address) can't be told.
    /// A private window (`WebPages.isPrivateWindow`) gives no address at all.
    func page(in window: AXUIElement, windowTitle: String) -> BrowserPage? {
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        let (areas, fields, buttonLabels) = search(window)
        let isPrivate = WebPages.isPrivateWindow(title: window.attribute(kAXTitleAttribute) ?? windowTitle,
                                                 addressFieldDescriptions: fields.compactMap { $0.attribute(kAXDescriptionAttribute) },
                                                 buttonLabels: buttonLabels)
        if isPrivate {
            watched = nil
            return WebPages.page(address: nil, title: windowTitle, isPrivate: true)
        }
        let visible = areas.filter { ($0.size.map { $0.width > 0 && $0.height > 0 }) ?? false }
        guard visible.count <= 1 else {
            watched = nil
            return .unrecognized
        }
        guard let area = visible.first else {
            watched = nil
            // Safari's start page is no web page at all, and its address field is empty.
            let isEmptyAddressField = fields.count == 1 && (fields[0].attribute(kAXValueAttribute) as String?) == ""
            return WebPages.page(address: isEmptyAddressField ? "" : nil, title: windowTitle)
        }
        let address = area.address
        watched = (area, address)
        let title = (area.attribute(kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? windowTitle
        return WebPages.page(address: address, title: title)
    }

    /// Whether the page last read may show something else now (a single-page site changing its address
    /// without any notice, e.g. YouTube). Cheap enough to ask twice a second.
    func pageMayHaveChanged() -> Bool {
        guard let watched else {
            blindChecks += 1
            return blindChecks % 5 == 0
        }
        AXUIElementSetMessagingTimeout(watched.area, Self.messagingTimeout)
        return watched.area.address != watched.address
    }

    /// The window's web areas (not looking inside them), its address field and what its buttons say,
    /// breadth first. Pages aren't looked into, so the buttons are the browser's own (not tabs, which are
    /// radio buttons or tabs).
    private func search(_ window: AXUIElement) -> (areas: [AXUIElement], fields: [AXUIElement], buttonLabels: [String]) {
        var areas: [AXUIElement] = []
        var fields: [AXUIElement] = []
        var buttonLabels: [String] = []
        var queue = [window]
        var next = 0
        while next < queue.count, next < Self.searchBudget {
            let node = queue[next]
            next += 1
            AXUIElementSetMessagingTimeout(node, Self.messagingTimeout)
            let role: String? = node.attribute(kAXRoleAttribute)
            if role == Self.webAreaRole {
                areas.append(node)
                continue
            }
            if role == kAXTextFieldRole as String, Self.isAddressField(node) { fields.append(node) }
            if let role, Self.buttonRoles.contains(role) {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let label: String = node.attribute(name), !label.isEmpty { buttonLabels.append(label) }
                }
            }
            if let children: [AXUIElement] = node.attribute(kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        return (areas, fields, buttonLabels)
    }

    private static let buttonRoles: Set = [kAXButtonRole as String, kAXPopUpButtonRole as String, kAXMenuButtonRole as String]

    /// Safari's address field (report 0005). Chrome's new tab is a page of its own, so it needs none.
    private static func isAddressField(_ field: AXUIElement) -> Bool {
        (field.attribute(kAXIdentifierAttribute) as String?) == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    }
}

private extension AXUIElement {
    /// A web area's address (AXURL).
    var address: String? {
        guard let value: AnyObject = attribute(kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    var size: CGSize? {
        guard let value: AnyObject = attribute(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
