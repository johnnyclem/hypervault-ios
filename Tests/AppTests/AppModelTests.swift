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


    override func setUp() {
        super.setUp()
        SharedState.begin()
    }

    override func tearDown() {
        SharedState.end()
        super.tearDown()
    }

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

    /// What a signed-in session needs from the auth server, whatever the gate says.
    private var authRoutes: [MockRoute] {
        [.json(.get, "/auth/v1/settings", "{}"), .json(.post, "/auth/v1/logout", "", status: 204)]
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
        model(transport: MockTransport(routes: routes), store: store)
    }

    private func model(
        transport: HTTPTransport,
        store: SecureStore = InMemorySecureStore(),
        server: ServerConfig = ServerConfig(baseURL: URL(string: "https://hv.test")!)
    ) -> AppModel {
        AppModel(secureStore: store, server: server, transport: transport, cacheDirectory: scratch())
    }

    /// Waits for the model to reach a phase; the state machine settles on its own tasks.
    private func settle(_ model: AppModel, to phase: AppModel.Phase, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
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

    // MARK: What an account leaves on the phone

    /// Puts the things a signed-in person leaves behind in place, and returns the cache they were filed in.
    private func leaveTraces(of app: AppModel) async throws -> DiskCache {
        let cache = try XCTUnwrap(app.env?.cache)
        await cache.store("kept", key: "yours", namespace: "u1")
        OutboxStore.add(OutboxItem(content: "a pasted secret"))
        SharedConfig.defaults.set(Data("[]".utf8), forKey: SharedConfig.widgetRecentKey)
        app.router.push(.memory(id: "m1"), on: .yours)
        app.router.sheet = .connectAgent
        app.router.canvasDraft = "half a thought"
        app.router.tab = .yours
        return cache
    }

    private func assertTracesGone(of app: AppModel, in cache: DiskCache, file: StaticString = #filePath, line: UInt = #line) async {
        let cached = await cache.entry(String.self, key: "yours", namespace: "u1")
        XCTAssertNil(cached, "the cache", file: file, line: line)
        XCTAssertEqual(OutboxStore.count, 0, "the outbox", file: file, line: line)
        XCTAssertNil(SharedConfig.defaults.object(forKey: SharedConfig.widgetRecentKey), "the widget's names", file: file, line: line)
        XCTAssertNil(SharedConfig.defaults.string(forKey: PrefKey.approvedUser), "the approval", file: file, line: line)
        XCTAssertNil(SharedConfig.defaults.string(forKey: PrefKey.sessionUser), "the marker", file: file, line: line)
        XCTAssertEqual(app.router.path(for: .yours).wrappedValue.count, 0, "the pushed screens", file: file, line: line)
        XCTAssertNil(app.router.sheet, "the sheet", file: file, line: line)
        XCTAssertNil(app.router.canvasDraft, "the draft", file: file, line: line)
        XCTAssertEqual(app.router.tab, .canvas, "the tab", file: file, line: line)
    }

    func testSigningOutTakesWhatTheAccountLeftOffThePhone() async throws {
        let app = model(routes: [capabilitiesRoute(approved: true)] + authRoutes, store: try await storedSession())
        await app.start()
        await settle(app, to: .ready)
        let cache = try await leaveTraces(of: app)
        XCTAssertEqual(SharedConfig.defaults.string(forKey: PrefKey.sessionUser), "u1")

        await app.signOut()
        await settle(app, to: .signedOut)
        await assertTracesGone(of: app, in: cache)
    }

    func testASessionThatEndsByItselfLeavesNothingBehindEither() async throws {
        let app = model(routes: [capabilitiesRoute(approved: true)] + authRoutes, store: try await storedSession())
        await app.start()
        await settle(app, to: .ready)
        let cache = try await leaveTraces(of: app)

        // The auth service ends the session on its own when the server refuses a refresh; the app is only told.
        await app.auth?.signOut()
        await settle(app, to: .signedOut)
        await assertTracesGone(of: app, in: cache)
    }

    func testASessionThatEndedWhileTheAppWasClosedIsCleanedUpAtTheNextLaunch() async throws {
        SharedConfig.defaults.set("u9", forKey: PrefKey.sessionUser)
        OutboxStore.add(OutboxItem(content: "what the last account left"))
        let app = model(routes: [capabilitiesRoute(approved: true)] + authRoutes)
        await app.start()
        await settle(app, to: .signedOut)
        XCTAssertEqual(OutboxStore.count, 0)
        XCTAssertNil(SharedConfig.defaults.string(forKey: PrefKey.sessionUser))
    }

    func testLaunchingWithNobodySignedInKeepsWhatIsWaiting() async {
        OutboxStore.add(OutboxItem(content: "shared before anyone signed in"))
        let app = model(routes: [capabilitiesRoute(approved: true)] + authRoutes)
        await app.start()
        await settle(app, to: .signedOut)
        XCTAssertEqual(OutboxStore.load().map(\.content), ["shared before anyone signed in"])
    }

    func testALinkReceivedBeforeSignInSurvivesTheCleanupAndIsFollowedAfter() async throws {
        SharedConfig.defaults.set("u9", forKey: PrefKey.sessionUser)
        let token = #"{"access_token":"A2","refresh_token":"R2","expires_in":3600,"user":{"id":"u1","email":"sam@example.com"}}"#
        let app = model(routes: [capabilitiesRoute(approved: true), .json(.post, "/auth/v1/token", token)] + authRoutes)
        app.handle(url: URL(string: "hypervault://tab/memory")!)
        await app.start()
        await settle(app, to: .signedOut)

        try await app.auth?.signIn(withIDToken: "apple-token", provider: "apple", nonce: nil)
        await settle(app, to: .ready)
        XCTAssertEqual(app.router.tab, .memory)
    }

    // MARK: Switching server

    /// What each host answers to capabilities. `{CAPS}` stands for a real answer, with the signed-in person's `user` block
    /// when the request carries a token.
    private func hostAnswers(_ answers: [String: String]) -> MockRoute {
        let anonymous = String(format: capabilitiesJSON, "")
        let signedIn = String(format: capabilitiesJSON, #","user":{"id":"u1","email":"sam@example.com","via":"bearer"}"#)
        return MockRoute(.get, "/api/capabilities") { request in
            guard let body = answers[request.url?.host ?? ""] else { return HTTPResponse(status: 404, data: Data(#"{"error":"Not found."}"#.utf8)) }
            let real = request.value(forHTTPHeaderField: "Authorization") != nil ? signedIn : anonymous
            return HTTPResponse(status: 200, data: Data(body.replacingOccurrences(of: "{CAPS}", with: real).utf8))
        }
    }

    private func signedInOnOneServer(transport: HTTPTransport) async throws -> AppModel {
        let app = model(transport: transport, store: try await storedSession())
        await app.start()
        await settle(app, to: .ready)
        return app
    }

    func testAnAddressThatCannotBeReachedChangesNothing() async throws {
        let mock = MockTransport(routes: [hostAnswers(["hv.test": "{CAPS}"])] + authRoutes)
        let app = try await signedInOnOneServer(transport: DeadHosts(base: mock, dead: ["typo.test"]))
        OutboxStore.add(OutboxItem(content: "still waiting"))
        let before = SharedConfig.server

        do {
            try await app.changeServer(to: ServerConfig(baseURL: URL(string: "https://typo.test")!))
            XCTFail("the switch should have been refused")
        } catch {
            XCTAssertEqual(error as? ServerSwitchError, .unreachable(host: "typo.test"))
        }
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.env?.user.id, "u1")
        XCTAssertEqual(app.server.baseURL.host, "hv.test")
        XCTAssertEqual(SharedConfig.server, before)
        XCTAssertEqual(OutboxStore.count, 1)
        let logouts = await mock.requests(matching: "/auth/v1/logout")
        XCTAssertTrue(logouts.isEmpty, "the person must stay signed in")
    }

    func testAnAddressThatIsNotHyperVaultChangesNothing() async throws {
        let mock = MockTransport(routes: [
            hostAnswers(["hv.test": "{CAPS}", "bare.test": "{}", "blog.test": "<html>hello</html>"]),
        ] + authRoutes)
        let app = try await signedInOnOneServer(transport: mock)

        do {
            try await app.changeServer(to: ServerConfig(baseURL: URL(string: "https://bare.test")!))
            XCTFail("a server that names no sign-in project should be refused")
        } catch {
            XCTAssertEqual(error as? ServerSwitchError, .notSetUp(host: "bare.test"))
        }
        do {
            try await app.changeServer(to: ServerConfig(baseURL: URL(string: "https://blog.test")!))
            XCTFail("a site that is not HyperVault should be refused")
        } catch {
            XCTAssertEqual(error as? ServerSwitchError, .notHyperVault(host: "blog.test"))
        }
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.server.baseURL.host, "hv.test")
        let logouts = await mock.requests(matching: "/auth/v1/logout")
        XCTAssertTrue(logouts.isEmpty)
    }

    func testSwitchingToAHyperVaultServerSignsOutAndStartsOverThere() async throws {
        let mock = MockTransport(routes: [hostAnswers(["hv.test": "{CAPS}", "other.test": "{CAPS}"])] + authRoutes)
        let app = try await signedInOnOneServer(transport: mock)
        let cache = try await leaveTraces(of: app)
        let other = ServerConfig(baseURL: URL(string: "https://other.test")!)

        try await app.changeServer(to: other)
        await settle(app, to: .signedOut)

        XCTAssertEqual(app.server, other)
        XCTAssertEqual(SharedConfig.server, other)
        XCTAssertNil(app.env)
        await assertTracesGone(of: app, in: cache)
        let logouts = await mock.requests(matching: "/auth/v1/logout")
        XCTAssertEqual(logouts.count, 1)
    }

    func testAServerThatStoppedAnsweringCanBeLeftForTheDefault() async {
        let fallback = SharedConfig.defaultServer
        let fallbackHost = fallback.baseURL.host ?? ""
        let mock = MockTransport(routes: [hostAnswers([fallbackHost: "{CAPS}"])] + authRoutes)
        let gone = ServerConfig(baseURL: URL(string: "https://gone.test")!)
        let app = model(transport: DeadHosts(base: mock, dead: ["gone.test"]), server: gone)

        await app.start()
        guard case .unreachable = app.phase else { return XCTFail("expected unreachable, got \(app.phase)") }
        XCTAssertFalse(app.isOnDefaultServer)

        await app.resetServer()
        await settle(app, to: .signedOut)
        XCTAssertEqual(app.server, fallback)
        XCTAssertEqual(SharedConfig.server, fallback)
        XCTAssertTrue(app.isOnDefaultServer)
    }

}

/// A flag the mock routes can flip from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// A network where some hosts do not answer at all.
private struct DeadHosts: HTTPTransport {
    let base: MockTransport
    let dead: Set<String>

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let host = request.url?.host, dead.contains(host) { throw URLError(.badServerResponse) }
        return try await base.send(request)
    }
}
