import Foundation

/// What the focused browser window shows (Safari, Chrome).
public enum BrowserPage: Equatable, Sendable {
    /// A web page, by its normalized address: notes bound to it show in any tab or window that opens it.
    case page(address: String, title: String)
    /// A new tab or start page: there is no page yet to bind to.
    case newTab
    /// One of the browser's own pages (settings, extensions), or a page whose address couldn't be read:
    /// notes fall back to the window, and say so.
    case unrecognized
    /// A private (incognito) window: its addresses are neither used nor saved, only the window is offered.
    case privateWindow
}

/// Tells which web page a browser shows from its address, the way folders are told by their path.
public enum WebPages {
    static let webSchemes: Set = ["http", "https"]
    /// Pages a new tab or the start page shows, by scheme and host (or, for `about:`, path).
    static let newTabPages: Set = ["about:blank", "about:newtab", "about:home", "favorites:", "topsites:",
                                   "chrome:newtab", "chrome:new-tab-page", "chrome-search:local-ntp"]

    /// The same page whatever the case of its host, a trailing "/" or which part of it (`#…`) is shown.
    /// The query is kept: on many sites (YouTube's `?v=`) it is what tells pages apart.
    public static func normalizedAddress(_ address: String) -> String? {
        guard var url = URLComponents(string: address), let scheme = url.scheme, url.host?.isEmpty == false else { return nil }
        url.scheme = scheme.lowercased()
        url.host = url.host?.lowercased()
        url.fragment = nil
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        if url.percentEncodedQuery?.isEmpty == true { url.percentEncodedQuery = nil }
        return url.string
    }

    /// What Chrome's toolbar button and window title say in an incognito window, in the languages likely here.
    static let incognitoLabels = ["Incognito", "無痕模式", "无痕模式"]

    /// What Safari's address field says about a private window ("smart search field in a private window"),
    /// in the languages likely here.
    static let privateFieldWords = ["private", "私密", "隐私", "隱私"]

    /// Signs, from read-only accessibility data, that a browser window is private (report 0005, checked on
    /// real windows): Safari describes the window's address field as being in a private window; Chrome's
    /// window title ends with "(Incognito)", and its toolbar has a button labelled "Incognito". Safari's
    /// `IsSecure` in the window identifier only says the page is HTTPS.
    public static func isPrivateWindow(title: String, addressFieldDescriptions: [String], buttonLabels: [String]) -> Bool {
        if addressFieldDescriptions.contains(where: { field in privateFieldWords.contains { field.lowercased().contains($0) } }) {
            return true
        }
        return incognitoLabels.contains { label in
            title.hasSuffix("(\(label))") || title.hasSuffix("（\(label)）") || buttonLabels.contains(label)
        }
    }

    /// `address` is nil when it couldn't be read, empty when the browser shows none (Safari's start page).
    /// Nil for a local file, which the folder and file scopes look after.
    public static func page(address: String?, title: String, isPrivate: Bool = false) -> BrowserPage? {
        if isPrivate { return .privateWindow }
        guard let address else { return .unrecognized }
        if address.isEmpty { return .newTab }
        guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased() else { return .unrecognized }
        if scheme == "file" { return nil }
        let place = scheme == "about" ? url.path : (url.host ?? "")
        if newTabPages.contains("\(scheme):\(place.lowercased())") { return .newTab }
        guard webSchemes.contains(scheme), let normalized = normalizedAddress(address) else { return .unrecognized }
        return .page(address: normalized, title: title)
    }
}
