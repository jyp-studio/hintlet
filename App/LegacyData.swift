import Foundation

/// Hintlet used to be `com.jyp.stickycontext`. The first run under the new ID brings the notes and the settings
/// along; the old copies stay where they were, as a backup.
///
/// What can't come along: macOS grants Accessibility and Automation to an app ID, so they are asked for again, and
/// API keys in the Keychain belong to the old app, so they are typed in again.
enum LegacyData {
    static let oldBundleID = "com.jyp.stickycontext"
    private static let migratedKey = "migratedFromStickyContext"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey), let newID = Bundle.main.bundleIdentifier, newID != oldBundleID else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent(oldBundleID, isDirectory: true)
        let newFolder = support.appendingPathComponent(newID, isDirectory: true)
        if FileManager.default.fileExists(atPath: oldFolder.path), !FileManager.default.fileExists(atPath: newFolder.path) {
            try? FileManager.default.copyItem(at: oldFolder, to: newFolder)
        }
        // Settings already set under the new ID win.
        for (key, value) in defaults.persistentDomain(forName: oldBundleID) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
