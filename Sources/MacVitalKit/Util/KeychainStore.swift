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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
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
