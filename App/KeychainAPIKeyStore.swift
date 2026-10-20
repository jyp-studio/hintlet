import Foundation
import Security
import StickyContextCore

/// An API key in the user's login Keychain: one generic password per service that only Hintlet writes. It
/// never goes into the notes file, its backups or an export. Read once and then kept in memory for this run.
final class KeychainAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String
    /// What the user sees in Keychain Access.
    private let label: String
    private let lock = NSLock()
    /// nil: not read yet; .some(nil): read, and there is none.
    private var cached: String??

    static func claude() -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: "com.jyp.stickycontext.claude-api", account: "Claude API key",
                            label: String(localized: "Hintlet Claude API key"))
    }

    static func openAI() -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: "com.jyp.stickycontext.openai-api", account: "OpenAI API key",
                            label: String(localized: "Hintlet OpenAI API key"))
    }

    private init(service: String, account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    struct KeychainError: Error {
        let status: OSStatus
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            let key = (item as? Data).map { String(decoding: $0, as: UTF8.self) }
            cached = .some(key)
            return key
        case errSecItemNotFound:
            cached = .some(nil)
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cached = .some(key)
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        cached = .some(nil)
    }
}
