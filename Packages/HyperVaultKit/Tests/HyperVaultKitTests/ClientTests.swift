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

    func testAPlusInAQueryIsSentEncodedBecauseTheServerReadsItAsASpace() throws {
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: MockTransport())
        // Searching Yours for "c++ notes"; a space still goes as %20.
        let search = try api.makeRequest(.yours(filter: .all, query: "c++ notes", limit: 50), token: nil)
        XCTAssertEqual(search.url?.absoluteString, "https://hv.test/api/yours?kind=all&q=c%2B%2B%20notes&limit=50")
        // "Pull C++ cheatsheet onto the page" searches with the name it read.
        guard case .pull(let name)? = CanvasCommandParser.parse("pull C++ cheatsheet onto the page") else { return XCTFail("should be a pull") }
        let pull = try api.makeRequest(.yours(filter: .all, query: name, limit: PullResolver.searchLimit), token: nil)
        XCTAssertEqual(pull.url?.absoluteString, "https://hv.test/api/yours?kind=all&q=C%2B%2B%20cheatsheet&limit=50")
        // What was already escaped stays as it was, and a "%2B" is not escaped twice.
        let mixed = try api.makeRequest(Endpoint<NoContent>(.get, "/api/x", query: .make([("q", "a+b & 100% %2B")])), token: nil)
        XCTAssertEqual(mixed.url?.query, "q=a%2Bb%20%26%20100%25%20%252B")
    }

    func testPathEscapesAreKeptNotEscapedTwice() throws {
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: MockTransport())
        func url(_ path: String) throws -> String? {
            try api.makeRequest(Endpoint<NoContent>(.delete, path), token: nil).url?.absoluteString
        }
        // A branch with a slash arrives pre-escaped and must reach the route that way.
        XCTAssertEqual(try url("/api/mind/branches/research%2Fquantum"), "https://hv.test/api/mind/branches/research%2Fquantum")
        // Anything raw is escaped once: a space, a question mark, a lone percent sign, non-ASCII.
        XCTAssertEqual(try url("/api/a/two words"), "https://hv.test/api/a/two%20words")
        XCTAssertEqual(try url("/api/a/what?"), "https://hv.test/api/a/what%3F")
        XCTAssertEqual(try url("/api/a/100%"), "https://hv.test/api/a/100%25")
        XCTAssertEqual(try url("/api/a/caf\u{e9}"), "https://hv.test/api/a/caf%C3%A9")
        // A base URL with its own path keeps it.
        let nested = HVClient(baseURL: URL(string: "https://hv.test/root/")!, transport: MockTransport())
        XCTAssertEqual(try nested.makeRequest(Endpoint<NoContent>(.get, "api/x%2Fy"), token: nil).url?.absoluteString, "https://hv.test/root/api/x%2Fy")
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

final class SourcePromptTests: XCTestCase {
    func testAPromptWithinTheLimitIsKeptAsItIsAndABlankOneIsLeftOut() {
        XCTAssertEqual(SourcePrompt.clipped("  Plan my week \u{1F600}  "), "Plan my week \u{1F600}")
        XCTAssertNil(SourcePrompt.clipped(" \n\t "))
    }

    func testTheLimitIsCountedInUTF16UnitsLikeTheServer() {
        // A CRLF is one Character but two units: 3,000 of them are 15,000 units.
        let crlf = String(repeating: "line\r\n", count: 3_000)
        XCTAssertEqual(SourcePrompt.clipped(crlf)?.utf16.count ?? 0 <= 10_000, true)
        XCTAssertGreaterThan(SourcePrompt.clipped(crlf)?.utf16.count ?? 0, 9_990)
        // Emoji are two units each: 6,000 of them are 12,000 units, and the cut falls between two of them.
        let emoji = SourcePrompt.clipped(String(repeating: "\u{1F600}", count: 6_000))
        XCTAssertEqual(emoji?.utf16.count, 10_000)
        XCTAssertFalse(emoji?.contains("\u{FFFD}") ?? true)
    }

    func testEveryKeepRequestClipsItsPrompt() throws {
        let request = KeepRequest(content: "x", sourcePrompt: String(repeating: "a", count: 12_000))
        XCTAssertEqual(request.sourcePrompt?.utf16.count, 10_000)
        XCTAssertNil(KeepRequest(content: "x", sourcePrompt: "   ").sourcePrompt)
    }
}

final class PermanentRefusalTests: XCTestCase {
    private func client(_ transport: MockTransport, tokens: FakeTokens) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: tokens,
                 retry: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0), sleep: { _ in })
    }

    func testAnAnswerThatNamesItsOwnCodeIsNotRetried() async {
        let transport = MockTransport()
        let counter = Counter()
        await transport.add(MockRoute(.get, "/api/mail") { _ in
            counter.bump()
            return HTTPResponse(status: 503, data: Data(#"{"error":"mail_unavailable: not set up","code":"mail_unavailable"}"#.utf8))
        })
        do {
            let _: NoContent = try await client(transport, tokens: FakeTokens(token: "t")).send(Endpoint(.get, "/api/mail"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? HVError)?.code, "mail_unavailable")
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testAToolsOwnSignInChallengeDoesNotRefreshThePersonsToken() async {
        let transport = MockTransport(routes: [
            .json(.post, "/api/mcp-servers/1/refresh", #"{"error":"Authorization expired","auth_required":true}"#, status: 401),
        ])
        let tokens = FakeTokens(token: "good", next: "fresh")
        do {
            let _: NoContent = try await client(transport, tokens: tokens).send(Endpoint(.post, "/api/mcp-servers/1/refresh"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 401)
        }
        let refreshes = await tokens.refreshCalls
        XCTAssertEqual(refreshes, 0)
    }
}
