import Foundation
import HyperVaultKit
import Security

/// The session lives in the Keychain, in a group the app, the share extension and
/// the widgets all belong to, so a keep from the share sheet is signed in as
/// the same person without asking again.
///
/// It is kept `AfterFirstUnlockThisDeviceOnly`: the extensions can still read it
/// once the phone has been unlocked since it started, and it does not travel in a
/// backup or to a new phone. An item an older build stored in the plain
/// `AfterFirstUnlock` class is moved over the next time it is read, in place and
/// under the same service, account and group, so nobody is signed out by it.
struct KeychainSecureStore: SecureStore {
    let service: String
    let accessGroup: String?

    /// The one class every item is kept in.
    static let accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    init(service: String = "store.hypervault.session", accessGroup: String? = SharedConfig.keychainGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func get(_ key: String) async -> Data? {
        var useGroup = true
        var result: AnyObject?
        var status = read(key, useGroup: useGroup, into: &result)
        if status == errSecMissingEntitlement || status == errSecParam {
            useGroup = false
            status = read(key, useGroup: useGroup, into: &result)
        }
        guard status == errSecSuccess,
              let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data
        else { return nil }
        if let change = Self.migration(of: found) {
            SecItemUpdate(baseQuery(key, useGroup: useGroup) as CFDictionary, change as CFDictionary)
        }
        return data
    }

    /// The item with its value and its attributes, the class among them.
    private func read(_ key: String, useGroup: Bool, into result: inout AnyObject?) -> OSStatus {
        var query = baseQuery(key, useGroup: useGroup)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    func set(_ value: Data, for key: String) async {
        for useGroup in [true, false] {
            let query = baseQuery(key, useGroup: useGroup)
            var status = SecItemUpdate(query as CFDictionary, Self.attributes(storing: value) as CFDictionary)
            if status == errSecItemNotFound {
                let add = query.merging(Self.attributes(storing: value)) { _, written in written }
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

    // MARK: What is written

    func baseQuery(_ key: String, useGroup: Bool) -> [String: Any] {
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

    /// What goes in with a value, whether the item is new or already there: a write also moves an old item to the class.
    static func attributes(storing value: Data) -> [String: Any] {
        [kSecValueData as String: value, kSecAttrAccessible as String: accessibility]
    }

    /// What to change on an item that was read back with these attributes, or nil when it is where it belongs.
    static func migration(of stored: [String: Any]) -> [String: Any]? {
        let current = (stored[kSecAttrAccessible as String] as? String) == (accessibility as String)
        return current ? nil : [kSecAttrAccessible as String: accessibility]
    }
}
