import Security
import XCTest
@testable import HyperVault

/// How the session is kept in the Keychain: which class, not synchronised, and that an item an older build stored in
/// the plain class is moved over without losing it.
final class KeychainSecureStoreTests: XCTestCase {
    private let account = "hypervault.session"

    private func freshStore() -> KeychainSecureStore {
        // A service of its own, so a test never touches the app's session; no group, which an unsigned test build is refused.
        KeychainSecureStore(service: "store.hypervault.tests.\(UUID().uuidString)", accessGroup: nil)
    }

    /// The class an item is kept in, or nil when there is no such item (or this build may not use the Keychain).
    private func storedClass(of store: KeychainSecureStore) -> String? {
        var query = store.baseQuery(account, useGroup: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let found = result as? [String: Any]
        else { return nil }
        return found[kSecAttrAccessible as String] as? String
    }

    // MARK: What is written, without the Keychain

    func testTheSessionIsKeptAfterFirstUnlockOnThisDeviceOnly() {
        XCTAssertEqual(KeychainSecureStore.accessibility as String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let written = KeychainSecureStore.attributes(storing: Data("v".utf8))
        XCTAssertEqual(written[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(written[kSecValueData as String] as? Data, Data("v".utf8))
    }

    func testTheItemIsNeverSynchronisedAndKeepsItsGroupAndName() {
        let store = KeychainSecureStore(service: "store.hypervault.session", accessGroup: "ABCDE12345.store.hypervault.shared")
        let query = store.baseQuery(account, useGroup: true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, "it does not go to iCloud Keychain")
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "ABCDE12345.store.hypervault.shared", "the extensions read the same item")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "store.hypervault.session")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account)
        XCTAssertNil(store.baseQuery(account, useGroup: false)[kSecAttrAccessGroup as String], "the fallback is the app's own Keychain")
    }

    func testAnItemInThePlainClassIsMovedAndOneAlreadyThereIsLeftAlone() {
        let old: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let change = KeychainSecureStore.migration(of: old)
        XCTAssertEqual(change?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(change?.count, 1, "only the class changes; the value, the name and the group stay as they are")

        let current: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertNil(KeychainSecureStore.migration(of: current))
        XCTAssertNotNil(KeychainSecureStore.migration(of: [:]), "an item that does not say its class is put in it")
    }

    // MARK: The Keychain itself

    func testAWrittenSessionComesBackAndIsInTheClass() async throws {
        let store = freshStore()
        await store.set(Data("one".utf8), for: account)
        defer { SecItemDelete(store.baseQuery(account, useGroup: false) as CFDictionary) }
        let read = await store.get(account)
        try XCTSkipIf(read == nil, "this build may not use the Keychain")

        XCTAssertEqual(read, Data("one".utf8))
        XCTAssertEqual(storedClass(of: store), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        await store.set(Data("two".utf8), for: account)
        let second = await store.get(account)
        XCTAssertEqual(second, Data("two".utf8), "a second write replaces the value")
        await store.remove(account)
        let removed = await store.get(account)
        XCTAssertNil(removed)
    }

    func testAnItemAnOlderBuildStoredIsMovedOverWhenItIsRead() async throws {
        let store = freshStore()
        var add = store.baseQuery(account, useGroup: false)
        add[kSecValueData as String] = Data("signed in".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        defer { SecItemDelete(store.baseQuery(account, useGroup: false) as CFDictionary) }
        try XCTSkipIf(SecItemAdd(add as CFDictionary, nil) != errSecSuccess, "this build may not use the Keychain")
        XCTAssertEqual(storedClass(of: store), kSecAttrAccessibleAfterFirstUnlock as String)

        let read = await store.get(account)
        XCTAssertEqual(read, Data("signed in".utf8), "the session is still there to be read")
        XCTAssertEqual(storedClass(of: store), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "and now in the new class")
        let again = await store.get(account)
        XCTAssertEqual(again, Data("signed in".utf8), "and still readable afterwards")
    }
}
