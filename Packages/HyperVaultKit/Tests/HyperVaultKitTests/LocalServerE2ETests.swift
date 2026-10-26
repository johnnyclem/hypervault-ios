import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The Kit against the REAL web backend, signed in, on this machine.
//
// Nothing here talks to a deployment: scripts/e2e/start.sh brings up PostgreSQL, a Supabase stand-in (fake
// sign-in plus a PostgREST-compatible layer) and the web app from a checkout of the web repo, with throwaway
// people and keys. See docs/LOCAL_E2E.md. These tests stay out of the normal run: each skips unless
//
//     HV_E2E_LOCAL_SERVER   the web app (http://127.0.0.1:3100)
//     HV_E2E_LOCAL_TOKEN    a signed-in person's access token (a member)
//
// are set; the rest are optional and the tests that need them skip:
//
//     HV_E2E_LOCAL_TOKEN_2          a second member (sharing, isolation)
//     HV_E2E_LOCAL_ADMIN_TOKEN      an administrator
//     HV_E2E_LOCAL_WAITLIST_TOKEN   a signed-in account that has not been let in (invite redeem)
//     HV_E2E_LOCAL_EXPIRED_TOKEN    a token past its expiry
//     HV_E2E_LOCAL_POOL_TOKENS      comma separated members, one per feature area, so no one person
//                                   runs into the server's 120-calls-a-minute meter
//     HV_E2E_SUPABASE_URL, HV_E2E_ANON_KEY, HV_E2E_SERVICE_KEY   the stand-in, for the Kit's direct
//                                   reads (AccountRest) and for arranging data the Kit cannot create
//
// Every check compares what a model decoded with the raw JSON the server sent, or writes something and reads it
// back; "it decoded" alone proves little when most models fall back to empty values.

struct LocalE2EEnvironment: Sendable {
    let server: ServerConfig
    let token: String
    let token2: String?
    let adminToken: String?
    let waitlistToken: String?
    let expiredToken: String?
    let poolTokens: [String]
    let supabaseURL: URL?
    let anonKey: String?
    let serviceKey: String?

    static func load() throws -> LocalE2EEnvironment {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        guard let serverText = value("HV_E2E_LOCAL_SERVER"), let server = ServerConfig(userInput: serverText),
              let token = value("HV_E2E_LOCAL_TOKEN")
        else {
            throw XCTSkip("Set HV_E2E_LOCAL_SERVER and HV_E2E_LOCAL_TOKEN (see docs/LOCAL_E2E.md) to run the local end-to-end tests.")
        }
        return LocalE2EEnvironment(
            server: server,
            token: token,
            token2: value("HV_E2E_LOCAL_TOKEN_2"),
            adminToken: value("HV_E2E_LOCAL_ADMIN_TOKEN"),
            waitlistToken: value("HV_E2E_LOCAL_WAITLIST_TOKEN"),
            expiredToken: value("HV_E2E_LOCAL_EXPIRED_TOKEN"),
            poolTokens: (value("HV_E2E_LOCAL_POOL_TOKENS") ?? "").split(separator: ",").map(String.init),
            supabaseURL: value("HV_E2E_SUPABASE_URL").flatMap(URL.init(string:)),
            anonKey: value("HV_E2E_ANON_KEY"),
            serviceKey: value("HV_E2E_SERVICE_KEY")
        )
    }
}

struct LocalStaticToken: TokenProvider {
    let token: String
    func accessToken() async throws -> String? { token }
    func refreshAfterUnauthorized(rejected: String?) async throws -> String? { nil }
}

/// The server meters each signed-in person at 120 calls a minute (`lib/api-auth.ts`). A suite this long would run
/// into it, so every person's calls are spaced to stay under 100 in any 60 seconds. Tests that want the 429 use
/// their own transport.
actor LocalCallPacer {
    private var stamps: [String: [Date]] = [:]

    func wait(for key: String, limit: Int = 100, window: TimeInterval = 60) async {
        while true {
            let now = Date()
            let recent = (stamps[key] ?? []).filter { now.timeIntervalSince($0) < window }
            if recent.count < limit {
                stamps[key] = recent + [now]
                return
            }
            let waitFor = window - now.timeIntervalSince(recent[recent.count - limit]) + 0.25
            try? await Task.sleep(nanoseconds: UInt64(max(0.25, waitFor) * 1_000_000_000))
        }
    }
}

struct LocalPacedTransport: HTTPTransport {
    let inner: HTTPTransport
    let pacer: LocalCallPacer
    let trace: Bool

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        await pacer.wait(for: request.value(forHTTPHeaderField: "Authorization") ?? "anonymous")
        let started = Date()
        let response = try await inner.send(request)
        if trace {
            let path = request.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? "?"
            print("e2e \(request.httpMethod ?? "GET") \(path.prefix(110)) -> \(response.status) \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        return response
    }
}

/// The shared pieces: the environment, one client per person, and the comparisons the journeys use.
class LocalE2ECase: XCTestCase {
    static let pacer = LocalCallPacer()
    var env: LocalE2EEnvironment!

    override func setUp() async throws {
        try await super.setUp()
        env = try LocalE2EEnvironment.load()
        continueAfterFailure = true
    }

    // MARK: Clients

    func client(_ token: String?, retry: RetryPolicy = .none) -> HVClient {
        let inner = LocalPacedTransport(
            inner: URLSessionTransport(), pacer: Self.pacer,
            trace: ProcessInfo.processInfo.environment["HV_E2E_TRACE"] == "1"
        )
        return HVClient(baseURL: env.server.baseURL, transport: inner, tokens: token.map(LocalStaticToken.init), retry: retry)
    }

    var primaryToken: String { env.token }

    /// A member for one feature area: the pool's nth person when the pool is there, else the main one.
    func member(_ index: Int) -> (client: HVClient, token: String) {
        let token = env.poolTokens.isEmpty ? env.token : env.poolTokens[index % env.poolTokens.count]
        return (client(token), token)
    }

    func second() throws -> (client: HVClient, token: String) {
        guard let token = env.token2 else { throw XCTSkip("Set HV_E2E_LOCAL_TOKEN_2 for the tests that need a second person.") }
        return (client(token), token)
    }

    func admin() throws -> (client: HVClient, token: String) {
        guard let token = env.adminToken else { throw XCTSkip("Set HV_E2E_LOCAL_ADMIN_TOKEN for the admin tests.") }
        return (client(token), token)
    }

    func waitlisted() throws -> (client: HVClient, token: String) {
        guard let token = env.waitlistToken else { throw XCTSkip("Set HV_E2E_LOCAL_WAITLIST_TOKEN for the invite tests.") }
        return (client(token), token)
    }

    /// A person who did not exist a moment ago: signs up with an emailed code against the stand-in's auth server
    /// (the Kit's own `AuthService`), and is let in by the administrator. For tests whose effects pile up
    /// on an account (claimed addresses, dismissed cards) and so cannot be repeated on the same one.
    func freshMember(_ label: String = "fresh") async throws -> (client: HVClient, token: String, userID: String, email: String) {
        guard let url = env.supabaseURL, let anon = env.anonKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL and HV_E2E_ANON_KEY to sign a new person up.")
        }
        let (admin, _) = try admin()
        let auth = AuthService(config: SupabaseConfig(url: url, anonKey: anon), transport: URLSessionTransport(), store: InMemorySecureStore())
        let email = "\(unique(label))@e2e.test"
        try await auth.requestEmailCode(email: email)
        let session = try await auth.verifyEmailCode(email: email, code: "424242")
        _ = try await admin.send(.changeAccount(id: session.user.id, .approve))
        return (client(session.accessToken), session.accessToken, session.user.id, email)
    }

    /// The stand-in's REST API with the service role, for arranging what the Kit has no call to create.
    func restAsService() throws -> AccountRest {
        guard let url = env.supabaseURL, let anon = env.anonKey, let service = env.serviceKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL, HV_E2E_ANON_KEY and HV_E2E_SERVICE_KEY for the tests that read Supabase directly.")
        }
        let api = HVClient(baseURL: url, transport: URLSessionTransport(), tokens: LocalStaticToken(token: service), retry: .none)
        return AccountRest(client: api, anonKey: anon)
    }

    /// Writes rows the Kit has no call for (a queue the server fills on a schedule, a message that arrives from
    /// outside) through the stand-in's REST API as its service role, and returns the rows as stored.
    @discardableResult
    func arrange(_ table: String, _ rows: JSONValue, upsert: String? = nil) async throws -> [JSONValue] {
        guard let url = env.supabaseURL, let anon = env.anonKey, let service = env.serviceKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL, HV_E2E_ANON_KEY and HV_E2E_SERVICE_KEY for the tests that arrange data.")
        }
        let api = HVClient(baseURL: url, transport: URLSessionTransport(), tokens: LocalStaticToken(token: service), retry: .none)
        var headers = ["apikey": anon, "Prefer": "return=representation"]
        var query: [URLQueryItem] = []
        if let upsert {
            headers["Prefer"] = "return=representation,resolution=merge-duplicates"
            query = [URLQueryItem(name: "on_conflict", value: upsert)]
        }
        let result = try await api.send(Endpoint<JSONValue>(.post, "/rest/v1/\(table)", query: query, body: .jsonValue(rows), keys: .verbatim, headers: headers))
        return result.array ?? []
    }

    /// Reads rows as the service role.
    func inspect(_ table: String, _ filters: [URLQueryItem] = [], select: String = "*") async throws -> [JSONValue] {
        guard let url = env.supabaseURL, let anon = env.anonKey, let service = env.serviceKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL, HV_E2E_ANON_KEY and HV_E2E_SERVICE_KEY for the tests that inspect rows.")
        }
        let api = HVClient(baseURL: url, transport: URLSessionTransport(), tokens: LocalStaticToken(token: service), retry: .none)
        let result = try await api.send(Endpoint<JSONValue>(.get, "/rest/v1/\(table)", query: [URLQueryItem(name: "select", value: select)] + filters, keys: .verbatim, headers: ["apikey": anon]))
        return result.array ?? []
    }

    func rest(token: String) throws -> AccountRest {
        guard let url = env.supabaseURL, let anon = env.anonKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL and HV_E2E_ANON_KEY for the tests that read Supabase directly.")
        }
        let api = HVClient(baseURL: url, transport: URLSessionTransport(), tokens: LocalStaticToken(token: token), retry: .none)
        return AccountRest(client: api, anonKey: anon)
    }

    // MARK: Comparisons

    /// The decoded value and the raw JSON it came from.
    func fetch<R: Sendable>(_ endpoint: Endpoint<R>, _ api: HVClient, file: StaticString = #filePath, line: UInt = #line) async throws -> (value: R, raw: JSONValue) {
        let response = try await api.sendRaw(endpoint)
        let raw = (try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: response.data)) ?? .null
        do {
            return (try endpoint.decode(response, endpoint.keys), raw)
        } catch {
            XCTFail("\(endpoint.method.rawValue) \(endpoint.path) did not decode: \(error). Body: \(String(decoding: response.data.prefix(600), as: UTF8.self))", file: file, line: line)
            throw error
        }
    }

    func send<R: Sendable>(_ endpoint: Endpoint<R>, _ api: HVClient, file: StaticString = #filePath, line: UInt = #line) async throws -> R {
        try await fetch(endpoint, api, file: file, line: line).value
    }

    /// Runs a call that should be refused and returns the failure for further checks.
    @discardableResult
    func expectFailure<R: Sendable>(
        _ status: Int, _ endpoint: Endpoint<R>, _ api: HVClient,
        message: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async -> APIFailure? {
        do {
            _ = try await api.sendRaw(endpoint)
            XCTFail("\(endpoint.method.rawValue) \(endpoint.path) was accepted; expected \(status)", file: file, line: line)
            return nil
        } catch let error as HVError {
            guard let failure = error.failure else {
                if status == 401, error == .unauthorized { return nil }
                XCTFail("\(endpoint.method.rawValue) \(endpoint.path) failed without a server answer: \(error)", file: file, line: line)
                return nil
            }
            XCTAssertEqual(failure.status, status, "\(endpoint.method.rawValue) \(endpoint.path): \(failure.message)", file: file, line: line)
            XCTAssertFalse(failure.message.isEmpty, "a refusal with no sentence to show", file: file, line: line)
            if let message {
                XCTAssertTrue(failure.message.localizedCaseInsensitiveContains(message), "expected '\(message)' in '\(failure.message)'", file: file, line: line)
            }
            return failure
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    /// The `sub` of a JWT, read without checking it.
    func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let object = try? HVCoding.decoder(.verbatim).decode(JSONValue.self, from: data) else { return nil }
        return object["sub"]?.string
    }

    func rawCount(_ raw: JSONValue, _ key: String) -> Int { raw[key]?.array?.count ?? -1 }

    func unique(_ prefix: String) -> String {
        "\(prefix)-\(String(UUID().uuidString.prefix(8)).lowercased())"
    }

    /// A word that appears nowhere else, for search.
    func uniqueWord() -> String {
        "zq" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    func report(_ area: String, _ pairs: [(String, Int)]) {
        print("e2e \(area): " + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }
}

// MARK: - Sign-in state, capabilities, keeping and Yours

final class LocalServerE2ETests: LocalE2ECase {

    // MARK: Capabilities

    func testCapabilitiesWithoutATokenAreAnonymousAndNameTheStandIn() async throws {
        let (caps, raw) = try await fetch(.capabilities, client(nil))
        XCTAssertNil(caps.user, "an anonymous call must not be told it is a person")
        XCTAssertEqual(caps.appUrl, raw["app_url"]?.string)
        let supabase = try XCTUnwrap(caps.supabase, "no Supabase project named, so nobody could sign in")
        XCTAssertEqual(supabase.url.absoluteString, raw["auth"]?["supabase_url"]?.string)
        XCTAssertEqual(supabase.anonKey, raw["auth"]?["supabase_anon_key"]?.string)
        XCTAssertEqual(caps.auth.inviteGated, raw["auth"]?["invite_gated"]?.bool)
        XCTAssertEqual(caps.providers.count, rawCount(raw, "providers"))
        XCTAssertGreaterThan(caps.providers.count, 5, "the connector registry decoded to nothing")
        XCTAssertEqual(caps.themes.count, rawCount(raw, "themes"))
        XCTAssertEqual(caps.domains.count, rawCount(raw, "domains"))
        XCTAssertEqual(caps.limits.artifactBytes, raw["limits"]?["artifact_bytes"]?.int)
        XCTAssertEqual(caps.limits.memoryBytes, raw["limits"]?["memory_bytes"]?.int)
        XCTAssertEqual(caps.limits.maxBackends, raw["limits"]?["max_backends"]?.int)
        XCTAssertEqual(caps.features.keyEncryption, raw["features"]?["key_encryption"]?.bool)
        XCTAssertTrue(caps.features.configured)
        XCTAssertTrue(caps.features.keyEncryption, "the stand-in sets HYPERVAULT_KEY_SECRET, so keys can be stored")
    }

    func testCapabilitiesWithATokenNameTheSignedInPerson() async throws {
        let (caps, raw) = try await fetch(.capabilities, client(env.token))
        let user = try XCTUnwrap(caps.user, "a call with a valid bearer was not told who it is")
        XCTAssertEqual(user.id, raw["user"]?["id"]?.string)
        XCTAssertEqual(user.via, "bearer")
        XCTAssertNotNil(user.email)
        XCTAssertFalse(user.id.isEmpty)
    }

    func testABadOrExpiredTokenIsJustAnonymousOnCapabilities() async throws {
        let caps = try await send(.capabilities, client("not-a-token"))
        XCTAssertNil(caps.user, "capabilities are public and must not turn a bad token into a person")
        if let expired = env.expiredToken {
            let afterExpiry = try await send(.capabilities, client(expired))
            XCTAssertNil(afterExpiry.user)
        }
    }

    // MARK: Refusals the app special-cases

    func testAnAuthenticatedRouteRefusesNoTokenWithA401TheAppCanShow() async throws {
        let anonymous = client(nil)
        // No provider at all: the client refuses before sending.
        do {
            _ = try await anonymous.sendRaw(.yours())
            XCTFail("a call with no token went out")
        } catch {
            XCTAssertEqual(error as? HVError, .unauthorized)
        }
        // Optional auth on a private route reaches the server, which says 401.
        let failure = await expectFailure(401, Endpoint<NoContent>(.get, "/api/yours", auth: .optional), anonymous)
        XCTAssertNotNil(failure)
    }

    func testABadTokenIsA401AndAnExpiredTokenToo() async throws {
        await expectFailure(401, Endpoint<NoContent>(.get, "/api/yours"), client("garbage.token.here"))
        if let expired = env.expiredToken {
            await expectFailure(401, Endpoint<NoContent>(.get, "/api/yours"), client(expired))
        }
    }

    func testAWaitlistedAccountIsTold403WithTheWaitlistSentence() async throws {
        let (carol, _) = try waitlisted()
        let failure = await expectFailure(403, .yours(), carol, message: "waitlist")
        XCTAssertTrue(HVError.api(try XCTUnwrap(failure)).isWaitlisted)
    }

    func testAnUnknownPageIs404WithAMessage() async throws {
        let (api, _) = member(0)
        await expectFailure(404, .artifactContent(slug: "no-such-page-\(unique("x"))"), api)
        await expectFailure(404, .artifactVersions(slug: "no-such-page-\(unique("x"))"), api)
    }

    // MARK: Keep

    func testKeepANoteThenFindItInYoursAndReadItBack() async throws {
        let (api, _) = member(0)
        let word = uniqueWord()
        let kept = try await send(.keep(content: "Remember the \(word) thing for the trip.", title: "Trip \(word)"), api)
        XCTAssertEqual(kept.kind, .page)
        XCTAssertEqual(kept.form, "note")
        XCTAssertEqual(kept.title, "Trip \(word)")
        XCTAssertTrue(kept.isPrivate, "a kept thing must come back private: \(kept.visibility)")
        XCTAssertFalse(kept.duplicate)
        XCTAssertTrue(kept.url.hasSuffix("/a/\(kept.slug)"), kept.url)

        // Yours lists it, newest first, in both lists, with the href the app opens.
        let (yours, raw) = try await fetch(.yours(), api)
        XCTAssertEqual(yours.recent.count, rawCount(raw, "recent"))
        XCTAssertEqual(yours.results.count, rawCount(raw, "results"))
        let item = try XCTUnwrap(yours.results.first { $0.slug == kept.slug }, "the kept note is not in Yours")
        XCTAssertEqual(item.name, "Trip \(word)")
        XCTAssertEqual(item.href, "/a/\(kept.slug)")
        XCTAssertEqual(item.kind, .page)
        XCTAssertNotNil(item.updatedAt, "updated_at did not parse")

        // Search finds it by a word in the body, and not by a word that is nowhere.
        let found = try await send(.yours(query: word), api)
        XCTAssertTrue(found.results.contains { $0.slug == kept.slug }, "search did not find the note by its body")
        let nothing = try await send(.yours(query: uniqueWord()), api)
        XCTAssertTrue(nothing.results.isEmpty)

        // The artifact's editable source is the note.
        let content = try await send(.artifactContent(slug: kept.slug), api)
        XCTAssertTrue(content.content.contains(word))
        XCTAssertEqual(content.slug, kept.slug)
    }

    func testKeepingTheSameContentTwiceAnswersTheFirstLink() async throws {
        let (api, _) = member(0)
        let text = "Exactly this, once: \(uniqueWord())"
        let first = try await send(.keep(content: text), api)
        let second = try await send(.keep(content: text), api)
        XCTAssertFalse(first.duplicate)
        XCTAssertTrue(second.duplicate, "the same content kept twice was not recognised")
        XCTAssertEqual(second.slug, first.slug)
    }

    func testKeepHTMLAndReactAreRecognised() async throws {
        let (api, _) = member(0)
        let marker = uniqueWord()
        let html = try await send(.keep(content: "<!doctype html><html><head><title>Page \(marker)</title></head><body><h1>\(marker)</h1></body></html>"), api)
        XCTAssertEqual(html.form, "html")
        let react = try await send(.keep(content: """
        import React, { useState } from "react";
        export default function App() {
          const [n, setN] = useState(0);
          return <button onClick={() => setN(n + 1)}>\(marker) {n}</button>;
        }
        """), api)
        XCTAssertEqual(react.form, "jsx")

        let list = try await send(.artifacts, api)
        let htmlRow = try XCTUnwrap(list.items.first { $0.slug == html.slug })
        let reactRow = try XCTUnwrap(list.items.first { $0.slug == react.slug })
        XCTAssertFalse(htmlRow.isJsx)
        XCTAssertTrue(reactRow.isJsx, "a React page must say so")
        XCTAssertEqual(htmlRow.visibility, .private)

        // The Kit reads a React page's source as the JSX and the stored copy as wrapped markup.
        let content = try await send(.artifactContent(slug: react.slug), api)
        XCTAssertTrue(content.isJsx)
        XCTAssertTrue(content.content.contains("useState"))
        let source = try await send(.artifactSource(slug: react.slug), api)
        XCTAssertFalse(source.content.isEmpty)
    }

    func testYoursFiltersSeparateMemoriesFilesAndKeys() async throws {
        let (api, _) = member(1)
        let word = uniqueWord()
        let page = try await send(.keep(content: "A page about \(word)."), api)
        let memory = try await send(.memoryCreate(MemoryDraft(content: "About \(word).", title: "Memory \(word)")), api)
        for filter in YoursFilter.allCases {
            let (list, raw) = try await fetch(.yours(filter: filter), api)
            XCTAssertEqual(list.results.count, rawCount(raw, "results"), "\(filter)")
            switch filter {
            case .memory:
                XCTAssertTrue(list.results.allSatisfy { $0.kind == .memory }, "the memory filter let \(list.results.map(\.kind)) through")
                XCTAssertTrue(list.results.contains { $0.id == memory.id }, "the memory is missing from its filter")
            case .file:
                XCTAssertTrue(list.results.allSatisfy { $0.kind != .memory && $0.kind != .key })
                XCTAssertTrue(list.results.contains { $0.slug == page.slug })
            case .key:
                XCTAssertTrue(list.results.allSatisfy { $0.kind == .key })
            case .all:
                XCTAssertTrue(list.results.contains { $0.slug == page.slug })
            }
        }
        let limited = try await send(.yours(limit: 1), api)
        XCTAssertLessThanOrEqual(limited.results.count, 1)
    }
}
