import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures are the routes' real output: app/api/mcp-servers (publicServer in
/// lib/smallchat/server-rows.ts), app/api/toolkits, app/api/registry.
final class ToolsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport, tokens: TokenProvider = FakeTokens(token: "t")) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: tokens, retry: RetryPolicy(maxAttempts: 2), sleep: { _ in })
    }

    // app/api/mcp-servers/route.ts GET: rows are snake_case, ciphers stripped.
    let listJSON = """
    {"servers":[
      {"id":"s1","name":"Linear","url":"https://mcp.linear.app/mcp","enabled":true,"disabled_tools":["delete_issue"],
       "tools_cache":[
         {"name":"list_issues","description":"List issues","input_schema":{"type":"object","properties":{"team_id":{"type":"string","description":"Which team"},"limit":{"type":["integer","null"]}},"required":["team_id"]}},
         {"name":"delete_issue","description":"Delete one","input_schema":{"type":"object"}}],
       "introspected_at":"2026-10-20T10:00:00.123456+00:00","registry_id":"app.linear/mcp","created_at":"2026-10-01T09:00:00+00:00",
       "has_auth":true,"secret_backed":true,"auth_type":"oauth"},
      {"id":"s2","name":"Notes","url":"https://notes.example.com/mcp","enabled":false,"disabled_tools":[],
       "tools_cache":[],"introspected_at":null,"registry_id":null,"created_at":"2026-10-02T09:00:00+00:00",
       "has_auth":true,"secret_backed":false}
    ]}
    """

    func testDecodesTheServerList() throws {
        let list = try HVCoding.decoder(.verbatim).decode(McpServerList.self, from: Data(listJSON.utf8))
        XCTAssertEqual(list.servers.map(\.id), ["s1", "s2"])
        let linear = list.servers[0]
        XCTAssertEqual(linear.authType, .oauth)
        XCTAssertTrue(linear.secretBacked)
        XCTAssertEqual(linear.host, "mcp.linear.app")
        XCTAssertEqual(linear.tools.count, 2)
        XCTAssertEqual(linear.enabledToolCount, 1)
        XCTAssertEqual(linear.status, .on)
        XCTAssertNotNil(linear.introspectedAt)
        // An older row with no `auth_type` falls back the way the web does.
        XCTAssertEqual(list.servers[1].authType, .headers)
        XCTAssertEqual(list.servers[1].status, .off)
        XCTAssertEqual(list.servers[1].enabledToolCount, 0)
    }

    func testToolParametersComeFromTheSchema() throws {
        let list = try HVCoding.decoder(.verbatim).decode(McpServerList.self, from: Data(listJSON.utf8))
        let parameters = list.servers[0].tools[0].parameters
        XCTAssertEqual(parameters.map(\.name), ["team_id", "limit"], "required first")
        XCTAssertEqual(parameters[0].summary, "Which team")
        XCTAssertTrue(parameters[0].isRequired)
        XCTAssertEqual(parameters[1].type, "integer | null")
        XCTAssertTrue(list.servers[0].tools[1].parameters.isEmpty)
    }

    func testListSurvivesACacheRoundTrip() throws {
        let list = try HVCoding.decoder(.verbatim).decode(McpServerList.self, from: Data(listJSON.utf8))
        let data = try HVCoding.encoder(.verbatim).encode(list)
        let again = try HVCoding.decoder(.verbatim).decode(McpServerList.self, from: data)
        XCTAssertEqual(again.servers.map(\.id), list.servers.map(\.id))
        XCTAssertEqual(again.servers[0].disabledTools, ["delete_issue"])
        XCTAssertEqual(again.servers[0].tools[0].inputSchema?["required"]?[0]?.string, "team_id")
    }

    func testAMinimalRowStillDecodes() throws {
        let server = try HVCoding.decoder(.verbatim).decode(McpServer.self, from: Data(#"{"id":"x","url":"https://a.example.com/mcp"}"#.utf8))
        XCTAssertEqual(server.name, "a.example.com")
        XCTAssertTrue(server.enabled)
        XCTAssertEqual(server.authType, .none)
        XCTAssertEqual(server.status, .noTools)
    }

    func testSwitchingToolsKeepsTheListSortedAndCapped() {
        let tools = (0..<600).map { McpToolInfo(name: String(format: "tool_%03d", $0)) }
        let server = McpServer(id: "s", name: "Big", url: "https://big.example.com", tools: tools)
        XCTAssertEqual(server.disabledTools(setting: "tool_002", enabled: false), ["tool_002"])
        XCTAssertEqual(server.disabledToolsSettingAll(enabled: true), [])
        let all = server.disabledToolsSettingAll(enabled: false)
        XCTAssertEqual(all.count, McpServer.maxDisabledTools, "the route keeps 500")
        XCTAssertEqual(all.first, "tool_000")

        var some = server
        some.disabledTools = ["b", "a"]
        XCTAssertEqual(some.disabledTools(setting: "a", enabled: true), ["b"])
        XCTAssertEqual(some.disabledTools(setting: "c", enabled: false), ["a", "b", "c"])
    }

    func testStatusWhenEveryToolIsOff() {
        var server = McpServer(id: "s", name: "S", url: "https://s.example.com", tools: [McpToolInfo(name: "a"), McpToolInfo(name: "b")])
        server.disabledTools = ["a", "b"]
        XCTAssertEqual(server.status, .allToolsOff)
    }

    // MARK: Requests

    func testAddRequestKeepsHeaderNamesAndNeverPrintsThem() throws {
        let request = McpAddRequest(
            url: "https://mcp.example.com/mcp", name: " Example ",
            headers: ["X-Api-Key": "s3cret"], registryId: "io.example/mcp", saveToVault: true
        )
        XCTAssertEqual(request.body["headers"]?["X-Api-Key"]?.string, "s3cret")
        XCTAssertEqual(request.body["registry_id"]?.string, "io.example/mcp")
        XCTAssertEqual(request.body["save_to_vault"]?.bool, true)
        XCTAssertEqual(request.body["name"]?.string, "Example")
        XCTAssertFalse("\(request)".contains("s3cret"))
        XCTAssertFalse(String(describing: request).contains("s3cret"))

        let bare = McpAddRequest(url: "https://mcp.example.com/mcp")
        XCTAssertNil(bare.body["headers"])
        XCTAssertNil(bare.body["save_to_vault"], "off is left out, not sent as false")
        XCTAssertNil(bare.body["name"])
    }

    func testBareTokensBecomeBearerOnTheAuthorizationHeader() {
        XCTAssertEqual(McpAuthHeader.make(name: "Authorization", token: " abc123 "), ["Authorization": "Bearer abc123"])
        XCTAssertEqual(McpAuthHeader.make(name: "", token: "abc"), ["Authorization": "Bearer abc"])
        XCTAssertEqual(McpAuthHeader.make(name: "authorization", token: "Basic dXNlcjpwYXNz"), ["authorization": "Basic dXNlcjpwYXNz"])
        XCTAssertEqual(McpAuthHeader.make(name: "X-Api-Key", token: "abc"), ["X-Api-Key": "abc"])
        XCTAssertNil(McpAuthHeader.make(name: "Authorization", token: "   "))
    }

    func testAddressesAreReadKindly() {
        XCTAssertEqual(McpServerURL.parse("mcp.example.com/mcp/")?.absoluteString, "https://mcp.example.com/mcp")
        XCTAssertEqual(McpServerURL.parse(" https://a.example.com ")?.absoluteString, "https://a.example.com")
        XCTAssertEqual(McpServerURL.parse("http://localhost:8080/mcp")?.absoluteString, "http://localhost:8080/mcp")
        XCTAssertNil(McpServerURL.parse("not a url"))
        XCTAssertNil(McpServerURL.parse("ftp://example.com"))
        XCTAssertNil(McpServerURL.parse("https://nodots"))
        XCTAssertNil(McpServerURL.parse(""))
    }

    // MARK: Calls

    func testAddSucceedsAndSendsTheBody() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/mcp-servers", """
        {"server":{"id":"new","name":"Example","url":"https://mcp.example.com/mcp","enabled":true,"disabled_tools":[],
         "tools_cache":[{"name":"ping","description":"","input_schema":{"type":"object"}}],"introspected_at":"2026-10-24T01:02:03.000Z",
         "registry_id":"io.example/mcp","created_at":"2026-10-24T01:02:03.000Z","has_auth":false,"secret_backed":false,"auth_type":"none"},
         "message":"Connected — 1 tool discovered. Compile to use them in chat."}
        """)])
        let answer = try await client(transport).send(.addMcpServer(McpAddRequest(url: "https://mcp.example.com/mcp", registryId: "io.example/mcp")))
        XCTAssertEqual(answer.server.id, "new")
        XCTAssertEqual(answer.message, "Connected — 1 tool discovered. Compile to use them in chat.")
        let sent = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(body["url"]?.string, "https://mcp.example.com/mcp")
        XCTAssertEqual(body["registry_id"]?.string, "io.example/mcp")
        XCTAssertEqual(sent[0].timeoutInterval, 100, "the server may spend 60 s looking inside")
    }

    func testTheServersOwnSentencesSurvive() async {
        let transport = MockTransport(routes: [
            .failure(.post, "/api/mcp-servers", status: 409, message: "That server is already added."),
        ])
        await assertFailure(transport, status: 409, message: "That server is already added.")

        let unreachable = MockTransport(routes: [
            .failure(.post, "/api/mcp-servers", status: 502, message: "Could not connect to the MCP server: HTTP 404"),
        ])
        await assertFailure(unreachable, status: 502, message: "Could not connect to the MCP server: HTTP 404")

        let full = MockTransport(routes: [
            .failure(.post, "/api/mcp-servers", status: 400, message: "Limit of 20 MCP servers reached."),
        ])
        await assertFailure(full, status: 400, message: "Limit of 20 MCP servers reached.")
    }

    private func assertFailure(_ transport: MockTransport, status: Int, message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client(transport).send(.addMcpServer(McpAddRequest(url: "https://x.example.com")))
            XCTFail("expected a failure", file: file, line: line)
        } catch let error as HVError {
            XCTAssertEqual(error.status, status, file: file, line: line)
            XCTAssertEqual(error.userMessage, message, file: file, line: line)
            XCTAssertFalse(error.isMcpAuthRequired, file: file, line: line)
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
        }
    }

    func testAnAuthChallengeIsNotASignOut() async {
        // The route answers 401 for the *MCP server's* login. The client retries
        // once with a refreshed token, then hands over the route's own answer.
        let transport = MockTransport(routes: [.json(.post, "/api/mcp-servers", """
        {"error":"This MCP server requires authorization.","auth_required":true,"url":"https://mcp.linear.app/mcp","name":"Linear","registry_id":"app.linear/mcp"}
        """, status: 401)])
        let tokens = FakeTokens(token: "stale", next: "fresh")
        do {
            _ = try await client(transport, tokens: tokens).send(.addMcpServer(McpAddRequest(url: "https://mcp.linear.app/mcp")))
            XCTFail("expected a challenge")
        } catch let error as HVError {
            XCTAssertTrue(error.isMcpAuthRequired)
            XCTAssertEqual(error.userMessage, "This MCP server requires authorization.")
            XCTAssertNotEqual(error, .unauthorized)
            XCTAssertEqual(error.failure?.body?["name"]?.string, "Linear")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testOAuthStartAndItsUnavailableAnswer() async throws {
        let ok = MockTransport(routes: [.json(.post, "/api/mcp-servers/oauth/start", #"{"authorization_url":"https://auth.example.com/authorize?client_id=c&state=s"}"#)])
        let start = try await client(ok).send(.startMcpOAuth(McpOAuthStartRequest(url: "https://mcp.example.com/mcp", name: "Example", saveToVault: true)))
        XCTAssertEqual(start.authorizationUrl.host, "auth.example.com")
        let sent = await ok.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(body["save_to_vault"]?.bool, true)
        XCTAssertNil(body["server_id"])

        // app/api/mcp-servers/oauth/start/route.ts: 409 + oauth_available:false.
        let none = MockTransport(routes: [.json(.post, "/api/mcp-servers/oauth/start", #"{"error":"This server doesn't advertise an OAuth login. Add an API token instead.","oauth_available":false}"#, status: 409)])
        do {
            _ = try await client(none).send(.startMcpOAuth(McpOAuthStartRequest(url: "https://mcp.example.com/mcp")))
            XCTFail("expected 409")
        } catch let error as HVError {
            XCTAssertTrue(error.isMcpOAuthUnavailable)
            XCTAssertEqual(error.userMessage, "This server doesn't advertise an OAuth login. Add an API token instead.")
        }
    }

    func testUpdateWritesVerbatimKeysAndCapsTheList() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/mcp-servers/s1", #"{"server":{"id":"s1","name":"Linear","url":"https://l.example.com"}}"#)])
        let names = (0..<520).map { "t\($0)" }
        let answer = try await client(transport).send(.updateMcpServer(id: "s1", enabled: false, disabledTools: names))
        XCTAssertEqual(answer.server.id, "s1")
        let sent = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(body["enabled"]?.bool, false)
        XCTAssertEqual(body["disabled_tools"]?.array?.count, 500)
        XCTAssertNil(body["name"])
    }

    func testOAuthCallbacksAreReadIfTheServerEverSendsThem() {
        XCTAssertEqual(McpOAuthResult(callback: URL(string: "hypervault://mcp-oauth?ok=1")!), .connected)
        XCTAssertEqual(McpOAuthResult(callback: URL(string: "hypervault://mcp-oauth?error=access_denied&error_description=You%20said%20no")!), .failed("You said no"))
        XCTAssertEqual(McpOAuthResult(callback: URL(string: "hypervault://mcp-oauth?ok=0&message=Token%20exchange%20failed.")!), .failed("Token exchange failed."))
        XCTAssertEqual(McpOAuthResult(callback: URL(string: "hypervault://mcp-oauth")!), .unknown)
    }

    func testReplacingHeadersWritesThemVerbatim() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/mcp-servers/s1", #"{"server":{"id":"s1","name":"A","url":"https://a.example.com"}}"#)])
        _ = try await client(transport).send(.replaceMcpHeaders(id: "s1", headers: ["X-Api-Key": "k"]))
        let sent = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(body["headers"]?["X-Api-Key"]?.string, "k")
        XCTAssertNil(body["enabled"])
    }

    func testRefreshAndDelete() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/mcp-servers/s1/refresh", #"{"tools":[{"name":"a","description":"A","input_schema":{"type":"object"}}],"disabled_tools":[],"introspected_at":"2026-10-24T01:02:03.000Z"}"#),
            .json(.delete, "/api/mcp-servers/s1", #"{"ok":true,"message":"Removed. Compiled toolkits keep working until you compile again."}"#),
        ])
        let api = client(transport)
        let refreshed = try await api.send(.refreshMcpServer(id: "s1"))
        XCTAssertEqual(refreshed.tools.map(\.name), ["a"])
        XCTAssertNotNil(refreshed.introspectedAt)
        let removed = try await api.send(.deleteMcpServer(id: "s1"))
        XCTAssertEqual(removed.message, "Removed. Compiled toolkits keep working until you compile again.")
    }

    // MARK: Toolkit

    func testToolkitStatusAndStaleness() throws {
        // app/api/toolkits/route.ts: stats are camelCase, the rest snake_case.
        let json = """
        {"toolkit":{"id":"k1","stats":{"toolCount":42,"uniqueSelectorCount":38,"providerCount":3,"collisionCount":2},
         "embedder":{"kind":"local","model":"x"},"embedder_label":"semantic (MiniLM-L6-v2, 384d local)","compiled_at":"2026-10-24T01:02:03.123Z"},"stale":true}
        """
        let status = try HVCoding.decoder(.verbatim).decode(McpToolkitStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.toolkit?.stats.toolCount, 42)
        XCTAssertEqual(status.toolkit?.stats.collisionCount, 2)
        XCTAssertEqual(status.toolkit?.isLexical, false)
        XCTAssertTrue(status.stale)

        let empty = try HVCoding.decoder(.verbatim).decode(McpToolkitStatus.self, from: Data(#"{"toolkit":null,"stale":false}"#.utf8))
        XCTAssertNil(empty.toolkit)
        XCTAssertFalse(empty.compiled(since: Date(timeIntervalSince1970: 0)))
    }

    func testRecognisesACompileThatFinishedWhileTheConnectionWasDown() throws {
        let started = HVDate.parse("2026-10-24T01:00:00.000Z")!
        let landed = McpToolkitStatus(toolkit: McpToolkit(id: "k", compiledAt: started.addingTimeInterval(95)))
        let old = McpToolkitStatus(toolkit: McpToolkit(id: "k", compiledAt: started.addingTimeInterval(-3600)))
        XCTAssertTrue(landed.compiled(since: started))
        XCTAssertFalse(old.compiled(since: started))
    }

    func testCompileResultAndItsErrorSentence() async throws {
        // lib/smallchat/compile.ts CompileOutcome, written camelCase.
        let ok = """
        {"toolkitId":"k2","stats":{"toolCount":10,"uniqueSelectorCount":9,"providerCount":2,"collisionCount":1},
         "collisions":[{"selectorA":"list_tasks","selectorB":"get_tasks","similarity":0.93,"hint":"Rename one"}],
         "embedder":{"kind":"local"},"embedderLabel":"lexical fallback (256d hash)","embedderDegradeReason":"no available backend found",
         "skippedServers":[{"id":"s9","name":"Slow","error":"timeout (using cached tool list)"}]}
        """
        let transport = MockTransport(routes: [.json(.post, "/api/toolkits/compile", ok)])
        let result = try await client(transport).send(.compileMcpToolkit)
        XCTAssertEqual(result.toolkitId, "k2")
        XCTAssertEqual(result.stats.uniqueSelectorCount, 9)
        XCTAssertTrue(result.isLexical)
        XCTAssertEqual(result.embedderDegradeReason, "no available backend found")
        XCTAssertEqual(result.skippedServers.map(\.name), ["Slow"])
        XCTAssertEqual(result.collisions.first?.selectorB, "get_tasks")
        let sent = await transport.requests
        XCTAssertEqual(sent[0].timeoutInterval, 330, "the server may take 300 s")

        // CompileError: { error: <code>, message: <sentence> } with 422 or 502.
        let refused = MockTransport(routes: [.json(.post, "/api/toolkits/compile", #"{"error":"no_enabled_tools","message":"Every tool is toggled off — enable at least one."}"#, status: 422)])
        do {
            _ = try await client(refused).send(.compileMcpToolkit)
            XCTFail("expected 422")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "no_enabled_tools", "the generic reader shows the code")
            XCTAssertEqual(error.mcpCompileSentence, "Every tool is toggled off — enable at least one.")
        }
    }

    // MARK: Registry

    func testRegistrySearchAndLiveness() async throws {
        // lib/smallchat/registry-search.ts RegistryServer.
        let search = """
        {"servers":[
          {"registryId":"io.a/mcp","name":"mcp","description":"A","url":"https://a.example.com/mcp","transport":"streamable-http","version":"1.0.0"},
          {"registryId":"io.b/mcp","name":"b","description":"B","url":"https://b.example.com/sse","transport":"sse","dead":true}],
         "suggested":[{"registryId":"hypervault","name":"HyperVault","description":"Own tools","url":"https://hypervault.store/api/mcp","transport":"streamable-http"}]}
        """
        let transport = MockTransport(routes: [
            .json(.get, "/api/registry/search", search),
            .json(.post, "/api/registry/liveness", #"{"results":[{"url":"https://a.example.com/mcp","state":"dead","status":404},{"url":"https://b.example.com/sse","state":"alive"},{"url":"https://c.example.com","state":"unknown"}]}"#),
        ])
        let api = client(transport)
        let found = try await api.send(.searchMcpRegistry(query: "  linear "))
        XCTAssertEqual(found.servers.count, 2)
        XCTAssertEqual(found.suggested.first?.name, "HyperVault")
        XCTAssertTrue(found.servers[1].dead)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, "q=linear")

        let verdicts = try await api.send(.probeMcpLiveness(urls: found.servers.map(\.url))).results
        XCTAssertEqual(verdicts.map(\.state), [.dead, .alive, .unknown])
        let merged = McpRegistryEntry.applying(verdicts, to: found.servers)
        XCTAssertEqual(merged.map(\.name), ["b", "mcp"], "alive first, the unreachable one sinks")
        XCTAssertEqual(merged.map(\.dead), [false, true])
    }

    func testLivenessKeepsTheRegistryOrderAndNeverDemotesOnUnknown() {
        let entries = ["a", "b", "c", "d"].map { McpRegistryEntry(registryId: $0, name: $0, url: "https://\($0).example.com/") }
        let merged = McpRegistryEntry.applying(
            [McpLivenessVerdict(url: "https://b.example.com", state: .dead, status: 410), McpLivenessVerdict(url: "https://c.example.com/", state: .unknown)],
            to: entries,
            knownDead: ["https://d.example.com"]
        )
        XCTAssertEqual(merged.map(\.name), ["a", "c", "b", "d"])
        XCTAssertEqual(merged.map(\.dead), [false, false, true, true])
    }

    func testACatalogNameThatSaysNothingFallsBackToTheRegistryId() {
        XCTAssertEqual(McpRegistryEntry(registryId: "app.linear/mcp", name: "mcp", url: "https://a.example.com").displayName, "app.linear/mcp")
        XCTAssertEqual(McpRegistryEntry(registryId: "com.github/github", name: "github", url: "https://b.example.com").displayName, "github")
        XCTAssertEqual(McpRegistryEntry(registryId: "hypervault", name: "mcp", url: "https://c.example.com").displayName, "mcp", "no slash to fall back on")
    }

    func testLivenessCallIsCappedAtTwelveAddresses() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/registry/liveness", #"{"results":[]}"#)])
        let urls = (0..<20).map { "https://s\($0).example.com" }
        _ = try await client(transport).send(.probeMcpLiveness(urls: urls))
        let sent = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody ?? Data())
        XCTAssertEqual(body["urls"]?.array?.count, 12)
    }

    func testPreviewDecodesMixedCasing() throws {
        // app/api/mcp-servers/preview/route.ts writes `serverName` camelCase.
        let json = #"{"url":"https://a.example.com","name":"A","serverName":"a-server","tools":[{"name":"t","description":"T","input_schema":{"type":"object","properties":{"q":{"type":"string"}}}}]}"#
        let preview = try HVCoding.decoder(.verbatim).decode(McpPreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.serverName, "a-server")
        XCTAssertEqual(preview.tools[0].parameters.map(\.name), ["q"])
    }
}
