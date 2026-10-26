import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

final class ConfigAndCacheTests: XCTestCase {
    func testCapabilitiesDecodeTheRealShape() throws {
        let json = """
        {"app_url":"https://hypervault.store","api_catalog":"https://hypervault.store/api","api_version":"2026-07-15",
         "auth":{"supabase_url":"https://p.supabase.co","supabase_anon_key":"anon","bearer_header":"Authorization","api_key_header":"X-HyperVault-Key","invite_gated":true},
         "features":{"configured":true,"deep_memory":false,"key_encryption":true,"smart_context":true,"truth_ledger":true,"truth_notary":false,"on_device_inference":true,"dreaming":true,"realm_home_page":true},
         "limits":{"artifact_bytes":1000000,"source_prompt_chars":10000,"chat_message_chars":100000,"memory_bytes":500000,"import_bytes":50000000,"max_backends":20,"max_mcp_servers":20,"max_pro_subdomains":10,"rate_limit_per_min":{"api_key":60,"user":120}},
         "providers":[{"id":"openai","label":"OpenAI","protocol":"openai","defaultBaseUrl":"https://api.openai.com/v1","defaultModel":"gpt-4o","requiresKey":true,"defaultEmbeddingModel":"text-embedding-3-small"},
                      {"id":"ollama","label":"Ollama","protocol":"openai","defaultBaseUrl":"http://localhost:11434/v1","defaultModel":"llama3","requiresKey":false}],
         "domains":[{"domain":"vault.cool","tagline":"Your vault","featured":true,"available":true}],
         "themes":[{"id":"modern-dark","name":"Modern Dark","mode":"dark"}],
         "user":{"id":"u1","email":"a@b.co","via":"bearer"}}
        """
        let caps = try HVCoding.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.appUrl, "https://hypervault.store")
        XCTAssertEqual(caps.supabase, SupabaseConfig(url: URL(string: "https://p.supabase.co")!, anonKey: "anon"))
        XCTAssertTrue(caps.features.truthLedger)
        XCTAssertFalse(caps.features.deepMemory)
        XCTAssertEqual(caps.limits.maxProSubdomains, 10)
        XCTAssertEqual(caps.providers.map(\.id), ["openai", "ollama"])
        XCTAssertEqual(caps.providers[0].defaultEmbeddingModel, "text-embedding-3-small")
        XCTAssertFalse(caps.providers[1].requiresKey)
        XCTAssertEqual(caps.domains.first?.domain, "vault.cool")
        XCTAssertEqual(caps.user?.via, "bearer")
    }

    func testCapabilitiesToleratesAnEmptyOrFutureServer() throws {
        let empty = try HVCoding.decoder().decode(Capabilities.self, from: Data("{}".utf8))
        XCTAssertNil(empty.supabase)
        XCTAssertEqual(empty.limits.artifactBytes, 1_000_000)
        let future = try HVCoding.decoder().decode(Capabilities.self, from: Data(#"{"features":{"hologram":true},"brand_new":[1,2]}"#.utf8))
        XCTAssertTrue(future.features.smartContext)
    }

    func testServerConfigInput() {
        XCTAssertEqual(ServerConfig(userInput: "hypervault.store")?.baseURL.absoluteString, "https://hypervault.store")
        XCTAssertEqual(ServerConfig(userInput: " https://my.host/ ")?.baseURL.absoluteString, "https://my.host")
        XCTAssertEqual(ServerConfig(userInput: "http://localhost:3000")?.baseURL.absoluteString, "http://localhost:3000")
        XCTAssertNil(ServerConfig(userInput: "http://example.com"), "plain http is only for localhost")
        XCTAssertNil(ServerConfig(userInput: "   "))
    }

    func temporaryCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-cache-" + UUID().uuidString))
    }

    func testDiskCacheRoundTripAndPerUserIsolation() async {
        let cache = temporaryCache()
        await cache.store(["a", "b"], key: "yours", namespace: "user-1")
        let mine = await cache.entry([String].self, key: "yours", namespace: "user-1")
        let theirs = await cache.entry([String].self, key: "yours", namespace: "user-2")
        XCTAssertEqual(mine?.value, ["a", "b"])
        XCTAssertNil(theirs)

        await cache.clear(namespace: "user-1")
        let cleared = await cache.entry([String].self, key: "yours", namespace: "user-1")
        XCTAssertNil(cleared)
    }

    func testCachedLoadYieldsCacheThenNetwork() async throws {
        let cache = temporaryCache()
        await cache.store(["old"], key: "k", namespace: "n")
        var seen: [(Loaded<[String]>.Source, [String])] = []
        for try await loaded in cachedLoad(cache: cache, namespace: "n", key: "k", fetch: { () async throws -> [String] in ["new"] }) {
            seen.append((loaded.source, loaded.value))
        }
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].0, .cache)
        XCTAssertEqual(seen[0].1, ["old"])
        XCTAssertEqual(seen[1].0, .network)
        XCTAssertEqual(seen[1].1, ["new"])
        let persisted = await cache.entry([String].self, key: "k", namespace: "n")
        XCTAssertEqual(persisted?.value, ["new"])
    }

    func testCachedLoadFallsBackToCacheWhenOffline() async throws {
        let cache = temporaryCache()
        await cache.store(["old"], key: "k", namespace: "n")
        var last: Loaded<[String]>?
        for try await loaded in cachedLoad(cache: cache, namespace: "n", key: "k", fetch: { () async throws -> [String] in throw HVError.transport("offline") }) {
            last = loaded
        }
        XCTAssertEqual(last?.value, ["old"])
        XCTAssertTrue(last?.isStale ?? false)
        XCTAssertEqual(last?.refreshError, .transport("offline"))
    }

    func testCachedLoadThrowsWithNothingCached() async {
        let cache = temporaryCache()
        do {
            for try await _ in cachedLoad(cache: cache, namespace: "n", key: "k", fetch: { () async throws -> [String] in throw HVError.api(APIFailure(status: 500, message: "boom")) }) {}
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "boom")
        }
    }
}
