import CoreSpotlight
import HyperVaultKit
import UniformTypeIdentifiers

/// Puts what has been kept into system search, on this phone only, so typing a page's name in
/// Spotlight opens it here. Keys are never indexed: their names are not for a search box. Each
/// result carries a `hypervault://` link, which the app already knows how to open.
enum SpotlightIndexer {
    static let domain = "store.hypervault.kept"
    static let preferenceKey = "pref.spotlight"

    /// Whether the person has search turned on. Off while the Face ID lock is on: a result in system search
    /// cannot be put behind a prompt, so names and summaries would be readable from the Home Screen without it.
    static var isEnabled: Bool {
        let wanted = UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
        return wanted && !isLockOn
    }

    private static var isLockOn: Bool {
        UserDefaults.standard.bool(forKey: PrefKey.biometricLock)
    }

    /// Replaces the index with the person's current list.
    static func index(_ items: [KeptItem]) {
        // Turning the lock on clears the index, but an index from before the lock was on, or from an older
        // version, is cleared here too, the first time the list loads.
        if isLockOn {
            clear()
            return
        }
        guard isEnabled else { return }
        let searchable: [CSSearchableItem] = items.compactMap { item in
            guard let link = item.appLink?.absoluteString else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = item.name
            attributes.contentDescription = item.summary.isEmpty ? item.kind.singular : item.summary
            attributes.contentModificationDate = item.updatedAt
            attributes.lastUsedDate = item.lastOpenedAt
            return CSSearchableItem(uniqueIdentifier: link, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            guard !searchable.isEmpty else { return }
            index.indexSearchableItems(searchable) { _ in }
        }
    }

    /// Forgets everything: on sign-out, or when the person turns it off.
    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
