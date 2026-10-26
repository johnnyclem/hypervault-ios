import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

final class AuthTests: XCTestCase {
    let config = SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon-key")

    static func tokenJSON(access: String, refresh: String, expiresAt: Int = 4_000_000_000) -> String {
        """
        {"access_token":"\(access)","token_type":"bearer","expires_in":3600,"expires_at":\(expiresAt),
         "refresh_token":"\(refresh)",
         "user":{"id":"u1","email":"sam@example.com","app_metadata":{"provider":"google"},
                 "user_metadata":{"full_name":"Sam Rivers","avatar_url":"https://img.test/a.png"}}}
        """
    }

    func service(_ transport: MockTransport, store: SecureStore = InMemorySecureStore(), now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AuthService {
        AuthService(config: config, transport: transport, store: store, now: { now })
    }

    func testAuthorizationURLCarriesPKCEChallenge() async throws {
        let store = InMemorySecureStore()
        let auth = service(MockTransport(), store: store)
        let url = try await auth.authorizationURL(provider: "google", redirectTo: URL(string: "hypervault://auth/callback")!)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/auth/v1/authorize")
        XCTAssertEqual(items["provider"], "google")
        XCTAssertEqual(items["redirect_to"], "hypervault://auth/callback")
        XCTAssertEqual(items["code_challenge_method"], "s256")
        let verifier = String(decoding: await store.get("hypervault.pkce.verifier") ?? Data(), as: UTF8.self)
        XCTAssertEqual(items["code_challenge"], PKCE.challenge(for: verifier))
    }

    func testCompleteOAuthExchangesTheCodeAndSignsIn() async throws {
        let transport = MockTransport(routes: [.json(.post, "/auth/v1/token", AuthTests.tokenJSON(access: "A1", refresh: "R1"))])
        let store = InMemorySecureStore()
        let auth = service(transport, store: store)
        _ = try await auth.authorizationURL(provider: "google", redirectTo: URL(string: "hypervault://auth/callback")!)
        let session = try await auth.completeOAuth(callbackURL: URL(string: "hypervault://auth/callback?code=abc123")!)

        XCTAssertEqual(session.accessToken, "A1")
        XCTAssertEqual(session.user.email, "sam@example.com")
        XCTAssertEqual(session.user.displayName, "Sam Rivers")
        XCTAssertEqual(session.user.firstName, "Sam")
        XCTAssertEqual(session.user.provider, "google")
        let state = await auth.state
        XCTAssertEqual(state, .signedIn(session.user))

        let sent = await transport.requests.last
        XCTAssertEqual(sent?.url?.query, "grant_type=pkce")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "apikey"), "anon-key")
        let body = try JSONDecoder().decode([String: String].self, from: sent?.httpBody ?? Data())
        XCTAssertEqual(body["auth_code"], "abc123")
        XCTAssertNotNil(body["code_verifier"])
        let leftover = await store.get("hypervault.pkce.verifier")
        XCTAssertNil(leftover, "the verifier is single-use")
    }

    func testCallbackErrorsBecomeReadableMessages() async {
        let auth = service(MockTransport())
        do {
            _ = try await auth.completeOAuth(callbackURL: URL(string: "hypervault://auth/callback?error=server_error&error_description=Unable+to+exchange+external+code")!)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .failed("Unable to exchange external code"))
        }
        do {
            _ = try await auth.completeOAuth(callbackURL: URL(string: "hypervault://auth/callback?error=access_denied")!)
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? AuthError, .cancelled)
        }
    }

    func testExpiringTokenIsRefreshedOnce() async throws {
        let transport = MockTransport()
        let counter = Counter()
        await transport.add(MockRoute(.post, "/auth/v1/token") { request in
            counter.bump()
            XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
            return HTTPResponse(status: 200, data: Data(AuthTests.tokenJSON(access: "A2", refresh: "R2").utf8))
        })
        let store = InMemorySecureStore()
        let old = AuthSession(
            accessToken: "A1", refreshToken: "R1",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
            user: AuthUser(id: "u1", email: "sam@example.com")
        )
        await store.set(try HVCoding.encoder(.verbatim).encode(old), for: "hypervault.session")
        let auth = service(transport, store: store)
        await auth.restore()

        async let one = auth.accessToken()
        async let two = auth.accessToken()
        let (a, b) = try await (one, two)
        XCTAssertEqual(a, "A2")
        XCTAssertEqual(b, "A2")
        XCTAssertEqual(counter.value, 1, "concurrent callers share one refresh")

        let saved = await store.get("hypervault.session")
        let stored = try HVCoding.decoder(.verbatim).decode(AuthSession.self, from: saved ?? Data())
        XCTAssertEqual(stored.refreshToken, "R2")
    }

    func testRejectedRefreshTokenSignsOut() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/auth/v1/token", #"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#, status: 400),
        ])
        let store = InMemorySecureStore()
        let old = AuthSession(
            accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSince1970: 1_000),
            user: AuthUser(id: "u1", email: nil)
        )
        await store.set(try HVCoding.encoder(.verbatim).encode(old), for: "hypervault.session")
        let auth = service(transport, store: store)
        await auth.restore()

        let token = try await auth.accessToken()
        XCTAssertNil(token)
        let state = await auth.state
        XCTAssertEqual(state, .signedOut)
        let kept = await store.get("hypervault.session")
        XCTAssertNil(kept)
    }

    func testOfflineRefreshKeepsTheSession() async throws {
        struct Offline: HTTPTransport {
            func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
        }
        let store = InMemorySecureStore()
        // Valid for another 30 seconds: inside the refresh margin, not yet expired.
        let old = AuthSession(
            accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
            user: AuthUser(id: "u1", email: nil)
        )
        await store.set(try HVCoding.encoder(.verbatim).encode(old), for: "hypervault.session")
        let auth = AuthService(config: config, transport: Offline(), store: store, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        await auth.restore()
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A1")
        let state = await auth.state
        XCTAssertEqual(state, .signedIn(old.user))
    }

    func testAppleIDTokenExchange() async throws {
        let transport = MockTransport(routes: [.json(.post, "/auth/v1/token", AuthTests.tokenJSON(access: "AP", refresh: "RP"))])
        let auth = service(transport)
        let session = try await auth.signIn(withIDToken: "apple-jwt", nonce: "raw-nonce")
        XCTAssertEqual(session.accessToken, "AP")
        let sent = await transport.requests.last
        XCTAssertEqual(sent?.url?.query, "grant_type=id_token")
        let body = try JSONDecoder().decode([String: String].self, from: sent?.httpBody ?? Data())
        XCTAssertEqual(body, ["provider": "apple", "id_token": "apple-jwt", "nonce": "raw-nonce"])
    }

    func testEmailCodeFlow() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/auth/v1/otp", "{}"),
            .json(.post, "/auth/v1/verify", AuthTests.tokenJSON(access: "EM", refresh: "RE")),
        ])
        let auth = service(transport)
        try await auth.requestEmailCode(email: " sam@example.com ")
        let session = try await auth.verifyEmailCode(email: "sam@example.com", code: "123 456")
        XCTAssertEqual(session.accessToken, "EM")
        let requests = await transport.requests
        let verify = try JSONDecoder().decode([String: String].self, from: requests[1].httpBody ?? Data())
        XCTAssertEqual(verify["token"], "123456")
        XCTAssertEqual(verify["type"], "email")
        let otp = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(otp?["email"] as? String, "sam@example.com")
        XCTAssertEqual(otp?["create_user"] as? Bool, true)
    }

    func testWrongEmailCodeSaysSo() async {
        let transport = MockTransport(routes: [
            .json(.post, "/auth/v1/verify", #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#, status: 403),
        ])
        let auth = service(transport)
        do {
            _ = try await auth.verifyEmailCode(email: "a@b.co", code: "000000")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .failed("That code has expired. Ask for a new one."))
        }
    }

    func testSignOutClearsEverythingEvenWhenOffline() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/auth/v1/token", AuthTests.tokenJSON(access: "A1", refresh: "R1")),
            .json(.post, "/auth/v1/logout", "", status: 204),
        ])
        let auth = service(transport)
        _ = try await auth.signIn(withIDToken: "x", nonce: nil)
        await auth.signOut()
        let state = await auth.state
        XCTAssertEqual(state, .signedOut)
        let token = try await auth.accessToken()
        XCTAssertNil(token)
        let logout = await transport.requests.last
        XCTAssertEqual(logout?.url?.path, "/auth/v1/logout")
        XCTAssertEqual(logout?.value(forHTTPHeaderField: "Authorization"), "Bearer A1")
    }

    func testProvidersFromSettings() async {
        let transport = MockTransport(routes: [
            .json(.get, "/auth/v1/settings", #"{"external":{"google":true,"apple":true,"email":false},"disable_signup":false}"#),
        ])
        let providers = await service(transport).providers()
        XCTAssertEqual(providers, AuthProviders(google: true, apple: true, email: false, signupDisabled: false))
    }

    func testStatesStreamStartsWithCurrentState() async {
        let auth = service(MockTransport())
        await auth.restore()
        var iterator = await auth.states().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .signedOut)
    }
}

/// Shared setup for the refresh tests: sessions written straight into a store, the way the
/// app, a widget or the share extension would have left them.
class RefreshTestCase: XCTestCase {
    let config = SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon-key")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let sessionKey = "hypervault.session"

    /// Long past: needs a refresh before it can be used.
    static let expired: TimeInterval = 1_000
    /// Still valid, but inside the refresh margin.
    static let expiring: TimeInterval = 1_800_000_030
    /// A token with a long life left.
    static let fresh: TimeInterval = 4_000_000_000

    func service(_ transport: HTTPTransport, store: SecureStore) -> AuthService {
        AuthService(config: config, transport: transport, store: store, now: { Self.now })
    }

    @discardableResult
    func seed(
        _ store: SecureStore, access: String = "A1", refresh: String = "R1",
        expiresAt: TimeInterval = RefreshTestCase.expired, userID: String = "u1"
    ) async throws -> AuthSession {
        let session = AuthSession(
            accessToken: access, refreshToken: refresh, expiresAt: Date(timeIntervalSince1970: expiresAt),
            user: AuthUser(id: userID, email: "sam@example.com")
        )
        await store.set(try HVCoding.encoder(.verbatim).encode(session), for: Self.sessionKey)
        return session
    }

    func stored(_ store: SecureStore) async throws -> AuthSession? {
        guard let data = await store.get(Self.sessionKey) else { return nil }
        return try HVCoding.decoder(.verbatim).decode(AuthSession.self, from: data)
    }
}

/// A refresh that did not work is only a sign-out when the server refused the refresh token.
final class RefreshResilienceTests: RefreshTestCase {
    func api(_ transport: MockTransport, store: SecureStore, baseURL: String = "https://hv.test") -> HVClient {
        HVClient(baseURL: URL(string: baseURL)!, transport: transport, tokens: service(transport, store: store), retry: .none, sleep: { _ in })
    }

    func testABusyAuthServerNeverEndsTheSession() async throws {
        let answers: [(Int, String)] = [
            (408, ""),
            (429, #"{"code":429,"error_code":"over_request_rate_limit","msg":"Request rate limit reached"}"#),
            (500, #"{"msg":"Database error"}"#),
            (502, "<html><body>Bad Gateway</body></html>"),
            (503, #"{"msg":"upstream unavailable"}"#),
            (504, ""),
        ]
        for (status, body) in answers {
            let store = InMemorySecureStore()
            try await seed(store)
            let auth = service(MockTransport(routes: [.json(.post, "/auth/v1/token", body, status: status)]), store: store)
            await auth.restore()

            do {
                _ = try await auth.accessToken()
                XCTFail("\(status): an expired token and no refresh cannot give a token")
            } catch let error as HVError {
                XCTAssertEqual(error.status, status, "\(status)")
                XCTAssertFalse(error.isUnauthorized, "\(status): nobody is being signed out")
            }
            let state = await auth.state
            XCTAssertEqual(state, .signedIn(AuthUser(id: "u1", email: "sam@example.com")), "\(status)")
            let kept = try await stored(store)
            XCTAssertEqual(kept?.refreshToken, "R1", "\(status): the refresh token is still the one to try next")
        }
    }

    func testTheSentenceForABusyAuthServerIsHonest() async throws {
        for (status, sentence) in [
            (429, "Too many requests. Wait a moment and try again."),
            (503, "Your session could not be renewed right now. Try again in a moment."),
        ] {
            let store = InMemorySecureStore()
            try await seed(store)
            let auth = service(MockTransport(routes: [.json(.post, "/auth/v1/token", "{}", status: status)]), store: store)
            do {
                _ = try await auth.accessToken()
                XCTFail("expected a failure")
            } catch let error as HVError {
                XCTAssertEqual(error.userMessage, sentence)
                XCTAssertFalse(error.isOffline, "\(status) is not the phone being offline")
            }
        }
    }

    func testBusyAuthFallsBackToTheTokenThatStillWorks() async throws {
        let store = InMemorySecureStore()
        let session = try await seed(store, expiresAt: Self.expiring)
        let auth = service(MockTransport(routes: [.json(.post, "/auth/v1/token", "{}", status: 503)]), store: store)
        await auth.restore()
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A1")
        let state = await auth.state
        XCTAssertEqual(state, .signedIn(session.user))
    }

    func testAnswersThatAreNotARefusalKeepTheSession() async throws {
        // A proxy's page, a captive portal, an error that names no token: none of them is the server
        // saying this refresh token is dead.
        let answers: [(Int, String)] = [
            (403, "<html><body>Blocked by the firewall</body></html>"),
            (401, ""),
            (400, #"{"error":"something_else"}"#),
            (404, "Not Found"),
            (200, "<html><body>Sign in to the Wi-Fi</body></html>"),
        ]
        for (status, body) in answers {
            let store = InMemorySecureStore()
            try await seed(store)
            let auth = service(MockTransport(routes: [.json(.post, "/auth/v1/token", body, status: status)]), store: store)
            await auth.restore()
            do {
                _ = try await auth.accessToken()
                XCTFail("\(status): expected a failure")
            } catch let error as HVError {
                XCTAssertTrue(error.isOffline, "\(status): reads as a connection problem, never as a sign-out")
            }
            let state = await auth.state
            XCTAssertNotEqual(state, .signedOut, "\(status)")
            let kept = try await stored(store)
            XCTAssertNotNil(kept, "\(status)")
        }
    }

    func testARefusedRefreshTokenEndsTheSession() async throws {
        let refusals: [(Int, String)] = [
            (400, #"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#),
            (400, #"{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}"#),
            (400, #"{"code":400,"error_code":"refresh_token_already_used","msg":"Refused"}"#),
            (401, #"{"msg":"Invalid Refresh Token: Session Expired"}"#),
            (403, #"{"code":403,"error_code":"session_not_found","msg":"Session does not exist"}"#),
            (403, #"{"code":403,"error_code":"user_banned","msg":"User is banned"}"#),
        ]
        for (status, body) in refusals {
            let store = InMemorySecureStore()
            try await seed(store)
            let auth = service(MockTransport(routes: [.json(.post, "/auth/v1/token", body, status: status)]), store: store)
            await auth.restore()
            let token = try await auth.accessToken()
            XCTAssertNil(token, "\(body)")
            let state = await auth.state
            XCTAssertEqual(state, .signedOut, "\(body)")
            let kept = try await stored(store)
            XCTAssertNil(kept, "\(body)")
        }
    }

    func testA401ThenABusyAuthServerIsNotASignOut() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/thing", #"{"error":"Invalid or expired access token"}"#, status: 401),
            .json(.post, "/auth/v1/token", "{}", status: 503),
        ])
        let store = InMemorySecureStore()
        let session = try await seed(store, expiresAt: Self.fresh)
        let client = api(transport, store: store)
        do {
            let _: Thing = try await client.send(Endpoint(.get, "/api/thing"))
            XCTFail("expected a failure")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 503)
            XCTAssertNotEqual(error, .unauthorized)
        }
        let kept = try await stored(store)
        XCTAssertEqual(kept, session)
    }

    func testSignInKeepsTheServersOwnSentenceWhenItIsBusy() async {
        let transport = MockTransport(routes: [
            .json(.post, "/auth/v1/otp", #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}"#, status: 429),
        ])
        let auth = service(transport, store: InMemorySecureStore())
        do {
            try await auth.requestEmailCode(email: "sam@example.com")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .failed("email rate limit exceeded"))
        }
    }
}

/// A GoTrue that rotates refresh tokens: each one works once and is answered with the next
/// (`R1` gives `A2` and `R2`). A token that was already used is refused.
final class RotatingGoTrue: @unchecked Sendable {
    private let lock = NSLock()
    private var spent: Set<String>
    private var presented: [String] = []

    init(spent: Set<String> = []) { self.spent = spent }

    /// The refresh tokens the server was shown, in order.
    var attempts: [String] { lock.lock(); defer { lock.unlock() }; return presented }

    var route: MockRoute {
        MockRoute(.post, "/auth/v1/token") { request in self.answer(request) }
    }

    private func answer(_ request: URLRequest) -> HTTPResponse {
        let body = (try? JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())) ?? [:]
        let token = body["refresh_token"] ?? ""
        lock.lock()
        defer { lock.unlock() }
        presented.append(token)
        if spent.contains(token) {
            return HTTPResponse(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#.utf8))
        }
        spent.insert(token)
        let number = Int(token.dropFirst()) ?? 0
        return HTTPResponse(status: 200, data: Data(AuthTests.tokenJSON(access: "A\(number + 1)", refresh: "R\(number + 1)").utf8))
    }
}

/// The app, the widgets, the share extension and Shortcuts each run their own `AuthService` over
/// one shared Keychain item, and a refresh token works once. The store is the truth.
final class SharedSessionTests: RefreshTestCase {
    func testASessionAnotherProcessRefreshedIsUsedNotRefreshedAgain() async throws {
        let gotrue = RotatingGoTrue()
        let transport = MockTransport(routes: [gotrue.route])
        let store = InMemorySecureStore()
        try await seed(store, expiresAt: Self.expiring)
        let app = service(transport, store: store)
        let widget = service(transport, store: store)
        await app.restore()
        await widget.restore()

        let fromWidget = try await widget.accessToken()
        XCTAssertEqual(fromWidget, "A2")
        // The app still holds A1 and R1, which the widget has spent.
        let fromApp = try await app.accessToken()
        XCTAssertEqual(fromApp, "A2")
        XCTAssertEqual(gotrue.attempts, ["R1"], "the app did not show the server a token that was already used")
        let state = await app.state
        XCTAssertEqual(state.user?.id, "u1")
        let kept = try await stored(store)
        XCTAssertEqual(kept?.refreshToken, "R2")
    }

    func testARefreshStartsFromTheNewestRefreshToken() async throws {
        let gotrue = RotatingGoTrue(spent: ["R1"])
        let transport = MockTransport(routes: [gotrue.route])
        let store = InMemorySecureStore()
        try await seed(store)
        let app = service(transport, store: store)
        await app.restore()
        // Another process refreshed, and what it saved is about to expire too.
        try await seed(store, access: "A2", refresh: "R2", expiresAt: Self.expiring)

        let token = try await app.accessToken()
        XCTAssertEqual(token, "A3")
        XCTAssertEqual(gotrue.attempts, ["R2"])
    }

    func testARefusalDoesNotDeleteASessionAnotherProcessSavedMeanwhile() async throws {
        // The app's request is out when the widget saves R2; the server then refuses R1.
        struct SavesThenRefuses: HTTPTransport {
            let store: InMemorySecureStore
            let saved: Data
            func send(_ request: URLRequest) async throws -> HTTPResponse {
                await store.set(saved, for: "hypervault.session")
                return HTTPResponse(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#.utf8))
            }
        }
        let store = InMemorySecureStore()
        try await seed(store)
        let widgetSession = AuthSession(
            accessToken: "A2", refreshToken: "R2", expiresAt: Date(timeIntervalSince1970: Self.fresh),
            user: AuthUser(id: "u1", email: "sam@example.com")
        )
        let app = service(SavesThenRefuses(store: store, saved: try HVCoding.encoder(.verbatim).encode(widgetSession)), store: store)
        await app.restore()

        let token = try await app.accessToken()
        XCTAssertEqual(token, "A2", "the newer session is used")
        let state = await app.state
        XCTAssertEqual(state, .signedIn(widgetSession.user))
        let kept = try await stored(store)
        XCTAssertEqual(kept, widgetSession, "the widget's session is still in the Keychain")
    }

    func testAnOlderStoredSessionNeverReplacesTheLiveOne() async throws {
        let gotrue = RotatingGoTrue(spent: ["R1"])
        let transport = MockTransport(routes: [gotrue.route])
        let store = InMemorySecureStore()
        try await seed(store, access: "A2", refresh: "R2", expiresAt: Self.expiring)
        let app = service(transport, store: store)
        await app.restore()
        // A write that did not take left the Keychain holding an older, spent session.
        try await seed(store, access: "A1", refresh: "R1", expiresAt: Self.expired)

        let token = try await app.accessToken()
        XCTAssertEqual(token, "A3")
        XCTAssertEqual(gotrue.attempts, ["R2"], "memory was newer, so memory is what was refreshed")
    }

    func testAnotherPersonsStoredSessionIsNotAdopted() async throws {
        let gotrue = RotatingGoTrue()
        let transport = MockTransport(routes: [gotrue.route])
        let store = InMemorySecureStore()
        try await seed(store, userID: "u1")
        let app = service(transport, store: store)
        await app.restore()
        try await seed(store, access: "B9", refresh: "RB9", expiresAt: Self.fresh, userID: "someone-else")

        _ = try await app.accessToken()
        XCTAssertEqual(gotrue.attempts, ["R1"])
    }

    func testReadingASlowStoreStillSharesOneRefresh() async throws {
        struct SlowStore: SecureStore {
            let inner = InMemorySecureStore()
            func get(_ key: String) async -> Data? {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return await inner.get(key)
            }
            func set(_ value: Data, for key: String) async { await inner.set(value, for: key) }
            func remove(_ key: String) async { await inner.remove(key) }
        }
        let gotrue = RotatingGoTrue()
        let transport = MockTransport(routes: [gotrue.route])
        let store = SlowStore()
        try await seed(store)
        let auth = service(transport, store: store)
        await auth.restore()

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<5 { group.addTask { try await auth.accessToken() } }
            var all: [String?] = []
            for try await token in group { all.append(token) }
            return all
        }
        XCTAssertEqual(tokens, Array(repeating: "A2", count: 5))
        XCTAssertEqual(gotrue.attempts, ["R1"], "callers that arrive while the store is read still share one request")
    }

    func testASignInDuringARefreshSurvivesTheOldSessionBeingRefused() async throws {
        final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var service: AuthService?
            var auth: AuthService? {
                get { lock.lock(); defer { lock.unlock() }; return service }
                set { lock.lock(); service = newValue; lock.unlock() }
            }
        }
        struct SignsInThenRefuses: HTTPTransport {
            let holder: Holder
            func send(_ request: URLRequest) async throws -> HTTPResponse {
                guard request.url?.query == "grant_type=refresh_token" else {
                    return HTTPResponse(status: 200, data: Data(AuthTests.tokenJSON(access: "B1", refresh: "RB1").utf8))
                }
                // The person signs in again while the old session's refresh is out.
                _ = try await holder.auth?.signIn(withIDToken: "apple-jwt", nonce: nil)
                return HTTPResponse(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#.utf8))
            }
        }
        let store = InMemorySecureStore()
        try await seed(store)
        let holder = Holder()
        let auth = service(SignsInThenRefuses(holder: holder), store: store)
        holder.auth = auth
        await auth.restore()

        _ = try await auth.accessToken()
        let state = await auth.state
        XCTAssertEqual(state.user?.id, "u1", "the new sign-in is still signed in")
        let kept = try await stored(store)
        XCTAssertEqual(kept?.refreshToken, "RB1", "the refusal was about R1, not about the session that replaced it")
    }

    func testReloadingFromTheStoreNeverSignsAnyoneOut() async throws {
        let store = InMemorySecureStore()
        let session = try await seed(store, expiresAt: Self.fresh)
        let auth = service(MockTransport(), store: store)
        await auth.restore()

        await store.remove(Self.sessionKey)
        await auth.reloadFromStore()
        var state = await auth.state
        XCTAssertEqual(state, .signedIn(session.user), "an empty read says nothing")

        await store.set(Data("not a session".utf8), for: Self.sessionKey)
        await auth.reloadFromStore()
        state = await auth.state
        XCTAssertEqual(state, .signedIn(session.user), "neither does an unreadable one")

        try await seed(store, access: "A2", refresh: "R2", expiresAt: Self.fresh + 100)
        await auth.reloadFromStore()
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A2", "a newer session is picked up")
    }
}

final class InviteTests: XCTestCase {
    let config = SupabaseConfig(url: URL(string: "https://proj.supabase.test")!, anonKey: "anon-key")

    func testRedeemCallsTheRPCWithTheUsersToken() async throws {
        let transport = MockTransport(routes: [.json(.post, "/rest/v1/rpc/redeem_invite_code", "\"ok\"")])
        let redeemer = InviteRedeemer(config: config, transport: transport, tokens: FakeTokens(token: "jwt"))
        let result = try await redeemer.redeem(" hv-ab12-cd34 ")
        XCTAssertEqual(result, .ok)
        XCTAssertTrue(result.isAccepted)
        let sent = await transport.requests.last
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "apikey"), "anon-key")
        let body = try JSONDecoder().decode([String: String].self, from: sent?.httpBody ?? Data())
        XCTAssertEqual(body["p_code"], "HV-AB12-CD34")
    }

    func testRefusalsComeBackAsResults() async throws {
        for (raw, expected) in [("invalid", InviteResult.invalid), ("exhausted", .exhausted), ("disabled", .disabled), ("already_approved", .alreadyApproved)] {
            let transport = MockTransport(routes: [.json(.post, "/rest/v1/rpc/redeem_invite_code", "\"\(raw)\"")])
            let redeemer = InviteRedeemer(config: config, transport: transport, tokens: FakeTokens(token: "jwt"))
            let result = try await redeemer.redeem("HV-AAAA-BBBB")
            XCTAssertEqual(result, expected)
        }
    }

    func testSignedOutCannotRedeem() async {
        let redeemer = InviteRedeemer(config: config, transport: MockTransport(), tokens: FakeTokens(token: nil))
        do {
            _ = try await redeemer.redeem("HV-AAAA-BBBB")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? HVError, .unauthorized)
        }
    }

    func testExtractsACodeFromPastedText() {
        XCTAssertEqual(InviteCode.extract(from: "https://hypervault.store/login?invite=hv-ab12-cd34&x=1"), "HV-AB12-CD34")
        XCTAssertEqual(InviteCode.extract(from: "Your code: HV-ZZZZ-9999!"), "HV-ZZZZ-9999")
        XCTAssertNil(InviteCode.extract(from: "no code here"))
    }
}
