import Foundation
import Security
enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jigaoyi.mikaweb", kSecAttrAccount as String: "api-key"]
    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        var status = SecItemDelete(query as CFDictionary)
        if !value.isEmpty {
            var q = query
            q[kSecValueData as String] = Data(value.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess || (value.isEmpty && status == errSecItemNotFound) else { throw MikaError("Keychain 保存失败（\(status)）") }
    }
}
