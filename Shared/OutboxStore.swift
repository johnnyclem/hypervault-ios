import Foundation
import HyperVaultKit

/// The outbox on disk: a small JSON list in the shared container, so a keep made from the share
/// sheet while offline is still there when the app next opens. The rules live in `Outbox`.
enum OutboxStore {
    private static let key = "hv.outbox"

    static func load() -> [OutboxItem] {
        guard let data = SharedConfig.defaults.data(forKey: key) else { return [] }
        return (try? HVCoding.decoder(.verbatim).decode([OutboxItem].self, from: data)) ?? []
    }

    static func save(_ items: [OutboxItem]) {
        if items.isEmpty {
            SharedConfig.defaults.removeObject(forKey: key)
        } else if let data = try? HVCoding.encoder(.verbatim).encode(items) {
            SharedConfig.defaults.set(data, forKey: key)
        }
    }

    static func add(_ item: OutboxItem) {
        save(Outbox.adding(item, to: load()))
    }

    /// Removes what has been handled and leaves anything added since it was read.
    static func remove(ids: Set<String>) {
        save(load().filter { !ids.contains($0.id) })
    }

    static var count: Int { load().count }
}
