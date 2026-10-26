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
