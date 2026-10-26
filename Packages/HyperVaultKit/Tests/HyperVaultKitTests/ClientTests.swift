import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// A token provider whose answers a test can script.
actor FakeTokens: TokenProvider {
    var token: String?
    var next: String?
    private(set) var refreshCalls = 0

    init(token: String?, next: String? = nil) {
        self.token = token
        self.next = next
    }

    func accessToken() async throws -> String? { token }

    func refreshAfterUnauthorized(rejected: String?) async throws -> String? {
        refreshCalls += 1
        token = next
        return next
    }
}

struct Thing: Decodable, Equatable, Sendable {
    var itemName: String
}

final class ClientTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport, tokens: TokenProvider? = nil, retry: RetryPolicy = RetryPolicy(maxAttempts: 3)) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: tokens, retry: retry, sleep: { _ in })
    }

    func testDecodesAndSendsBearer() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/thing", #"{"item_name":"ok"}"#)])
        let api = client(transport, tokens: FakeTokens(token: "t1"))
        let thing: Thing = try await api.send(Endpoint(.get, "/api/thing"))
        XCTAssertEqual(thing, Thing(itemName: "ok"))
        let sent = await transport.requests
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testSignedOutFailsWithoutCallingTheNetwork() async {
        let transport = MockTransport()
        let api = client(transport, tokens: FakeTokens(token: nil))
        do {
            let _: Thing = try await api.send(Endpoint(.get, "/api/thing"))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? HVError, .unauthorized)
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testPublicEndpointsSkipTheToken() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/thing", #"{"item_name":"x"}"#)])
        let api = client(transport, tokens: FakeTokens(token: "t1"))
        let _: Thing = try await api.send(Endpoint(.get, "/api/thing", auth: AuthMode.none))
        let sent = await transport.requests
        XCTAssertNil(sent.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testRefreshesOnceOn401ThenRetries() async throws {
        let transport = MockTransport()
        let counter = Counter()
        await transport.add(MockRoute(.get, "/api/thing") { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" {
                return HTTPResponse(status: 200, data: Data(#"{"item_name":"after"}"#.utf8))
            }
            counter.bump()
            return HTTPResponse(status: 401, data: Data(#"{"error":"Invalid or expired access token"}"#.utf8))
        })
        let tokens = FakeTokens(token: "stale", next: "fresh")
        let api = client(transport, tokens: tokens)
        let thing: Thing = try await api.send(Endpoint(.get, "/api/thing"))
        XCTAssertEqual(thing.itemName, "after")
        XCTAssertEqual(counter.value, 1)
        let refreshes = await tokens.refreshCalls
        XCTAssertEqual(refreshes, 1)
    }

    func testARouteThatRefusesAGoodTokenShowsItsOwnSentence() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/keys", status: 401, message: "Sign in to create API keys.")])
        let api = client(transport, tokens: FakeTokens(token: "stale", next: "fresh"))
        do {
            let _: NoContent = try await api.send(Endpoint(.post, "/api/keys"))
            XCTFail("expected failure")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.userMessage, "Sign in to create API keys.")
            XCTAssertNotEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testStaysUnauthorizedWhenRefreshGivesNothing() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/thing", status: 401, message: "no")])
        let api = client(transport, tokens: FakeTokens(token: "stale", next: nil))
        do {
            let _: Thing = try await api.send(Endpoint(.get, "/api/thing"))
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? HVError, .unauthorized)
        }
    }

    func testServerErrorsKeepTheirSentence() async {
        let transport = MockTransport(routes: [
            .json(.post, "/api/keep", #"{"error":"That is over the 1 MB limit. Trim it and try again.","recovery":{"action":"trim"}}"#, status: 413),
        ])
        let api = client(transport, tokens: FakeTokens(token: "t"))
        do {
            let _: NoContent = try await api.send(Endpoint(.post, "/api/keep", body: .jsonValue(["content": "x"])))
            XCTFail("expected failure")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 413)
            XCTAssertEqual(error.userMessage, "That is over the 1 MB limit. Trim it and try again.")
            XCTAssertEqual(error.failure?.recovery?["action"]?.string, "trim")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testWaitlistRefusalIsRecognised() async {
        let transport = MockTransport(routes: [
            .failure(.get, "/api/yours", status: 403, message: "Your account is on the waitlist — redeem an invite code to unlock the API."),
        ])
        let api = client(transport, tokens: FakeTokens(token: "t"))
        do {
            let _: NoContent = try await api.send(Endpoint(.get, "/api/yours"))
            XCTFail("expected failure")
        } catch let error as HVError {
            XCTAssertTrue(error.isWaitlisted)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testRetriesSafeRequestsOnTransientStatus() async throws {
        let transport = MockTransport()
        let counter = Counter()
        await transport.add(MockRoute(.get, "/api/thing") { _ in
            counter.bump()
            if counter.value < 3 { return HTTPResponse(status: 503, data: Data(#"{"error":"warming up"}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(#"{"item_name":"third time"}"#.utf8))
        })
        let api = client(transport, tokens: FakeTokens(token: "t"))
        let thing: Thing = try await api.send(Endpoint(.get, "/api/thing"))
        XCTAssertEqual(thing.itemName, "third time")
        XCTAssertEqual(counter.value, 3)
    }

    func testDoesNotRetryMutations() async {
        let transport = MockTransport()
        let counter = Counter()
        await transport.add(MockRoute(.post, "/api/save") { _ in
            counter.bump()
            return HTTPResponse(status: 503, data: Data(#"{"error":"down"}"#.utf8))
        })
        let api = client(transport, tokens: FakeTokens(token: "t"))
        do {
            let _: NoContent = try await api.send(Endpoint(.post, "/api/save", body: .jsonValue(["content": "x"])))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 503)
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testBodyIsWrittenSnakeCaseOrVerbatim() async throws {
        struct Body: Encodable, Sendable { var sourcePrompt: String; var makePwa: Bool }
        let transport = MockTransport(routes: [.json(.post, "/api/save", "{}")])
        let api = client(transport, tokens: FakeTokens(token: "t"))
        let _: NoContent = try await api.send(Endpoint(.post, "/api/save", body: .json(Body(sourcePrompt: "p", makePwa: true))))
        let _: NoContent = try await api.send(Endpoint(.post, "/api/save", body: .jsonValue(["X-Raw_Key": 1])))
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"make_pwa":true,"source_prompt":"p"}"#)
        XCTAssertEqual(String(decoding: sent[1].httpBody ?? Data(), as: UTF8.self), #"{"X-Raw_Key":1}"#)
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testQueryAndPathJoining() throws {
        let api = HVClient(baseURL: URL(string: "https://hv.test/")!, transport: MockTransport())
        let endpoint = Endpoint<NoContent>(.get, "api/yours", query: .make([("filter", "memory"), ("q", nil), ("limit", "")]))
        let request = try api.makeRequest(endpoint, token: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://hv.test/api/yours?filter=memory")
    }

    func testDecodingFailureNamesTheField() async {
        let transport = MockTransport(routes: [.json(.get, "/api/thing", #"{"other":1}"#)])
        let api = client(transport, tokens: FakeTokens(token: "t"))
        do {
            let _: Thing = try await api.send(Endpoint(.get, "/api/thing"))
            XCTFail("expected decoding failure")
        } catch let error as HVError {
            guard case .decoding(let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(message.contains("itemName"), message)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
}

/// A tiny lock-protected counter the mock routes can bump from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

final class PlainMessageTests: XCTestCase {
    func testDropsTheMachineCodeThatLeadsTheSentence() {
        let failure = APIFailure(status: 403, message: "missing_scope: This key cannot send mail.", code: "missing_scope")
        XCTAssertEqual(HVError.api(failure).userMessage, "This key cannot send mail.")
    }

    func testKeepsAPrefixThatIsNotTheFailuresOwnCode() {
        let note = APIFailure(status: 400, message: "Note: that name is taken.", code: "name_taken")
        XCTAssertEqual(HVError.api(note).userMessage, "Note: that name is taken.")
        let noCode = APIFailure(status: 400, message: "missing_scope: This key cannot send mail.")
        XCTAssertEqual(HVError.api(noCode).userMessage, "missing_scope: This key cannot send mail.")
    }

    func testNeverReturnsAnEmptySentence() {
        let failure = APIFailure(status: 500, message: "boom: ", code: "boom")
        XCTAssertFalse(HVError.api(failure).userMessage.isEmpty)
    }
}
