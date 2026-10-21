import AppKit
import QuartzCore
import ApplicationServices
import HintletCore

/// Watches the frontmost app's focused window through Accessibility and reports two things: which window
/// the user is working in (`onChange`), and whether that window is in motion (`onMotionChange`).
///
/// Another process's overlay can never move in lockstep with a window the window server is animating
/// (drags, Genie, full screen), so notes don't chase the window: they step aside while it moves and come
/// back, in the right place, once it is still.
/// Must live as long as the app: the AX observer holds an unretained reference to it.
@MainActor
final class WindowContextProvider {
    var onChange: ((ContextObservation) -> Void)?
    /// True while the focused window is being moved, resized, minimized or taken full screen.
    var onMotionChange: ((Bool) -> Void)?
    /// A window closed or its app quit: its notes wait to be found again.
    var onWindowsGone: (([WindowID]) -> Void)?

    private static let windowNotifications = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]
    /// Keeps a hung app from stalling the main thread.
    private static let messagingTimeout: Float = 0.25
    /// A window counts as still once its frame hasn't changed for this long. Once the mouse is up the window
    /// server stops moving it at once, so a couple of frames are enough; app or keyboard driven animations
    /// (tiling, zoom) need a little longer.
    private static let stillAfterRelease: TimeInterval = 0.04
    private static let stillAfterAnimation: TimeInterval = 0.12
    /// How long to watch for a move to start after a press or a move/resize notification.
    private static let watchWindow: TimeInterval = 0.4
    /// Roughly how long macOS takes to animate a window into or out of full screen.
    private static let fullScreenAnimation: TimeInterval = 0.8
    /// After clicking minimize or full screen, give up waiting for the app to confirm after this long.
    private static let buttonConfirmDelay: TimeInterval = 1.5
    private static let resizeEdge: CGFloat = 8
    /// Notes don't stay out of the way forever, whatever a window keeps doing.
    private static let longestMotion: TimeInterval = 20
    /// Where the traffic-light buttons can be: a title bar or a unified toolbar.
    private static let titleBarHeight: CGFloat = 60
    /// Not among the AX constants AppKit exports.
    private static let fullScreenAttribute = "AXFullScreen"

    private var watchedApp: NSRunningApplication?
    private var watchedElement: AXUIElement?
    private var observer: AXObserver?
    private var identities = WindowIdentities()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private let ticker = FrameTicker()
    private let finderFolders = FinderFolders()
    private let terminalSessions = TerminalSessions()
    /// Starting or quitting Claude Code in a tab changes nothing Accessibility reports, so a terminal in
    /// front is checked now and then too. A check reads a few small files and the tab's processes.
    private var terminalPoll: Timer?
    private static let terminalPollInterval: TimeInterval = 1
    /// Which conversation Claude shows; also asked by the app delegate for consent.
    let claudePages = ClaudePages()
    /// Which web page Safari or Chrome shows.
    private let browserPages = BrowserPages()
    /// Claude gives no notice when the conversation changes without focus moving (e.g. a link, or a click
    /// in the sidebar), so its page is also read now and then while it is in front. A read is a cached
    /// element's address, about 0.03 ms (report 0002). Twice a second, with room to fall in with other
    /// timers, wakes the Mac least; checking more often made no difference anyone could see.
    /// Browsers neither say when a single-page site changes its address (YouTube), so theirs is read the same way.
    private var claudePoll: Timer?
    private static let claudePollInterval: TimeInterval = 0.5

    /// Windows that close are only reported to observers registered on them; tracked per observer.
    private var destroyWatched: [AXUIElement] = []

    /// The last window reported (nil while none can be identified).
    private var lastWindow: ObservedWindow?
    /// The last window actually seen; a failed read in the middle of an animation doesn't clear it.
    private var lastSeenWindow: ObservedWindow?
    private var isMouseDown = false
    private var pressLocation = NSPoint.zero
    /// The title-bar button (by AX subrole) the mouse went down on.
    private var pressedButton: String?

    // Motion
    private var isMoving = false
    /// The window server's number for the focused window, whose frame is what is actually on screen.
    private var serverWindow: CGWindowID?
    private var serverFrame: CGRect?
    private var serverLookupFailed = false
    /// The current motion comes from the user dragging the window (vs. an animation the app runs).
    private var pressedOnWindow = false
    private var lastFrameChange = Date.distantPast
    private var motionStarted = Date.distantPast
    /// The app reported a move or resize the window-server polling may not have seen.
    private var refreshWhenWatchEnds = false
    private var watchUntil = Date.distantPast
    /// Set while waiting out a minimize or full-screen animation the app hasn't confirmed yet.
    private var holdUntil = Date.distantPast

    func start() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                  queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostAppChanged(to: app) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                  queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                let gone = self.identities.forget(pid: app.processIdentifier)
                self.finderFolders.forget(gone)
                self.terminalSessions.forget(gone)
                self.onWindowsGone?(gone)
            }
        })
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let isDown = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.mouseChanged(isDown: isDown, at: NSEvent.mouseLocation) }
        }
        ticker.onFrame = { [weak self] in self?.tick() }
        frontmostAppChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    /// Reads the focused window again and reports it. Before creating a note, `waitingForFolder` makes sure
    /// a Finder window's folder is known, so the note goes to the folder.
    func refresh(waitingForFolder: Bool = false) {
        guard let app = watchedApp, let element = watchedElement else {
            report(nil)
            return
        }
        report(focusedWindow(of: app, element: element, waitingForFolder: waitingForFolder))
    }

    private func report(_ window: ObservedWindow?) {
        var motionIsOver = false
        if let window, window.id != lastSeenWindow?.id {
            serverWindow = nil
            serverFrame = nil
            serverLookupFailed = false
            // Whatever was in motion was the previous window (e.g. it went to the Dock); this one is still.
            holdUntil = .distantPast
            motionIsOver = true
        }
        if let window, let seen = lastSeenWindow, window.id == seen.id, window.isFullScreen != seen.isFullScreen {
            // The app says so as the window server starts animating; wait the animation out.
            hold(for: Self.fullScreenAnimation)
        }
        lastWindow = window
        if let window { lastSeenWindow = window }
        // The new context first, then the end of motion, so notes are revealed for the right window.
        onChange?(window.map(ContextObservation.window) ?? .unidentified)
        if motionIsOver { setMoving(false) }
    }

    // MARK: Motion

    private func setMoving(_ moving: Bool) {
        guard moving != isMoving else { return }
        isMoving = moving
        if moving { motionStarted = Date() } else { pressedOnWindow = false }
        onMotionChange?(moving)
    }

    /// Keeps notes out of the way until `duration` has passed and the window is still.
    private func hold(for duration: TimeInterval) {
        holdUntil = max(holdUntil, Date().addingTimeInterval(duration))
        setMoving(true)
        watch(for: duration)
    }

    /// Watches the window server's frame of the focused window every display frame for a while.
    private func watch(for duration: TimeInterval) {
        watchUntil = max(watchUntil, Date().addingTimeInterval(duration))
        ticker.start()
    }

    private func tick() {
        // A global monitor can miss the mouse-up (e.g. under Secure Input).
        if isMouseDown, !CGEventSource.buttonState(.combinedSessionState, button: .left) { isMouseDown = false }
        let now = Date()

        if let frame = currentServerFrame() {
            if let previous = serverFrame, previous != frame {
                lastFrameChange = now
                setMoving(true)
                // Carried along while they fade out of the way, so they dissolve on the window, not behind it.
                if var window = lastWindow {
                    window.frame = frame
                    report(window)
                }
            }
            serverFrame = frame
        }

        let stillAfter = pressedOnWindow ? Self.stillAfterRelease : Self.stillAfterAnimation
        let still = now.timeIntervalSince(lastFrameChange) >= stillAfter
        if isMoving, still, !isMouseDown, now >= holdUntil {
            settle()
        } else if isMoving, now.timeIntervalSince(motionStarted) > Self.longestMotion {
            holdUntil = .distantPast
            settle()
        }
        // A press that hasn't moved the window soon is a click, a selection or a scroll: stop polling.
        // If it turns into a drag after all, the app's move notification starts watching again.
        if !isMoving, now >= watchUntil {
            ticker.stop()
            if refreshWhenWatchEnds {
                refreshWhenWatchEnds = false
                refresh()
            }
        }
    }

    /// The window is still: read its final state and bring the notes back. The window server's frame is
    /// what is on screen; the app's own may not have caught up yet.
    private func settle() {
        guard let app = watchedApp, let element = watchedElement else {
            report(nil)
            setMoving(false)
            return
        }
        var window = focusedWindow(of: app, element: element)
        if let frame = serverFrame, window?.id == lastWindow?.id, window?.isMinimized == false {
            window?.frame = frame
        }
        refreshWhenWatchEnds = false
        report(window)
        // Reading the final state may itself reveal a full-screen change that has just begun.
        if Date() >= holdUntil { setMoving(false) }
    }

    private func currentServerFrame() -> CGRect? {
        guard let window = lastWindow, let app = watchedApp else { return nil }
        if serverWindow == nil, let key = window.serverKey {
            serverWindow = key.number
        }
        if serverWindow == nil, !serverLookupFailed {
            serverWindow = ServerWindows.find(pid: app.processIdentifier, frame: window.frame)
            // Listing every window is the costly part; don't repeat it every frame.
            serverLookupFailed = serverWindow == nil
        }
        guard let serverWindow else { return nil }
        return ServerWindows.frame(of: serverWindow)
    }

    private func mouseChanged(isDown: Bool, at location: NSPoint) {
        isMouseDown = isDown
        if isDown {
            pressLocation = location
            pressedButton = nil
            // Only a press on the focused window (or just outside it, on a resize edge) can move it.
            guard let window = lastWindow,
                  window.frame.insetBy(dx: -Self.resizeEdge, dy: -Self.resizeEdge).contains(location) else { return }
            if window.frame.maxY - location.y < Self.titleBarHeight {
                pressedButton = windowButtonOfFocusedWindow(at: location)
            }
            serverFrame = nil
            serverLookupFailed = false
            pressedOnWindow = true
            watch(for: Self.watchWindow)
        } else {
            // No second AX hit test here: the app is busy starting its animation and would answer late.
            if let button = pressedButton, hypot(location.x - pressLocation.x, location.y - pressLocation.y) < 4 {
                windowButtonClicked(button)
            }
            pressedButton = nil
            if ticker.isRunning { watch(for: Self.watchWindow) }
        }
    }

    /// The app reports a minimize or full-screen change only once the system's animation is over, so a
    /// click on the button moves the notes out of the way right away.
    private func windowButtonClicked(_ subrole: String) {
        guard [kAXMinimizeButtonSubrole, kAXFullScreenButtonSubrole].contains(subrole) else { return }
        // Held until the app confirms (then the full-screen check extends it) or gives up.
        hold(for: Self.buttonConfirmDelay)
    }

    /// The subrole of the focused window's title-bar button under `location`, if any.
    private func windowButtonOfFocusedWindow(at location: NSPoint) -> String? {
        guard let focused = watchedElement?.elementAttribute(kAXFocusedWindowAttribute) else { return nil }
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        // A hung app under the cursor mustn't freeze the notes.
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x),
                                               Float(primaryScreenHeight - location.y), &hit) == .success,
              let hit, let subrole: String = hit.attribute(kAXSubroleAttribute),
              let window = hit.elementAttribute(kAXWindowAttribute), CFEqual(window, focused) else { return nil }
        return subrole
    }

    // MARK: Focus

    private func frontmostAppChanged(to app: NSRunningApplication?) {
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Typing in a note: keep watching the app underneath so its notes stay put.
            onChange?(.ownApp)
            return
        }
        // Straight to the new app's window (AX answers within its timeout): reporting "nothing" in between
        // would take down a note that is about to show again, and it would flash.
        startWatching(app)
        refresh()
    }

    private func startWatching(_ app: NSRunningApplication?) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        destroyWatched = []
        watchedApp = app
        watchedElement = nil
        claudePoll?.invalidate()
        claudePoll = nil
        terminalPoll?.invalidate()
        terminalPoll = nil
        guard let app else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        watchedElement = element

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let provider = Unmanaged<WindowContextProvider>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { provider.windowChanged(element, notification: name) }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        if app.bundleIdentifier == ClaudePages.bundleID {
            enableClaude()
            // Switching conversations moves focus inside the page, at the same moment the address changes.
            AXObserverAddNotification(created, element, kAXFocusedUIElementChangedNotification as CFString, refcon)
            let poll = Timer(timeInterval: Self.claudePollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClaudePage() }
            }
            poll.tolerance = 0.1
            RunLoop.main.add(poll, forMode: .common)
            claudePoll = poll
        } else if BrowserPages.isBrowser(app.bundleIdentifier) {
            let poll = Timer(timeInterval: Self.claudePollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkBrowserPage() }
            }
            poll.tolerance = 0.1
            RunLoop.main.add(poll, forMode: .common)
            claudePoll = poll
        }
        if let bundleID = app.bundleIdentifier, TerminalSessions.bundleIDs.contains(bundleID) {
            let poll = Timer(timeInterval: Self.terminalPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkTerminalSession() }
            }
            poll.tolerance = 0.2
            RunLoop.main.add(poll, forMode: .common)
            terminalPoll = poll
        }
        // Common modes, so windows keep being followed while a menu or alert is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func windowChanged(_ element: AXUIElement, notification: String) {
        switch notification {
        case kAXUIElementDestroyedNotification:
            if let id = identities.forget(element) {
                finderFolders.forget([id])
                terminalSessions.forget([id])
                onWindowsGone?([id])
            }
            refresh()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Keyboard tiling, zoom and app-driven resizes animate too: watch the window until it is still.
            // Its notes only step aside if the frame actually keeps changing.
            if !isMoving, !ticker.isRunning { refresh() }
            refreshWhenWatchEnds = true
            serverLookupFailed = false
            watch(for: Self.watchWindow)
        default:
            refresh()
        }
    }

    /// Document-based apps report the window's file as a URL string.
    private static func filePath(fromDocument document: String) -> String? {
        URL(string: document).flatMap(DocumentPaths.path(of:))
    }

    /// Reads Claude's page again and reports the window if it changed. Not while a note is being typed in
    /// (Hintlet is in front) or the window moves, and only once the window has been read at all.
    private func checkClaudePage() {
        guard claudePages.consent == true, !isMoving, !ticker.isRunning, let last = lastWindow,
              let app = watchedApp, let element = watchedElement,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              claudePages.pageMayHaveChanged(),
              let window = element.elementAttribute(kAXFocusedWindowAttribute) else { return }
        if claudePages.page(of: app, element: element, window: window) != last.claudePage { refresh() }
    }

    /// Reads which Claude Code session the terminal's front tab shows and reports the window if it changed.
    private func checkTerminalSession() {
        guard !isMoving, !ticker.isRunning, let last = lastWindow, let app = watchedApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        let page = terminalSessions.page(of: app, window: last.id, titled: last.title, number: last.serverKey?.number) { [weak self] in
            self?.folderChanged()
        }
        if page != last.claudePage { refresh() }
    }

    /// Reads the browser's page again if its address may have changed. Not while a note is being typed in or
    /// the window moves.
    private func checkBrowserPage() {
        guard !isMoving, !ticker.isRunning, lastWindow != nil, let app = watchedApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              browserPages.pageMayHaveChanged() else { return }
        refresh()
    }

    /// Asks Claude for its full tree (once the user has agreed). `whenReady` runs, after the page has been
    /// read again, once the tree has had time to fill in (at once if it already has).
    func enableClaude(whenReady: (@MainActor () -> Void)? = nil) {
        guard let app = watchedApp, app.bundleIdentifier == ClaudePages.bundleID else {
            whenReady?()
            return
        }
        let justAsked = claudePages.enable(in: app)
        guard justAsked || claudePages.isWarmingUp(app) else {
            whenReady?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudePages.treeDelay) { [weak self] in
            self?.refresh()
            whenReady?()
        }
    }

    /// Finder found out (or corrected) which folder the focused window shows. Not in the middle of a move:
    /// the app's frame lags behind the window server's then, and the move reports the window when it ends.
    private func folderChanged() {
        if isMoving || ticker.isRunning {
            refreshWhenWatchEnds = true
        } else {
            refresh()
        }
    }

    private static func isFinderDesktop(role: String?, title: String, frame: CGRect) -> Bool {
        role != kAXWindowRole as String
            || (title.isEmpty && NSScreen.screens.contains { $0.frame.size == frame.size })
    }

    private func focusedWindow(of app: NSRunningApplication, element: AXUIElement,
                               waitingForFolder: Bool = false) -> ObservedWindow? {
        guard let window = element.elementAttribute(kAXFocusedWindowAttribute),
              let topLeftFrame = window.frame else { return nil }
        let id = identities.id(for: window, pid: app.processIdentifier)
        if let observer, !destroyWatched.contains(where: { CFEqual($0, window) }) {
            // Many apps only report a window closing to observers registered on that window.
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            destroyWatched.append(window)
        }
        var title: String = window.attribute(kAXTitleAttribute) ?? ""
        var documentPath = (window.attribute(kAXDocumentAttribute) as String?).flatMap(Self.filePath(fromDocument:))
        if app.bundleIdentifier == FinderFolders.bundleID,
           Self.isFinderDesktop(role: window.attribute(kAXRoleAttribute), title: title, frame: topLeftFrame),
           let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            // With no folder window in front, Finder reports the desktop: an untitled, screen-sized
            // "window". It is the Desktop folder, so its notes are that folder's.
            documentPath = DocumentPaths.path(of: desktop)
            title = FileManager.default.displayName(atPath: desktop.path)
        } else if documentPath == nil, app.bundleIdentifier == FinderFolders.bundleID {
            documentPath = waitingForFolder
                ? finderFolders.folderNow(of: id, titled: title)
                // Reported with the folder as last known (none the first time); its notes show, or are
                // corrected, once Finder answers. Checked again on coming back, as two folders can share a name.
                : finderFolders.folder(of: id, titled: title, checkAgain: lastWindow?.id != id) { [weak self] in
                    self?.folderChanged()
                }
        }
        var serverKey: ServerWindowKey?
        if let number = window.serverWindowNumber, let launched = app.launchDate {
            serverKey = ServerWindowKey(number: number, processID: app.processIdentifier, appLaunchedAt: launched)
        }
        var claudePage: ClaudePage?
        if app.bundleIdentifier == ClaudePages.bundleID {
            claudePage = claudePages.page(of: app, element: element, window: window)
        } else if let bundleID = app.bundleIdentifier, TerminalSessions.bundleIDs.contains(bundleID) {
            // Reported with the tab as last known; corrected once the terminal answers.
            claudePage = waitingForFolder
                ? terminalSessions.pageNow(of: app, window: id, titled: title, number: serverKey?.number)
                : terminalSessions.page(of: app, window: id, titled: title, number: serverKey?.number) { [weak self] in self?.folderChanged() }
        }
        var browserPage: BrowserPage?
        if BrowserPages.isBrowser(app.bundleIdentifier), documentPath == nil {
            browserPage = browserPages.page(in: window, windowTitle: title)
        }
        return ObservedWindow(
            id: id,
            appName: app.localizedName ?? app.bundleIdentifier ?? "",
            title: title,
            frame: ScreenCoordinates.appKitRect(fromTopLeft: topLeftFrame, primaryScreenHeight: primaryScreenHeight),
            isMinimized: window.attribute(kAXMinimizedAttribute) ?? false,
            isFullScreen: window.attribute(Self.fullScreenAttribute) ?? false,
            bundleID: app.bundleIdentifier,
            documentPath: documentPath,
            claudePage: claudePage,
            browserPage: browserPage,
            serverKey: serverKey
        )
    }
}

/// The height of the menu-bar screen: AX, window-server and AppKit coordinates are all anchored to it (report 0003).
@MainActor
private var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// The window server's view of windows, in AppKit coordinates.
@MainActor
private enum ServerWindows {
    /// The on-screen window of `pid` that is the AX window just reported: the same size, and at or
    /// near the same place (the AX frame may already lag behind a drag that has begun).
    static func find(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { info -> (id: CGWindowID, distance: CGFloat)? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, let candidate = Self.frame(from: info),
                  candidate.size == frame.size else { return nil }
            return (id, hypot(candidate.minX - frame.minX, candidate.minY - frame.minY))
        }
        return candidates.filter { $0.distance < maxLag }.min { $0.distance < $1.distance }?.id
    }

    private static let maxLag: CGFloat = 80

    static func frame(of id: CGWindowID) -> CGRect? {
        // The array holds raw window numbers, not NSNumbers.
        var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &raw, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]], let info = list.first else { return nil }
        return frame(from: info)
    }

    private static func frame(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let topLeft = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return ScreenCoordinates.appKitRect(fromTopLeft: topLeft, primaryScreenHeight: primaryScreenHeight)
    }
}

/// Calls `onFrame` once per display refresh while started.
@MainActor
private final class FrameTicker: NSObject {
    var onFrame: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        guard link == nil, let screen = NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(displayRefreshed))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    var isRunning: Bool { link != nil }

    @objc private func displayRefreshed() {
        onFrame?()
    }
}

/// Hands out a `WindowID` per AX window element for this run, comparing elements with `CFEqual`.
private struct WindowIdentities {
    private var known: [(element: AXUIElement, pid: pid_t, id: WindowID)] = []
    private var next: UInt64 = 1

    mutating func id(for element: AXUIElement, pid: pid_t) -> WindowID {
        if let match = known.first(where: { CFEqual($0.element, element) }) { return match.id }
        let id = WindowID(next)
        next += 1
        known.append((element, pid, id))
        return id
    }

    mutating func forget(_ element: AXUIElement) -> WindowID? {
        guard let index = known.firstIndex(where: { CFEqual($0.element, element) }) else { return nil }
        return known.remove(at: index).id
    }

    mutating func forget(pid: pid_t) -> [WindowID] {
        let gone = known.filter { $0.pid == pid }.map(\.id)
        known.removeAll { $0.pid == pid }
        return gone
    }
}
