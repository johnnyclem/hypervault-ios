import HyperVaultKit
import SwiftUI

/// The person's connected models: list, connect, edit, disconnect. Keys go to
/// the server once and are never kept here.
@MainActor
@Observable
final class ChatBackendsModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var backends: [ChatBackend] = []
    private(set) var isStale = false
    /// Told whenever the list changes, so the screen that opened this one can follow.
    var onChange: (([ChatBackend]) -> Void)?

    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String
    static let cacheKey = "chat.backends"

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    func load() async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: Self.cacheKey) {
                try await client.send(.backends)
            }
            for try await loaded in stream {
                backends = loaded.value
                isStale = loaded.isStale
                phase = .loaded
                onChange?(backends)
            }
        } catch {
            if backends.isEmpty { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    /// Connects a model; the server tests it first (up to a minute). Returns the
    /// server's sentence, which says what the test found.
    func connect(_ draft: ChatBackendDraft, serverCanStoreKeys: Bool) async throws -> String {
        let saved = try await client.send(.connectBackend(draft, serverCanStoreKeys: serverCanStoreKeys))
        backends.removeAll { $0.id == saved.backend.id }
        backends.insert(saved.backend, at: 0)
        phase = .loaded
        await changed()
        return saved.message ?? "\(saved.backend.name) connected."
    }

    func update(_ backend: ChatBackend, draft: ChatBackendDraft, supportsEmbeddings: Bool, serverCanStoreKeys: Bool) async throws -> String {
        let saved = try await client.send(
            .updateBackend(id: backend.id, draft, supportsEmbeddings: supportsEmbeddings, serverCanStoreKeys: serverCanStoreKeys)
        )
        if let index = backends.firstIndex(where: { $0.id == backend.id }) { backends[index] = saved.backend }
        await changed()
        return saved.message ?? "\(saved.backend.name) updated."
    }

    /// Removes the row now; puts it back if the server refuses.
    func disconnect(_ backend: ChatBackend) async throws {
        guard let index = backends.firstIndex(where: { $0.id == backend.id }) else { return }
        let removed = backends.remove(at: index)
        onChange?(backends)
        do {
            _ = try await client.send(.disconnectBackend(id: backend.id))
            await changed()
        } catch let error as HVError {
            backends.insert(removed, at: min(index, backends.count))
            onChange?(backends)
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The model was not disconnected."))
        }
    }

    private func changed() async {
        await cache.store(backends, key: Self.cacheKey, namespace: namespace)
        onChange?(backends)
    }
}
