import Foundation
import Security

enum KeychainHelper {
    private static let legacyPath = NSHomeDirectory() + "/.thirdhand-api-key"
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.thirdhand.openrouter",
        kSecAttrAccount as String: "api-key"
    ]

    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ControllerError.invalid("Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")")
        }
        try? FileManager.default.removeItem(atPath: legacyPath)
    }

    static func getAPIKey() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        guard status == errSecItemNotFound,
              let legacy = try? String(contentsOfFile: legacyPath, encoding: .utf8) else { return nil }
        let key = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        do { try saveAPIKey(key); return key }
        catch { return nil }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(atPath: legacyPath)
    }
}
