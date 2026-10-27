import XCTest
@testable import HyperVault

/// The system's cache keeps nothing the server said to a signed-in person: not the vault's names and labels, not the list
/// of what they kept.
final class HVURLCacheTests: XCTestCase {
    private func makeCache() -> HVURLCache {
        HVURLCache(
            memoryCapacity: 1_000_000, diskCapacity: 0,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-urlcache-\(UUID().uuidString)")
        )
    }

    private func request(_ path: String, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://hv.test\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func answer(to request: URLRequest) -> CachedURLResponse {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return CachedURLResponse(response: response, data: Data(#"{"secrets":[{"name":"visa-4242"}]}"#.utf8), userInfo: nil, storagePolicy: .allowed)
    }

    func testTheAnswerToASignedInRequestIsNotStored() {
        let cache = makeCache()
        let signedIn = request("/api/secrets", token: "t0ken")
        cache.storeCachedResponse(answer(to: signedIn), for: signedIn)
        XCTAssertNil(cache.cachedResponse(for: signedIn))
        XCTAssertNil(cache.cachedResponse(for: request("/api/secrets")), "nor under the plain address")
    }

    func testTheAnswerToAnotherRequestIsStoredAsTheSystemWould() {
        let cache = makeCache()
        let plain = request("/icons/icon-512.png")
        cache.storeCachedResponse(answer(to: plain), for: plain)
        XCTAssertNotNil(cache.cachedResponse(for: plain))
    }

    func testATaskForASignedInRequestStoresNothingEither() {
        let cache = makeCache()
        let signedIn = request("/api/secrets", token: "t0ken")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: signedIn)
        cache.storeCachedResponse(answer(to: signedIn), for: task)
        XCTAssertNil(cache.cachedResponse(for: signedIn))
        XCTAssertNil(cache.cachedResponse(for: request("/api/secrets")))
    }

    func testOnlyARequestWithoutATokenMayBeStored() {
        XCTAssertTrue(HVURLCache.mayStore(request("/a/slug")))
        XCTAssertFalse(HVURLCache.mayStore(request("/api/yours", token: "t0ken")))
        XCTAssertFalse(HVURLCache.mayStore(nil), "a task that does not say what it asked is not trusted with an answer")
    }

    func testInstallingIsTheSharedCacheAndHappensOnce() {
        HVURLCache.install()
        let installed = URLCache.shared
        XCTAssertTrue(installed is HVURLCache)
        HVURLCache.install()
        XCTAssertTrue(URLCache.shared === installed, "a second install does not replace it")
    }
}
