import Foundation
import Security
import Synchronization

/// API keys live in the login Keychain, readable only by this device. They share one item, read once and then
/// kept in memory: with a self-signed app macOS asks again for every item after each update, so one item means
/// at most one prompt.
public enum Keychain {
    private struct KeychainStatus: Error {
        let status: OSStatus

        init(_ status: OSStatus) {
            self.status = status
        }
    }

    private struct State {
        var secrets: [String: String]?
        /// The user refused access: do not ask again until they save a key.
        var denied = false
    }

    private static let service = "dev.redos.RedOS"
    private static let vaultAccount = "secrets"
    /// One item per secret, before 0.14.
    private static let legacyAccounts = SystemTwoProvider.allCases.map(\.rawValue) + ["jev", "mcp.server.token"]
    private static let state = Mutex(State())

    /// Reads the secrets ahead of time, off the main thread, so a Keychain prompt never freezes the app.
    public static func preload() async {
        await Task.detached(priority: .userInitiated) { _ = secret(for: vaultAccount) }.value
    }

    public static func secret(for account: String) -> String? {
        state.withLock { state in
            if state.secrets == nil, !state.denied {
                state.secrets = loadVault()
                state.denied = state.secrets == nil
            }
            return state.secrets?[account]
        }
    }

    /// An empty or nil secret removes it.
    public static func setSecret(_ secret: String?, for account: String) throws {
        try state.withLock { state in
            // Never overwrite secrets that could not be read.
            guard var secrets = state.secrets ?? loadVault() else {
                throw ProviderError.commandFailed(String(localized: "RedOS can't read its Keychain item."))
            }
            secrets[account] = secret?.isEmpty == false ? secret : nil
            try save(secrets)
            state = State(secrets: secrets)
        }
    }

    /// nil when the item exists but could not be read (access refused).
    private static func loadVault() -> [String: String]? {
        switch read(vaultAccount) {
        case .success(let data):
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        case .failure(let error) where error.status != errSecItemNotFound:
            return nil
        case .failure:
            break
        }
        var secrets: [String: String] = [:]
        for account in legacyAccounts {
            if case .success(let data) = read(account), let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                secrets[account] = value
            }
        }
        if !secrets.isEmpty, (try? save(secrets)) != nil {
            legacyAccounts.forEach { SecItemDelete(identity($0) as CFDictionary) }
        }
        return secrets
    }

    private static func read(_ account: String) -> Result<Data, KeychainStatus> {
        var query = identity(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return .failure(KeychainStatus(status)) }
        return .success(data)
    }

    private static func save(_ secrets: [String: String]) throws {
        let identity = identity(vaultAccount)
        guard !secrets.isEmpty else {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let data = try JSONEncoder().encode(secrets)
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ProviderError.commandFailed(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
        }
    }

    private static func identity(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
