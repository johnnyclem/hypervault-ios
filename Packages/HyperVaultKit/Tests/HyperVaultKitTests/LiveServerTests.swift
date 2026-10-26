import XCTest
@testable import HyperVaultKit

/// What the Kit does against a real deployment, with nobody signed in: the launch path every new person takes.
/// These stay out of the normal run (they need the network and a server). To run them:
///
///     HV_LIVE_SERVER=https://hypervault.store swift test --filter LiveServerTests
///
/// They only read, and they send no credentials, so they are safe to point at production.
final class LiveServerTests: XCTestCase {
    private func server() throws -> ServerConfig {
        guard let text = ProcessInfo.processInfo.environment["HV_LIVE_SERVER"], let config = ServerConfig(userInput: text) else {
            throw XCTSkip("Set HV_LIVE_SERVER to a deployment's address to run the live checks.")
        }
        return config
    }

    private func client(_ config: ServerConfig) -> HVClient {
        HVClient(baseURL: config.baseURL, transport: URLSessionTransport())
    }

    func testTheCapabilitiesAnswerDecodesAndNamesAProjectToSignInAgainst() async throws {
        let config = try server()
        let capabilities = try await client(config).send(.capabilities)
        let supabase = try XCTUnwrap(capabilities.supabase, "the server names no Supabase project, so nobody could sign in")
        XCTAssertEqual(supabase.url.scheme, "https")
        XCTAssertGreaterThan(capabilities.limits.chatMessageChars, 0)
        XCTAssertGreaterThan(capabilities.limits.artifactBytes, 0)
        XCTAssertFalse(capabilities.providers.isEmpty, "no chat providers decoded")
        XCTAssertNil(capabilities.user, "an anonymous call must not be told it is a person")
    }

    func testTheProjectOffersAWayIn() async throws {
        let config = try server()
        let capabilities = try await client(config).send(.capabilities)
        let supabase = try XCTUnwrap(capabilities.supabase)
        let auth = AuthService(config: supabase, transport: URLSessionTransport(), store: InMemorySecureStore())
        let providers = await auth.providers()
        XCTAssertTrue(providers.google || providers.apple || providers.email, "the sign-in screen would have nothing to offer: \(providers)")
        print("live sign-in methods: google=\(providers.google) apple=\(providers.apple) email=\(providers.email) signupDisabled=\(providers.signupDisabled)")
    }

    /// The Kit's refresh handling against the project's real GoTrue, with a session made up for the purpose: the
    /// server has never seen these refresh tokens, so it refuses them, and the Kit must read that as "signed out".
    func testARefreshTokenTheServerNeverIssuedEndsTheSession() async throws {
        let config = try server()
        let capabilities = try await client(config).send(.capabilities)
        let supabase = try XCTUnwrap(capabilities.supabase)
        for refreshToken in ["abcdefghijkl", "123456789012", "not-a-token", ""] {
            let store = InMemorySecureStore()
            let made = AuthSession(
                accessToken: "expired", refreshToken: refreshToken, expiresAt: Date(timeIntervalSince1970: 1_000),
                user: AuthUser(id: "00000000-0000-4000-8000-000000000000", email: nil)
            )
            await store.set(try HVCoding.encoder(.verbatim).encode(made), for: "hypervault.session")
            let auth = AuthService(config: supabase, transport: URLSessionTransport(), store: store)
            await auth.restore()
            let token = try? await auth.accessToken()
            XCTAssertNil(token ?? nil, "refresh token '\(refreshToken)'")
            let kept = await store.get("hypervault.session")
            XCTAssertNil(kept, "the real server refused '\(refreshToken)' and the Kit kept the session")
        }
    }

    func testAnAnonymousCallIsRefusedWithASentenceAPersonCanRead() async throws {
        let config = try server()
        do {
            _ = try await client(config).send(Endpoint<NoContent>(.get, "/api/yours", auth: AuthMode.none))
            XCTFail("an anonymous call to a private route was accepted")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 401)
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    func testThePagesTheAppLinksToExist() async throws {
        let config = try server()
        for path in ["/explain.md", "/connect.md"] {
            let response = try await client(config).sendRaw(Endpoint<NoContent>(.get, path, auth: AuthMode.none))
            XCTAssertEqual(response.status, 200, path)
            XCTAssertGreaterThan(response.data.count, 100, path)
        }
    }
}
