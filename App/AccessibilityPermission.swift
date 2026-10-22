import AppKit
import ApplicationServices

/// Explains why Hintlet needs Accessibility, sends the user to System Settings, and reports when it is granted.
@MainActor
final class AccessibilityPermission {
    /// Privacy & Security › Accessibility, renamed "Device Control and Data Access" in macOS 27.
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
    private static let pollInterval: TimeInterval = 1.5
    /// Stop waiting after a while; the next ⌘⌥N in a new run explains again.
    private static let pollLimit: TimeInterval = 10 * 60

    private var hasExplained = false
    private var pollTimer: Timer?

    var isGranted: Bool { AXIsProcessTrusted() }

    static var permissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? String(localized: "裝置控制與資料存取") : String(localized: "輔助使用")
    }

    /// Shows the explanation once per run; `onGranted` runs when the user has turned the permission on.
    /// Returns true when System Settings was opened, so the caller should leave the keyboard there.
    @discardableResult
    func requestIfNeeded(onGranted: @escaping @MainActor () -> Void) -> Bool {
        guard !isGranted, !hasExplained else { return false }
        hasExplained = true

        let alert = NSAlert()
        alert.messageText = String(localized: "讓便利貼跟著視窗出現")
        alert.informativeText = String(localized: """
        Hintlet 需要「\(Self.permissionName)」權限，才能知道你目前在哪個視窗，讓便利貼在切走時隱藏、回來時出現，並跟著視窗移動。

        請在「系統設定 › 隱私權與安全性 › \(Self.permissionName)」中打開「Hintlet」。

        Hintlet 只讀取視窗的位置與標題，不會記錄你的輸入，也不會上傳任何內容。

        沒有授權時，便利貼仍可使用，但會一直浮動顯示。
        """)
        // macOS's own prompt (or the pane) comes next; this only explains.
        alert.addButton(withTitle: String(localized: "繼續"))
        alert.addButton(withTitle: String(localized: "稍後"))
        AppPresence.comeForward()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        openSystemSettings(onGranted: onGranted)
        return true
    }


    /// The system process that shows macOS's "would like to control this computer" prompt.
    private static let promptBundleID = "com.apple.accessibility.universalAccessAuthWarn"

    /// Takes the user to the switch, one way only. macOS's own prompt is asked for first: asking is what puts this
    /// very build of Hintlet in the list, and the prompt's button opens the right pane. Only when no prompt came
    /// (macOS shows it once in a while, not every time) is the pane opened directly, so there are never two
    /// things on screen at once. Then waits a while for the user to turn the permission on.
    func openSystemSettings(onGranted: @escaping @MainActor () -> Void) {
        pollTimer?.invalidate()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let prompting = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.promptBundleID).isEmpty
            if !prompting, !AXIsProcessTrusted() { NSWorkspace.shared.open(Self.settingsURL) }
        }
        let deadline = Date().addingTimeInterval(Self.pollLimit)
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] timer in
            let granted = MainActor.assumeIsolated { self?.isGranted ?? false }
            if granted {
                timer.invalidate()
                MainActor.assumeIsolated { onGranted() }
            } else if Date() > deadline {
                timer.invalidate()
            }
        }
    }
}
