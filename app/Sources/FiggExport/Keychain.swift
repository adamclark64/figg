import Foundation
import Security

/// Generic-password Keychain storage for secrets such as the Atlassian API token.
public enum Keychain {
    static let service = "dev.adamclark.figg"

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves, or deletes when `value` is empty.
    ///
    /// An item already there is updated in place, never deleted first. If
    /// the Keychain refuses the write (it is locked, say), the secret that
    /// was stored stays stored, and the caller gets false.
    @discardableResult
    public static func write(_ account: String, _ value: String) -> Bool {
        write(account, value, using: .system)
    }

    /// The three Keychain calls a write can make, so the rule above is
    /// tested without a real Keychain.
    struct Calls {
        var update: (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
        var add: (_ item: [String: Any]) -> OSStatus
        var delete: (_ query: [String: Any]) -> OSStatus

        static let system = Calls(
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) })
    }

    static func write(_ account: String, _ value: String, using calls: Calls) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = calls.delete(base)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = calls.update(base, [kSecValueData as String: data])
        if updated == errSecSuccess { return true }
        // Anything but "not there yet" is a refusal: leave what is stored.
        guard updated == errSecItemNotFound else { return false }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return calls.add(item) == errSecSuccess
    }
}
