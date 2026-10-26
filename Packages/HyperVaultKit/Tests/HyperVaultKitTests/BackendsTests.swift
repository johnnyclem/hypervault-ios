import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures follow app/api/backends/route.ts.
final class BackendsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    let registry = ChatProviders.builtIn

    func spec(_ id: String) -> Capabilities.ProviderSpec { ChatProviders.spec(for: id, in: registry)! }

    func testListDecodes() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/backends", """
        {"backends":[
          {"id":"b1","name":"Claude","provider":"anthropic","base_url":null,"default_model":"claude-opus-4-8","embedding_model":null,"key_hint":"sk-ant-\u{2026}","created_at":"2026-10-01T10:00:00.000Z","last_used_at":"2026-10-25T09:00:00.000Z"},
          {"id":"b2","name":"My Ollama","provider":"ollama","base_url":"https://tunnel.example.com/v1","default_model":"llama3.3","embedding_model":"nomic","key_hint":null,"created_at":"2026-10-02T10:00:00.000Z","last_used_at":null}
        ],"providers":[{"id":"openai","label":"OpenAI","protocol":"openai","defaultBaseUrl":"https://api.openai.com/v1","defaultModel":"gpt-4o","requiresKey":true}]}
        """)])
        let list = try await client(transport).send(.backends)
        XCTAssertEqual(list.map(\.name), ["Claude", "My Ollama"])
        XCTAssertEqual(list[0].keyHint, "sk-ant-\u{2026}")
        XCTAssertNotNil(list[0].lastUsedAt)
        XCTAssertNil(list[1].lastUsedAt)
        XCTAssertEqual(list[1].baseUrl, "https://tunnel.example.com/v1")
        XCTAssertEqual(list[1].modelLine, "llama3.3")
    }

    func testConnectSendsTheKeyOnceAndNothingBlank() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/backends", """
        {"backend":{"id":"b3","name":"Claude","provider":"anthropic","base_url":null,"default_model":"claude-opus-4-8","embedding_model":null,"key_hint":"sk-ant-\u{2026}","created_at":"2026-10-26T10:00:00Z","last_used_at":null},
         "message":"Claude connected \u{2014} test reply received from claude-opus-4-8."}
        """)])
        let draft = ChatBackendDraft(provider: "anthropic", name: "  ", apiKey: " sk-ant-secret ", model: "")
        let saved = try await client(transport).send(.connectBackend(draft, serverCanStoreKeys: true))
        XCTAssertEqual(saved.backend.id, "b3")
        XCTAssertEqual(saved.message, "Claude connected \u{2014} test reply received from claude-opus-4-8.")
        let request = await transport.requests(matching: "/api/backends").first
        XCTAssertEqual(requestJSON(request), ["provider": "anthropic", "api_key": "sk-ant-secret"])
        XCTAssertEqual(request?.timeoutInterval, backendTestTimeout)
    }

    func testAKeyIsNeverSentToAServerThatCannotStoreIt() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/backends", #"{"backend":{"id":"b","name":"x","provider":"ollama"},"message":"ok"}"#)])
        var draft = ChatBackendDraft(provider: "ollama", name: "Home", apiKey: "leftover-key", baseURL: "https://t.example.com/v1", model: "llama3.3")
        draft.skipTest = true
        _ = try await client(transport).send(.connectBackend(draft, serverCanStoreKeys: false))
        let body = requestJSON(await transport.requests(matching: "/api/backends").first)
        XCTAssertNil(body?["api_key"])
        XCTAssertEqual(body?["skip_test"], true)
        XCTAssertEqual(body?["base_url"], "https://t.example.com/v1")
        XCTAssertEqual(body?["name"], "Home")
    }

    func testEditKeepsTheStoredKeyWhenTheFieldIsBlank() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/backends", #"{"backend":{"id":"b1","name":"Work","provider":"openai"},"message":"Work updated."}"#)])
        let backend = ChatBackend(id: "b1", name: "OpenAI", provider: "openai", baseUrl: nil, defaultModel: "gpt-4o", embeddingModel: nil, keyHint: "sk-proj\u{2026}")
        var draft = ChatBackendDraft(editing: backend)
        draft.name = "Work"
        draft.embeddingModel = ""
        _ = try await client(transport).send(.updateBackend(id: "b1", draft, supportsEmbeddings: true, serverCanStoreKeys: true))
        var body = requestJSON(await transport.requests(matching: "/api/backends").last)
        XCTAssertNil(body?["api_key"])
        XCTAssertEqual(body?["id"], "b1")
        XCTAssertEqual(body?["name"], "Work")
        XCTAssertEqual(body?["embedding_model"], "")
        XCTAssertEqual(body?["default_model"], "gpt-4o")

        draft.apiKey = "sk-new"
        _ = try await client(transport).send(.updateBackend(id: "b1", draft, supportsEmbeddings: false, serverCanStoreKeys: true))
        body = requestJSON(await transport.requests(matching: "/api/backends").last)
        XCTAssertEqual(body?["api_key"], "sk-new")
        XCTAssertNil(body?["embedding_model"])
    }

    func testDisconnect() async throws {
        let transport = MockTransport(routes: [.json(.delete, "/api/backends", #"{"message":"Backend disconnected."}"#)])
        _ = try await client(transport).send(.disconnectBackend(id: "b1"))
        let request = await transport.requests.first
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(requestJSON(request), ["id": "b1"])
    }

    func testTheConnectionTestFailureIsTheServersSentence() async {
        let message = "Connection test failed: 401 invalid x-api-key"
        let transport = MockTransport(routes: [.failure(.post, "/api/backends", status: 400, message: message)])
        do {
            _ = try await client(transport).send(.connectBackend(ChatBackendDraft(apiKey: "bad"), serverCanStoreKeys: true))
            XCTFail("expected 400")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, message)
        } catch { XCTFail("\(error)") }
    }

    // MARK: form rules (the route's own validation, ahead of the round trip)

    func testRequiredKeysAndCustomEndpoints() {
        var draft = ChatBackendDraft(provider: "anthropic")
        XCTAssertEqual(draft.problem(spec: spec("anthropic"), serverCanStoreKeys: true), "Anthropic (Claude) needs an API key.")
        draft.apiKey = "k"
        XCTAssertNil(draft.problem(spec: spec("anthropic"), serverCanStoreKeys: true))

        var custom = ChatBackendDraft(provider: "custom")
        XCTAssertEqual(custom.problem(spec: spec("custom"), serverCanStoreKeys: true), "Custom endpoints need a base URL.")
        custom.baseURL = "https://llm.example.com/v1"
        XCTAssertEqual(custom.problem(spec: spec("custom"), serverCanStoreKeys: true), "Custom endpoints need a model.")
        custom.model = "m"
        XCTAssertNil(custom.problem(spec: spec("custom"), serverCanStoreKeys: true))

        XCTAssertNil(ChatBackendDraft(provider: "ollama").problem(spec: spec("ollama"), serverCanStoreKeys: true))
    }

    func testEmbeddingsAreOnlyForOpenAIStyleBackends() {
        var draft = ChatBackendDraft(provider: "anthropic", apiKey: "k", embeddingModel: "x")
        XCTAssertNotNil(draft.problem(spec: spec("anthropic"), serverCanStoreKeys: true))
        draft.provider = "openai"
        XCTAssertNil(draft.problem(spec: spec("openai"), serverCanStoreKeys: true))
        XCTAssertTrue(spec("openai").supportsEmbeddings)
        XCTAssertFalse(spec("gemini").supportsEmbeddings)
    }

    func testTheKeyRuleWhenTheServerCannotEncrypt() {
        let draft = ChatBackendDraft(provider: "openai", apiKey: "k")
        XCTAssertEqual(draft.problem(spec: spec("openai"), serverCanStoreKeys: false), ChatBackendDraft.noKeyStorageLine)
        XCTAssertEqual(ChatBackendDraft(provider: "openai").problem(spec: spec("openai"), serverCanStoreKeys: false), ChatBackendDraft.noKeyStorageLine)
        // A local runtime needs no key, so it still connects.
        XCTAssertNil(ChatBackendDraft(provider: "ollama").problem(spec: spec("ollama"), serverCanStoreKeys: false))
    }

    func testEditingNeedsNoKeyAndTheLimitBlocksNewOnes() {
        let draft = ChatBackendDraft(provider: "openai")
        XCTAssertNil(draft.problem(spec: spec("openai"), serverCanStoreKeys: true, editing: true))
        XCTAssertEqual(
            ChatBackendDraft(provider: "ollama").problem(spec: spec("ollama"), serverCanStoreKeys: true, connectedCount: 20, maxBackends: 20),
            "Backend limit reached (20)."
        )
    }

    func testChoicesFoldTheCustomStyles() {
        XCTAssertEqual(ChatProviders.choices(from: []).map(\.id).last, "custom")
        XCTAssertFalse(ChatProviders.choices(from: []).contains { $0.id == "custom-anthropic" })
        let server = [Capabilities.ProviderSpec(id: "openai", label: "OpenAI")]
        XCTAssertEqual(ChatProviders.choices(from: server).map(\.id), ["openai"])
        XCTAssertEqual(ChatProviders.shortName(for: "anthropic", in: []), "Anthropic")
        XCTAssertEqual(ChatProviders.shortName(for: "ollama", in: []), "Ollama")
    }

    func testLocalAddressesGetTheReachabilityNote() {
        XCTAssertTrue(ChatBackendHints.isLocalAddress("http://localhost:11434/v1"))
        XCTAssertTrue(ChatBackendHints.isLocalAddress("192.168.1.20:1234"))
        XCTAssertTrue(ChatBackendHints.isLocalAddress("http://10.0.0.5/v1"))
        XCTAssertTrue(ChatBackendHints.isLocalAddress("http://172.20.1.1/v1"))
        XCTAssertTrue(ChatBackendHints.isLocalAddress("http://mac.local:1234"))
        XCTAssertFalse(ChatBackendHints.isLocalAddress("https://api.openai.com/v1"))
        XCTAssertFalse(ChatBackendHints.isLocalAddress("http://172.32.0.1"))
        XCTAssertNotNil(ChatBackendHints.reachabilityNote(provider: spec("ollama"), baseURL: ""))
        XCTAssertNil(ChatBackendHints.reachabilityNote(provider: spec("ollama"), baseURL: "https://tunnel.example.com/v1"))
        XCTAssertNil(ChatBackendHints.reachabilityNote(provider: spec("openai"), baseURL: ""))
        XCTAssertNotNil(ChatBackendHints.reachabilityNote(provider: spec("custom"), baseURL: "http://192.168.1.2:8080"))
    }
}
