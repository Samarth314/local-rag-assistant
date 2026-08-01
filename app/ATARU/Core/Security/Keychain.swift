import Foundation
import Security

/// Minimal Keychain wrapper. The bearer token is the only secret ATARU stores
/// and it never touches UserDefaults, caches, or logs.
struct KeychainStore {

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain operation failed (\(status))."
            }
        }
    }

    let service: String

    init(service: String = "com.ataru.client.credentials") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Stores (or replaces) a secret. Accessible only after first unlock, on
    /// this device only — never synced to iCloud.
    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var attributes = query(account)
        SecItemDelete(attributes as CFDictionary)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func get(_ account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    @discardableResult
    func remove(_ account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary) == errSecSuccess
    }

    static let bearerTokenAccount = "ataru.bearer.token"
}
