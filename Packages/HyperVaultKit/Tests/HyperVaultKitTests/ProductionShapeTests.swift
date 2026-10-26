import XCTest
@testable import HyperVaultKit

/// The Kit's models against the shapes a real deployment sent when an API key asked for them (field names, types,
/// nulls and array nesting captured from production on 2026-10-26; the values here are made up). Most models
/// decode leniently, so every check counts what came out: a renamed or mis-cased field would show up as an empty
/// list, not an error.
final class ProductionShapeTests: XCTestCase {
    private let when = "2026-10-24T14:02:11.123456+00:00"

    private func client(_ routes: [MockRoute]) -> HVClient {
        HVClient(baseURL: URL(string: "https://prod.test")!, transport: MockTransport(routes: routes), tokens: StaticTokenProvider(), retry: .none)
    }

    func testCapabilitiesForAnAPIKeyNameTheCallerWithoutAnEmail() async throws {
        let json = #"""
        {"app_url":"https://www.example.com","api_catalog":"https://www.example.com/api","api_version":"2026-07-15",
         "auth":{"supabase_url":"https://p.supabase.co","supabase_anon_key":"sb_publishable_x","bearer_header":"Authorization","api_key_header":"X-HyperVault-Key","invite_gated":true},
         "features":{"configured":true,"deep_memory":false,"key_encryption":true,"smart_context":true,"truth_ledger":true,"truth_notary":false,"on_device_inference":true,"dreaming":true,"realm_home_page":true},
         "limits":{"artifact_bytes":1000000,"source_prompt_chars":10000,"chat_message_chars":100000,"memory_bytes":500000,"import_bytes":50000000,"max_backends":20,"max_mcp_servers":20,"max_pro_subdomains":10,"rate_limit_per_min":{"api_key":60,"user":120}},
         "providers":[{"defaultBaseUrl":"https://api.openai.com/v1","defaultEmbeddingModel":"text-embedding-3-small","defaultModel":"gpt-4o","id":"openai","label":"OpenAI","protocol":"openai","requiresKey":true}],
         "domains":[{"available":true,"domain":"vault.cool","featured":true,"tagline":"Your vault."}],
         "themes":[{"id":"midnight","mode":"dark","name":"Midnight"}],
         "user":{"id":"7d1f0a52-0000-4000-8000-000000000001","email":null,"via":"api_key"}}
        """#
        let caps = try await client([.json(.get, "/api/capabilities", json)]).send(.capabilities)
        XCTAssertEqual(caps.user?.id, "7d1f0a52-0000-4000-8000-000000000001")
        XCTAssertNil(caps.user?.email)
        XCTAssertEqual(caps.limits.chatMessageChars, 100_000)
        XCTAssertEqual(caps.providers.count, 1)
        XCTAssertEqual(caps.domains.count, 1)
        XCTAssertEqual(caps.themes.count, 1)
        XCTAssertNotNil(caps.supabase)
    }

    func testYoursKeepsEveryRowAndItsNulls() async throws {
        func row(_ id: String, _ kind: String) -> String {
            #"{"href":"/a/\#(id)","id":"\#(id)","kind":"\#(kind)","last_opened_at":null,"name":"Name \#(id)","summary":"Summary","updated_at":"\#(when)"}"#
        }
        let json = #"{"recent":[\#(row("a1", "page")),\#(row("a2", "memory"))],"results":[\#(row("a1", "page")),\#(row("a2", "memory")),\#(row("a3", "file")),\#(row("a4", "group")),\#(row("a5", "key"))]}"#
        let list = try await client([.json(.get, "/api/yours", json)]).send(.yours())
        XCTAssertEqual(list.recent.count, 2)
        XCTAssertEqual(list.results.count, 5)
        XCTAssertEqual(Set(list.results.map(\.kind)), [.page, .memory, .file, .group, .key])
        XCTAssertTrue(list.results.allSatisfy { $0.updatedAt != nil && $0.lastOpenedAt == nil })
    }

    func testArtifactsKeepEveryRowWithoutAnIdOrAMutableFlag() async throws {
        let item = #"{"created_at":"\#(when)","icon":null,"is_jsx":false,"is_pwa":true,"slug":"page-one-ab12","source_prompt":null,"tags":["a","b"],"title":"Page one","type":"html","url":"https://x.test/a/page-one-ab12","visibility":"private"}"#
        let json = #"{"items":[\#(item),\#(item),\#(item)]}"#
        let list = try await client([.json(.get, "/api/artifacts", json)]).send(.artifacts)
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items.first?.slug, "page-one-ab12")
        XCTAssertEqual(list.items.first?.tags, ["a", "b"])
    }

    func testGroupsKeepEveryRow() async throws {
        let item = #"{"created_at":"\#(when)","id":"g1","slug":"group-one-cd34","tags":[],"title":"Group","url":"https://x.test/g/group-one-cd34","visibility":"public"}"#
        let list = try await client([.json(.get, "/api/artifact-groups", #"{"items":[\#(item),\#(item)]}"#)]).send(.artifactGroups)
        XCTAssertEqual(list.items.count, 2)
    }

    func testTheConnectionsGraphKeepsEveryEdgeKind() async throws {
        let json = #"""
        {"connections":[{"a_id":"a","b_id":"b","created_at":"\#(when)","id":"c1","kind":"manual"},{"a_id":"a","b_id":"c","created_at":"\#(when)","id":"c2","kind":"auto"}],
         "memory_links":[{"a_id":"m1","b_id":"m2","created_at":"\#(when)","id":"l1","kind":"manual"}],
         "memory_artifact_links":[{"artifact_id":"a","created_at":"\#(when)","id":"x1","kind":"manual","memory_id":"m1"},{"artifact_id":"b","created_at":"\#(when)","id":"x2","kind":"auto","memory_id":"m2"},{"artifact_id":"c","created_at":"\#(when)","id":"x3","kind":"auto","memory_id":"m1"}]}
        """#
        let route = MockRoute.json(.get, "/api/connections", json)
        let edges = try await client([route]).send(.artifactEdges)
        XCTAssertEqual(edges.connections.count, 2)
        XCTAssertEqual(edges.memoryArtifactLinks.count, 3)
        let memory = try await client([route]).send(.memoryConnections)
        XCTAssertEqual(memory.memoryLinks.count, 1)
        XCTAssertEqual(memory.bridges.count, 3)
    }

    func testChatSettingsHaveTheFourFlags() async throws {
        let settings = try await client([.json(.get, "/api/chat-settings", #"{"smart_context":true,"deep_memory":false,"polytician":false,"truth":true}"#)]).send(.chatSettings)
        XCTAssertTrue(settings.smartContext)
        XCTAssertFalse(settings.deepMemory)
        XCTAssertTrue(settings.truth)
    }

    func testBackendsAndConversationsAndRoomsKeepEveryRow() async throws {
        let backend = #"{"base_url":"https://api.openai.com/v1","created_at":"\#(when)","default_model":"gpt-4o","embedding_model":null,"id":"b1","key_hint":"…abcd","last_used_at":null,"name":"OpenAI","provider":"openai"}"#
        let usedBackend = #"{"base_url":"https://api.anthropic.com","created_at":"\#(when)","default_model":"claude","embedding_model":null,"id":"b2","key_hint":"…wxyz","last_used_at":"\#(when)","name":"Claude","provider":"anthropic"}"#
        let provider = #"{"defaultBaseUrl":"https://api.openai.com/v1","defaultEmbeddingModel":"text-embedding-3-small","defaultModel":"gpt-4o","id":"openai","label":"OpenAI","protocol":"openai","requiresKey":true}"#
        let conversation = #"{"created_at":"\#(when)","id":"c1","model":"gpt-4o","share_slug":null,"source_platform":"hypervault","title":"A chat","updated_at":"\#(when)","visibility":"private"}"#
        let api = client([
            .json(.get, "/api/backends", #"{"backends":[\#(backend),\#(usedBackend)],"providers":[\#(provider)]}"#),
            .json(.get, "/api/conversations", #"{"conversations":[\#(conversation),\#(conversation),\#(conversation)]}"#),
            .json(.get, "/api/rooms", #"{"rooms":[]}"#),
        ])
        let backends = try await api.send(.backends)
        XCTAssertEqual(backends.count, 2)
        XCTAssertNil(backends.first?.lastUsedAt)
        XCTAssertNotNil(backends.last?.lastUsedAt)
        let canvas = try await api.send(.canvasBackends)
        XCTAssertEqual(canvas.count, 2)
        let conversations = try await api.send(.conversations)
        XCTAssertEqual(conversations.count, 3)
        let rooms = try await api.send(.rooms)
        XCTAssertEqual(rooms.count, 0)
    }

    func testMemoriesAndTheMindKeepEveryRow() async throws {
        let memory = #"{"created_at":"\#(when)","id":"m1","source":"manual","summary":"Summary","tags":["x","y"],"title":"A memory"}"#
        let branch = #"{"created_at":"\#(when)","head_commit_id":"k1","id":"br1","is_default":true,"memory_count":51,"name":"main"}"#
        let commit = #"{"author_kind":"agent","change_counts":{"created":1,"updated":2,"deleted":0,"links":3},"created_at":"\#(when)","id":"k1","merge_parent_commit_id":null,"message":"Added a thing","parent_commit_id":"k0"}"#
        let api = client([
            .json(.get, "/api/memories", #"{"branch":"main","memories":[\#(memory),\#(memory)]}"#),
            .json(.get, "/api/mind/branches", #"{"branches":[\#(branch),\#(branch)]}"#),
            .json(.get, "/api/mind/commits", #"{"branch":"main","commits":[\#(commit),\#(commit),\#(commit)]}"#),
        ])
        let list = try await api.send(.memoryList())
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(list.memories.count, 2)
        XCTAssertEqual(list.memories.first?.tags, ["x", "y"])
        let branches = try await api.send(.mindBranches)
        XCTAssertEqual(branches.branches.count, 2)
        XCTAssertEqual(branches.branches.first?.isDefault, true)
        let commits = try await api.send(.mindCommits(limit: 3))
        XCTAssertEqual(commits.commits.count, 3)
        XCTAssertEqual(commits.commits.first?.changeCounts.links, 3)
    }

    func testDreamsDigestAndJobsDecodeTheirEnvelopes() async throws {
        let api = client([
            .json(.get, "/api/dreams", #"{"dreaming_enabled":true,"last_run_at":"\#(when)","pending_count":0,"runs":[]}"#),
            .json(.get, "/api/dreams/settings", #"{"enabled":true,"last_run_at":"\#(when)"}"#),
            .json(.get, "/api/digest", #"{"digestion_enabled":false,"pending_count":0,"runs":[]}"#),
            .json(.get, "/api/digest/settings", #"{"enabled":false}"#),
            .json(.get, "/api/jobs", #"{"jobs":[]}"#),
        ])
        let dreams = try await api.send(.dreamQueue)
        XCTAssertTrue(dreams.dreamingEnabled)
        XCTAssertNotNil(dreams.lastRunAt)
        let settings = try await api.send(.dreamSettings)
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.lastRunAt)
        let digest = try await api.send(.digestQueue)
        XCTAssertFalse(digest.digestionEnabled)
        let digestSettings = try await api.send(.digestSettings)
        XCTAssertFalse(digestSettings.enabled)
        let jobs = try await api.send(.backgroundJobs)
        XCTAssertEqual(jobs.jobs.count, 0)
    }
}
