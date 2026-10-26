import Foundation
import HyperVaultKit
import Security

/// The session lives in the Keychain, in a group the app, the share extension
/// and the widgets all belong to, so a keep from the share sheet is signed in as
/// the same person without asking again.
struct KeychainSecureStore: SecureStore {
    let service: String
    let accessGroup: String?

    init(service: String = "store.hypervault.session", accessGroup: String? = SharedConfig.keychainGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func get(_ key: String) async -> Data? {
        var query = baseQuery(key, useGroup: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement || status == errSecParam {
            query = baseQuery(key, useGroup: false)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ value: Data, for key: String) async {
        for useGroup in [true, false] {
            let query = baseQuery(key, useGroup: useGroup)
            let update: [String: Any] = [kSecValueData as String: value]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = value
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
            // Without the keychain-sharing entitlement (unsigned simulator
            // builds) the group is refused; fall back to the app's own keychain.
            if status != errSecMissingEntitlement && status != errSecParam { return }
        }
    }

    func remove(_ key: String) async {
        for useGroup in [true, false] {
            SecItemDelete(baseQuery(key, useGroup: useGroup) as CFDictionary)
        }
    }

    private func baseQuery(_ key: String, useGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        if useGroup, let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
