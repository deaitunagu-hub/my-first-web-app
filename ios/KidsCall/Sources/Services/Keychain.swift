import Foundation
import Security

/// Minimal Keychain wrapper. Everything is stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the device identity
/// is readable when a VoIP push wakes the app but is never copied to another
/// device through backups or iCloud Keychain.
enum Keychain {
    private static let service = "com.example.kidscall"

    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ key: String, _ data: Data) -> Bool {
        delete(key)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func readJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = read(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func writeJSON<T: Encodable>(_ key: String, _ value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return write(key, data)
    }
}
