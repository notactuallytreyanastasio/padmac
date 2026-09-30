import Foundation
import Security

/// Pairing codes, one per Mac name.
enum Keychain {
    private static let service = "com.bgrayson.remotemac.pairing"

    static func code(for host: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: host, kSecReturnData: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ code: String?, for host: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: host]
        SecItemDelete(q as CFDictionary)
        guard let code else { return }
        var add = q
        add[kSecValueData] = Data(code.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
