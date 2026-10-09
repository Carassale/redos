import Foundation
import Security

/// API keys live in the login Keychain, readable only by this device.
public enum Keychain {
    private static let service = "dev.redos.RedOS"

    public static func secret(for account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// An empty or nil secret removes the item.
    public static func setSecret(_ secret: String?, for account: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(identity as CFDictionary)
        guard let secret, !secret.isEmpty else { return }
        var item = identity
        item[kSecValueData] = Data(secret.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderError.commandFailed(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
        }
    }
}
