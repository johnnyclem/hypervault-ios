import Foundation

/// The cache the system keeps for the app's requests, on disk and in memory. HyperVault keeps its own copies of what it
/// shows offline (`DiskCache`, with file protection), so this one has no business holding what the server told a
/// signed-in person: the names and labels in their vault, the list of what they kept, the markup of a private page. It
/// refuses to store the response to any request that carries their token, and is the system's own cache for the rest.
///
/// Installed once, before the first request, as `URLCache.shared`, which is what `URLSession.shared` (and so the client
/// of the app and of its extensions) reads and writes.
final class HVURLCache: URLCache, @unchecked Sendable {
    /// Whether the answer to this request may be kept.
    static func mayStore(_ request: URLRequest?) -> Bool {
        guard let request else { return false }
        return request.value(forHTTPHeaderField: "Authorization") == nil
    }

    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        guard Self.mayStore(request) else { return }
        super.storeCachedResponse(cachedResponse, for: request)
    }

    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for dataTask: URLSessionDataTask) {
        guard Self.mayStore(dataTask.currentRequest ?? dataTask.originalRequest) else { return }
        super.storeCachedResponse(cachedResponse, for: dataTask)
    }

    /// Replaces the shared cache with this one, once per process, and empties what the old one held: an earlier build
    /// let it keep these answers.
    static func install() {
        guard !(URLCache.shared is HVURLCache) else { return }
        let old = URLCache.shared
        old.removeAllCachedResponses()
        URLCache.shared = HVURLCache(memoryCapacity: old.memoryCapacity, diskCapacity: old.diskCapacity, directory: nil)
    }
}
