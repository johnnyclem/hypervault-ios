import HyperVaultKit
import XCTest
@testable import HyperVault

/// The launch state machine: what the window shows for each thing the server can say.
@MainActor
final class AppModelTests: XCTestCase {
    private let capabilitiesJSON = """
    {"app_url":"https://hv.test","api_version":"2026-07-15",
     "auth":{"supabase_url":"https://proj.supabase.test","supabase_anon_key":"anon","invite_gated":true},
     "features":{},"limits":{},"providers":[],"domains":[],"themes":[]%@}
    """

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hv-model-\(UUID().uuidString)")
    }

    /// Capabilities answer without a `user` block for a stranger and for someone the gate refuses,
    /// and with one for a person who is let in.
    private func capabilitiesRoute(approved: Bool) -> MockRoute {
        let anonymous = String(format: capabilitiesJSON, "")
        let signedIn = String(format: capabilitiesJSON, #","user":{"id":"u1","email":"sam@example.com","via":"bearer"}"#)
        return MockRoute(.get, "/api/capabilities") { request in
            let hasToken = request.value(forHTTPHeaderField: "Authorization") != nil
            let body = hasToken && approved ? signedIn : anonymous
            return HTTPResponse(status: 200, data: Data(body.utf8))
        }
    }

    private func storedSession() async throws -> InMemorySecureStore {
        let store = InMemorySecureStore()
        let session = AuthSession(
            accessToken: "A1", refreshToken: "R1",
            expiresAt: Date().addingTimeInterval(3600),
            user: AuthUser(id: "u1", email: "sam@example.com", displayName: "Sam Rivers")
        )
        await store.set(try HVCoding.encoder(.verbatim).encode(session), for: "hypervault.session")
        return store
    }

    private func model(routes: [MockRoute], store: SecureStore = InMemorySecureStore()) -> AppModel {
        AppModel(
            secureStore: store,
            server: ServerConfig(baseURL: URL(string: "https://hv.test")!),
            transport: MockTransport(routes: routes),
            cacheDirectory: scratch()
        )
    }

    /// Waits for the model to reach a phase; the state machine settles on its own tasks.
    private func settle(_ model: AppModel, to phase: AppModel.Phase, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if model.phase == phase { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("Expected \(phase), still \(model.phase)", file: file, line: line)
    }

    func testNobodySignedInShowsTheWayIn() async {
        let app = model(routes: [capabilitiesRoute(approved: true), .json(.get, "/auth/v1/settings", #"{"external":{"google":true,"apple":true,"email":true}}"#)])
        await app.start()
        await settle(app, to: .signedOut)
        XCTAssertNil(app.env)
        XCTAssertEqual(app.providers, AuthProviders(google: true, apple: true, email: true, signupDisabled: false))
    }

    func testAnApprovedPersonLandsInTheApp() async throws {
        let app = model(routes: [capabilitiesRoute(approved: true), .json(.get, "/auth/v1/settings", "{}")], store: try await storedSession())
        await app.start()
        await settle(app, to: .ready)
        XCTAssertEqual(app.env?.user.id, "u1")
        XCTAssertEqual(app.env?.user.firstName, "Sam")
    }

    func testSomeoneNotLetInYetSeesTheWaitlist() async throws {
        let app = model(routes: [capabilitiesRoute(approved: false), .json(.get, "/auth/v1/settings", "{}")], store: try await storedSession())
        await app.start()
        guard case .waitlisted(let user) = await waitForWaitlist(app) else { return XCTFail("expected the waitlist, got \(app.phase)") }
        XCTAssertEqual(user.id, "u1")
        XCTAssertNil(app.env)
    }

    private func waitForWaitlist(_ app: AppModel) async -> AppModel.Phase {
        for _ in 0..<100 {
            if case .waitlisted = app.phase { return app.phase }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return app.phase
    }

    func testAnInviteCodeLetsThemIn() async throws {
        let approved = Flag()
        let capabilities = MockRoute(.get, "/api/capabilities") { [capabilitiesJSON] request in
            let letIn = approved.isSet && request.value(forHTTPHeaderField: "Authorization") != nil
            let extra = letIn ? #","user":{"id":"u1","email":"sam@example.com","via":"bearer"}"# : ""
            return HTTPResponse(status: 200, data: Data(String(format: capabilitiesJSON, extra).utf8))
        }
        let redeem = MockRoute(.post, "/rest/v1/rpc/redeem_invite_code") { _ in
            approved.set()
            return HTTPResponse(status: 200, data: Data("\"ok\"".utf8))
        }
        let app = model(routes: [capabilities, redeem, .json(.get, "/auth/v1/settings", "{}")], store: try await storedSession())
        await app.start()
        _ = await waitForWaitlist(app)

        let result = try await app.redeemInvite("hv-aaaa-bbbb")
        XCTAssertEqual(result, .ok)
        await settle(app, to: .ready)
    }

    func testAServerThatCannotBeReachedAndNothingCachedSaysSo() async {
        let app = model(routes: [])
        await app.start()
        guard case .unreachable(let message) = app.phase else { return XCTFail("expected unreachable, got \(app.phase)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testSigningOutReturnsToTheWayIn() async throws {
        let app = model(routes: [capabilitiesRoute(approved: true), .json(.get, "/auth/v1/settings", "{}"), .json(.post, "/auth/v1/logout", "", status: 204)], store: try await storedSession())
        await app.start()
        await settle(app, to: .ready)
        await app.signOut()
        await settle(app, to: .signedOut)
        XCTAssertNil(app.env)
    }

    func testALinkOpenedBeforeSignInIsFollowedAfter() async throws {
        let app = model(routes: [capabilitiesRoute(approved: true), .json(.get, "/auth/v1/settings", "{}")], store: try await storedSession())
        app.handle(url: URL(string: "hypervault://tab/memory")!)
        await app.start()
        await settle(app, to: .ready)
        XCTAssertEqual(app.router.tab, .memory)
    }

    func testAnInviteLinkBeforeSignInIsRemembered() {
        let app = model(routes: [])
        app.handle(url: URL(string: "https://hypervault.store/login?invite=HV-AB12-CD34")!)
        XCTAssertEqual(app.pendingInviteCode, "HV-AB12-CD34")
    }
}

/// A flag the mock routes can flip from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
