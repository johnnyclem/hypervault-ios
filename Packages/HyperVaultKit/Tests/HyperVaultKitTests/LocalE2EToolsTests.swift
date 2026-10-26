import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Tools: MCP servers the person connects (preview, add, edit, refresh, compile) and webhooks the server delivers
// to. The MCP server and the webhook receiver are the stand-ins in scripts/e2e/fakes.mjs.

final class LocalE2EToolsTests: LocalE2ECase {

    private func requireFakes() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["HV_E2E_FAKES"], let url = URL(string: text) else {
            throw XCTSkip("Set HV_E2E_FAKES (scripts/e2e/start.sh does) for the tests that call a local MCP server or webhook receiver.")
        }
        return url
    }

    private func fakeClient() throws -> HVClient {
        HVClient(baseURL: try requireFakes(), transport: URLSessionTransport(), tokens: nil, retry: .none)
    }

    // MARK: MCP servers

    func testPreviewAddEditRefreshAndRemoveAnMCPServer() async throws {
        let (api, _) = member(29)
        let base = try requireFakes()
        let url = base.appendingPathComponent("mcp").absoluteString
        XCTAssertNotNil(McpServerURL.parse(url))
        // Start clean: an earlier run that stopped half way may have left this server connected.
        for leftover in try await send(.mcpServers, api).servers where leftover.url == url { _ = try await send(.deleteMcpServer(id: leftover.id), api) }

        // Preview reads the tools without saving anything.
        let preview = try await send(.previewMcpServer(url: url, name: "Fake tools"), api)
        XCTAssertEqual(preview.tools.map(\.name).sorted(), ["add", "echo"])
        XCTAssertEqual(preview.serverName, "Fake MCP")
        XCTAssertEqual(preview.url, url)
        let add = try XCTUnwrap(preview.tools.first { $0.name == "add" })
        XCTAssertEqual(add.description, "Add two numbers")
        XCTAssertEqual(add.parameters.map(\.name).sorted(), ["a", "b"])
        XCTAssertTrue(add.parameters.allSatisfy { $0.isRequired && $0.type == "number" })
        let before = try await send(.mcpServers, api)
        XCTAssertNil(before.servers.first { $0.url == url }, "a preview saved the server")

        // Add saves it with its tools cached.
        let (added, raw) = try await fetch(.addMcpServer(McpAddRequest(url: url, name: "Fake tools")), api)
        XCTAssertEqual(added.server.name, "Fake tools")
        XCTAssertEqual(added.server.url, url)
        XCTAssertTrue(added.server.enabled)
        XCTAssertEqual(added.server.tools.map(\.name).sorted(), ["add", "echo"])
        XCTAssertNotNil(added.server.introspectedAt)
        XCTAssertFalse(added.server.hasAuth)
        XCTAssertEqual(added.server.authType, .none)
        XCTAssertTrue(added.server.disabledTools.isEmpty)
        XCTAssertEqual(added.server.enabledToolCount, 2)
        XCTAssertEqual(raw["server"]?["tools_cache"]?.array?.count, 2)
        let id = added.server.id

        let (list, listRaw) = try await fetch(.mcpServers, api)
        XCTAssertEqual(list.servers.count, rawCount(listRaw, "servers"))
        let row = try XCTUnwrap(list.servers.first { $0.id == id })
        XCTAssertEqual(row.tools.count, 2)
        XCTAssertEqual(row.host, "127.0.0.1")
        await expectFailure(409, .addMcpServer(McpAddRequest(url: url)), api, message: "already")

        // Turn a tool off, then the whole server, then rename.
        let toolOff = try await send(.updateMcpServer(id: id, disabledTools: ["echo"]), api)
        XCTAssertEqual(toolOff.server.disabledTools, ["echo"])
        XCTAssertEqual(toolOff.server.enabledToolCount, 1)
        let off = try await send(.updateMcpServer(id: id, enabled: false), api)
        XCTAssertFalse(off.server.enabled)
        let renamed = try await send(.updateMcpServer(id: id, name: "Renamed tools", enabled: true), api)
        XCTAssertEqual(renamed.server.name, "Renamed tools")
        XCTAssertTrue(renamed.server.enabled)

        // Refresh reads the tools again and keeps what was switched off.
        let refreshed = try await send(.refreshMcpServer(id: id), api)
        XCTAssertEqual(refreshed.tools.map(\.name).sorted(), ["add", "echo"])
        XCTAssertEqual(refreshed.disabledTools, ["echo"])
        XCTAssertNotNil(refreshed.introspectedAt)

        // Compile the toolkit: the Kit reads the status and the compile result.
        _ = try await send(.mcpToolkit, api)   // (a toolkit from an earlier run may still be there)
        let compiled = try await send(.compileMcpToolkit, api)
        XCTAssertFalse(compiled.toolkitId.isEmpty)
        XCTAssertEqual(compiled.stats.providerCount, 1)
        XCTAssertEqual(compiled.stats.toolCount, 1, "echo is off, so one tool is compiled")
        XCTAssertFalse(compiled.embedderLabel.isEmpty)
        XCTAssertTrue(compiled.skippedServers.isEmpty, "\(compiled.skippedServers)")
        let status1 = try await send(.mcpToolkit, api)
        XCTAssertEqual(status1.toolkit?.id, compiled.toolkitId)
        XCTAssertEqual(status1.toolkit?.stats.toolCount, 1)
        XCTAssertFalse(status1.stale)
        let chatStatus = try await send(.toolkitStatus, api)
        XCTAssertTrue(chatStatus.hasToolkit)
        // Changing which tools are on makes the toolkit stale.
        _ = try await send(.updateMcpServer(id: id, disabledTools: []), api)
        let stale = try await send(.mcpToolkit, api)
        XCTAssertTrue(stale.stale, "enabling a tool should mark the compiled toolkit stale")

        // Remove it.
        let (bob, _) = try second()
        await expectFailure(404, .refreshMcpServer(id: id), bob)
        _ = try? await bob.send(.deleteMcpServer(id: id))
        let stillThere = try await send(.mcpServers, api)
        XCTAssertNotNil(stillThere.servers.first { $0.id == id }, "another person removed this person's server")
        _ = try await send(.deleteMcpServer(id: id), api)
        let after = try await send(.mcpServers, api)
        XCTAssertNil(after.servers.first { $0.id == id })
        await expectFailure(404, .refreshMcpServer(id: id), api)
    }

    func testAnMCPServerThatWantsASignInIsAChallengeNotAFailure() async throws {
        let (api, _) = member(29)
        let base = try requireFakes()
        let url = base.appendingPathComponent("mcp-auth").absoluteString
        // No token: the server asks for a sign-in, which the Kit reads from the 401.
        let challenge = await expectFailure(401, .previewMcpServer(url: url), api)
        XCTAssertEqual(challenge?.body?["auth_required"]?.bool, true, "the 401 should say a sign-in is needed: \(String(describing: challenge?.body))")
        // A 401 about the tool's sign-in does not log the person out of HyperVault: no refresh is tried.
        // With the token as a header the preview works, and the add stores it encrypted.
        let header = ["Authorization": "Bearer mcp-secret"]
        let preview = try await send(.previewMcpServer(url: url, headers: header), api)
        XCTAssertEqual(preview.serverName, "Fake Private MCP")
        let added = try await send(.addMcpServer(McpAddRequest(url: url, name: "Private tools", headers: header)), api)
        XCTAssertTrue(added.server.hasAuth)
        XCTAssertFalse(added.server.secretBacked)
        XCTAssertEqual(added.server.authType, .headers)
        XCTAssertFalse(String(describing: added).contains("mcp-secret"))
        let stored = try await inspect("mcp_servers", [URLQueryItem(name: "id", value: "eq.\(added.server.id)")], select: "auth_headers_cipher")
        let cipher = try XCTUnwrap(stored.first?["auth_headers_cipher"]?.string)
        XCTAssertFalse(cipher.contains("mcp-secret"))
        let listed = try await send(.mcpServers, api)
        XCTAssertFalse(listed.servers.contains { $0.url.contains("mcp-secret") })
        let replaced = try await send(.replaceMcpHeaders(id: added.server.id, headers: ["Authorization": "Bearer mcp-secret"]), api)
        XCTAssertTrue(replaced.server.hasAuth)
        _ = try await send(.deleteMcpServer(id: added.server.id), api)
    }

    func testMCPAddressesTheServerWillNotCallAreRefusedPlainly() async throws {
        let (api, _) = member(29)
        // An address with nothing behind it, and one that is not a URL at all.
        let dead = await expectFailure(502, .previewMcpServer(url: "http://127.0.0.1:9/mcp"), api)
        XCTAssertFalse(dead?.message.isEmpty ?? true)
        await expectFailure(400, .previewMcpServer(url: "not a url"), api)
        await expectFailure(400, .addMcpServer(McpAddRequest(url: "ftp://example.com/mcp")), api)
        let results = try await send(.probeMcpLiveness(urls: ["http://127.0.0.1:9/mcp"]), api)
        XCTAssertEqual(results.results.count, 1)
    }

    // MARK: Webhooks, delivered

    func testAWebhookIsSignedAndDeliveredWhenTruthMoves() async throws {
        let fakes = try fakeClient()
        let base = try requireFakes()
        let fresh = try await freshMember("hookowner")
        let api = fresh.client
        _ = try await send(.setTruthHandle(unique("hooker")), api)
        let slug = unique("hookcase")
        _ = try await send(.createTruthLedger(slug: slug, kind: .hosted), api)
        _ = try await fakes.send(Endpoint<JSONValue>(.delete, "/__received", auth: .none, keys: .verbatim))

        let target = base.appendingPathComponent("hook/ok").absoluteString
        let created = try await send(.createWebhook(url: target, name: "Receiver", events: ["truth.challenged"]), api)

        // The ping the app offers goes to the receiver, signed.
        let ping = try await send(.testWebhook(id: created.webhook.id), api)
        XCTAssertTrue(ping.ok, ping.summary)
        XCTAssertEqual(ping.status, 200)
        var got = try await receivedHooks(fakes, "/hook/ok")
        let pingDelivery = try XCTUnwrap(got.first, "the ping never arrived")
        XCTAssertEqual(pingDelivery["method"]?.string, "POST")
        XCTAssertEqual(pingDelivery["headers"]?["x-hypervault-event"]?.string, "truth.test")
        let signing = try await send(.webhooks, api).signing
        let signatureHeader = try XCTUnwrap(signing?.signatureHeader).lowercased()
        let signature = try XCTUnwrap(pingDelivery["headers"]?[signatureHeader]?.string, "no \(signatureHeader) header: \(pingDelivery["headers"]?.jsonString() ?? "")")
        let body = try XCTUnwrap(pingDelivery["body"]?.string)
        XCTAssertTrue(HookSignature.verify(signature: signature, body: body, secret: created.secret), "the signature is not an HMAC-SHA256 of the body under the secret: \(signature)")
        XCTAssertFalse(HookSignature.verify(signature: signature, body: body, secret: created.secret + "x"))

        // A real event: a TB under appeal is delivered (the hook asked for 'challenged' only).
        let tbResult = try await send(.assertTruth(tbDraft(), ledger: slug), api)
        let tbID = try XCTUnwrap(tbResult.line?.id)
        let key = try await send(.createAgentKey(name: unique("hook agent")), api)
        let contest = Endpoint<JSONValue>(.post, "/api/truth/entries", body: .jsonValue([
            "type": "UV", "ledger": .string(slug), "assertion": "Not so", "basis": "I looked", "verifyBy": ["kind": "inspect", "value": "look"], "contests": .string(tbID),
        ]), keys: .verbatim)
        _ = try await send(contest, client(key.key))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        got = try await receivedHooks(fakes, "/hook/ok")
        let challenged = got.filter { $0["headers"]?["x-hypervault-event"]?.string == "truth.challenged" }
        XCTAssertEqual(challenged.count, 1, "events seen: \(got.compactMap { $0["headers"]?["x-hypervault-event"]?.string })")
        if let delivery = challenged.first {
            let payload = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data((delivery["body"]?.string ?? "{}").utf8))
            XCTAssertEqual(payload["type"]?.string, "truth.challenged")
            XCTAssertEqual(payload["data"]?["event"]?["entry_id"]?.string, tbID)
            XCTAssertNotNil(payload["created_at"]?.string)
        }
        let detail = try await send(.webhookDetail(id: created.webhook.id), api)
        XCTAssertFalse(detail.deliveries.isEmpty, "the deliveries the app shows are empty")
        XCTAssertNotNil(detail.webhook.lastDeliveredAt)
        XCTAssertEqual(detail.webhook.lastStatus, 200)
        XCTAssertEqual(detail.webhook.consecutiveFailures, 0)

        // A receiver that fails is counted.
        let failing = try await send(.createWebhook(url: base.appendingPathComponent("hook/fail").absoluteString, events: ["truth.*"]), api)
        let failedPing = try await send(.testWebhook(id: failing.webhook.id), api)
        XCTAssertFalse(failedPing.ok)
        XCTAssertEqual(failedPing.status, 500)
        XCTAssertFalse(failedPing.summary.isEmpty)
        _ = try await send(.deleteWebhook(id: failing.webhook.id), api)
        _ = try await send(.deleteWebhook(id: created.webhook.id), api)
    }

    private func tbDraft() -> TruthAssertDraft {
        var draft = TruthAssertDraft(type: .tb)
        draft.text = "The hook fires"
        draft.evidence = [TruthEvidenceDraft(kind: .file, ref: "hooks.md")]
        return draft
    }

    private func receivedHooks(_ fakes: HVClient, _ path: String) async throws -> [JSONValue] {
        let result = try await fakes.send(Endpoint<JSONValue>(.get, "/__received", query: [URLQueryItem(name: "path", value: path)], auth: .none, keys: .verbatim))
        return result.array ?? []
    }
}

enum HookSignature {
    /// `t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>" with the secret>`, the scheme `GET /api/webhooks` documents.
    static func verify(signature: String, body: String, secret: String) -> Bool {
        let parts = Dictionary(uniqueKeysWithValues: signature.split(separator: ",").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
        guard let t = parts["t"], let v1 = parts["v1"] else { return false }
        return hmacHex(key: Data(secret.utf8), message: Data("\(t).\(body)".utf8)) == v1.lowercased()
    }

    /// RFC 2104 over the Kit's own SHA-256 (block size 64).
    static func hmacHex(key: Data, message: Data) -> String {
        var k = key.count > 64 ? Data(SHA256.hash(key)) : key
        k.append(Data(repeating: 0, count: 64 - k.count))
        let inner = Data(k.map { $0 ^ 0x36 }) + message
        let outer = Data(k.map { $0 ^ 0x5c }) + Data(SHA256.hash(inner))
        return SHA256.hex(outer)
    }
}
