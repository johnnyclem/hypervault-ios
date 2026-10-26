import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Webhooks: app/api/webhooks/** and lib/webhooks/subscriptions.ts.
final class WebhooksTests: XCTestCase {
    func api(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    static let hook = #"{"id":"w1","user_id":"u1","api_key_id":null,"name":"grok","url":"https://agent.example/hooks/hv","events":["truth.challenged","truth.overturned"],"authors":["grok"],"enabled":true,"consecutive_failures":2,"last_delivered_at":"2026-10-25T10:00:00.5+00:00","last_status":200,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-21T10:00:00Z"}"#

    func testListDecodes() async throws {
        let json = #"{"webhooks":[\#(Self.hook)],"events":["truth.*","truth.challenged","truth.overturned","truth.upheld","truth.verified","truth.undermined","truth.restored"],"signing":{"signature_header":"X-HyperVault-Signature","event_header":"X-HyperVault-Event","delivery_header":"X-HyperVault-Delivery","scheme":"t=<unix seconds>,v1=<hex HMAC-SHA256>","payload":"{ id }","retries":"5 attempts"}}"#
        let transport = MockTransport(routes: [.json(.get, "/api/webhooks", json)])
        let list = try await api(transport).send(.webhooks)
        XCTAssertEqual(list.webhooks.count, 1)
        let hook = list.webhooks[0]
        XCTAssertEqual(hook.title, "grok")
        XCTAssertEqual(hook.events, ["truth.challenged", "truth.overturned"])
        XCTAssertEqual(hook.authors, ["grok"])
        XCTAssertTrue(hook.isFailing)
        XCTAssertEqual(hook.lastStatus, 200)
        XCTAssertNotNil(hook.lastDeliveredAt)
        XCTAssertEqual(list.events, WebhookRules.knownEvents)
        XCTAssertEqual(list.signing?.signatureHeader, "X-HyperVault-Signature")
    }

    func testAnUnnamedHookIsTitledByItsHost() throws {
        let json = #"{"id":"w2","name":"","url":"https://agent.example/hooks/hv","events":["truth.*"],"authors":[],"enabled":false}"#
        let hook = try HVCoding.decoder().decode(OutboundWebhook.self, from: Data(json.utf8))
        XCTAssertEqual(hook.title, "agent.example")
        XCTAssertFalse(hook.enabled)
    }

    func testCreateReturnsTheSecretOnceAndNeverPrintsIt() async throws {
        let secret = "whsec_abcdefghijklmnopqrstuvwxyz012345"
        let json = #"{"webhook":\#(Self.hook),"secret":"\#(secret)","signing":{},"message":"Webhook registered. Store the secret now — it is not shown again."}"#
        let transport = MockTransport(routes: [.json(.post, "/api/webhooks", json, status: 201)])
        let created = try await api(transport).send(.createWebhook(url: "https://agent.example/hooks/hv", name: " grok ", events: ["truth.challenged"], authors: ["grok"]))
        XCTAssertEqual(created.secret, secret)
        XCTAssertEqual(created.webhook.id, "w1")
        for text in [String(describing: created), "\(created)", String(reflecting: created)] { XCTAssertFalse(text.contains(secret), text) }
        var dumped = ""
        dump(created, to: &dumped)
        XCTAssertFalse(dumped.contains(secret))

        let requests = await transport.requests(matching: "/api/webhooks")
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body, ["url": "https://agent.example/hooks/hv", "name": "grok", "events": ["truth.challenged"], "authors": ["grok"]])
    }

    func testCreateWithDefaultsSendsOnlyTheURL() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/webhooks", #"{"webhook":\#(Self.hook),"secret":"whsec_x"}"#, status: 201)])
        _ = try await api(transport).send(.createWebhook(url: "https://agent.example/h"))
        let requests = await transport.requests(matching: "/api/webhooks")
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests.first?.httpBody)), ["url": "https://agent.example/h"])
    }

    func testCreateRefusalsAreTheServersWords() async {
        for (status, message) in [(400, "That webhook URL can't be used: private address."), (409, "You already have 20 webhooks — delete one first.")] {
            let transport = MockTransport(routes: [.failure(.post, "/api/webhooks", status: status, message: message)])
            do {
                _ = try await api(transport).send(.createWebhook(url: "http://10.0.0.1"))
                XCTFail("expected a refusal")
            } catch let error as HVError {
                XCTAssertEqual(error.userMessage, message)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testTestPingDeleteAndSwitch() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/webhooks/w1/test", #"{"ok":true,"status":200,"response":"ok"}"#),
            .json(.delete, "/api/webhooks/w1", #"{"ok":true}"#),
            .json(.patch, "/api/webhooks/w1", #"{"webhook":\#(Self.hook)}"#),
            .json(.get, "/api/webhooks/w1", #"{"webhook":\#(Self.hook),"deliveries":[{"id":"d1","event_id":"e1","status":"delivered","attempts":1,"next_attempt_at":null,"last_status":200,"last_error":null,"created_at":"2026-10-25T10:00:00Z","delivered_at":"2026-10-25T10:00:01Z"}]}"#),
        ])
        let hv = api(transport)
        let ping = try await hv.send(.testWebhook(id: "w1"))
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(ping.summary, "The receiver answered 200. Real events will arrive the same way.")
        _ = try await hv.send(.deleteWebhook(id: "w1"))
        let switched = try await hv.send(.setWebhookEnabled(id: "w1", enabled: false))
        XCTAssertEqual(switched.webhook.id, "w1")
        let detail = try await hv.send(.webhookDetail(id: "w1"))
        XCTAssertEqual(detail.deliveries.first?.status, "delivered")
        XCTAssertEqual(detail.deliveries.first?.lastStatus, 200)
    }

    func testTestResultSentences() throws {
        func result(_ json: String) throws -> WebhookTestResult { try HVCoding.decoder().decode(WebhookTestResult.self, from: Data(json.utf8)) }
        XCTAssertEqual(try result(#"{"ok":false,"status":500,"response":"err"}"#).summary, "The receiver answered 500. It needs a 2xx for a delivery to count.")
        XCTAssertEqual(try result(#"{"ok":false,"status":null,"error":"timed out"}"#).summary, "Could not reach it: timed out")
        XCTAssertEqual(try result(#"{"ok":false,"status":null}"#).summary, "Could not reach it.")
    }

    func testURLRule() {
        XCTAssertNil(WebhookRules.validate(url: "https://agent.example/hooks/hv"))
        XCTAssertNil(WebhookRules.validate(url: " http://agent.example "))
        XCTAssertEqual(WebhookRules.validate(url: ""), "Add the address HyperVault should post to.")
        XCTAssertNotNil(WebhookRules.validate(url: "agent.example/hook"))
        XCTAssertEqual(WebhookRules.validate(url: "ftp://agent.example/x"), "The address must start with https:// or http://.")
        XCTAssertEqual(WebhookRules.validate(url: "https://"), "The address must be a full URL, like https://example.com/hooks/hypervault.")
    }

    func testAuthorsAndEventTitles() {
        XCTAssertEqual(WebhookRules.authors(from: "grok, gemini\n grok ,, claude"), ["grok", "gemini", "claude"])
        XCTAssertEqual(WebhookRules.authors(from: "  "), [])
        XCTAssertEqual(WebhookRules.eventTitle("truth.*"), "Everything")
        XCTAssertEqual(WebhookRules.eventTitle("truth.challenged"), "Challenged")
    }
}
