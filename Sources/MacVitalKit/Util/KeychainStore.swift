import Foundation
import Security

/// The API key never touches UserDefaults or a plist. It lives in the keychain
/// and is read on demand.
public enum KeychainStore {
    public static let service = "com.macvital.MacVital"

    public enum Key: String {
        case anthropicAPIKey = "anthropic-api-key"
    }

    public static func set(_ value: String?, for key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                Log.app.error("keychain delete failed: \(status, privacy: .public)")
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            attributes.forEach { newItem[$0.key] = $0.value }
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.app.error("keychain write failed: \(status, privacy: .public)")
        }
    }

    public static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func has(_ key: Key) -> Bool {
        get(key)?.isEmpty == false
    }
}
