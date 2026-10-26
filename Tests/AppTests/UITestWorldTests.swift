import HyperVaultKit
import XCTest
@testable import HyperVault

/// The canned server behind the UI-test mode (App/Core/UITestWorld.swift) answers in the shapes the app reads, through
/// the same endpoints the app calls. If a route drifts from what a screen decodes, this fails here, in seconds, instead
/// of as a journey that never finds its first screen.
final class UITestWorldTests: XCTestCase {
    private func client(_ scenario: UITestScenario) -> HVClient {
        let transport = MockTransport(routes: UITestWorld.routes(for: scenario))
        return HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private var supabase: SupabaseConfig {
        SupabaseConfig(url: UITestWorld.supabaseURL, anonKey: UITestWorld.anonKey)
    }

    func testCapabilitiesNameTheProjectAndOnlyALetInPersonHasAUser() async throws {
        let signedIn = try await client(.signedIn).send(.capabilities)
        XCTAssertEqual(signedIn.supabase?.url, UITestWorld.supabaseURL)
        XCTAssertEqual(signedIn.user?.id, UITestWorld.user.id)

        let signedOut = try await client(.signedOut).send(.capabilities)
        XCTAssertNotNil(signedOut.supabase)
        XCTAssertNil(signedOut.user)
    }

    func testTheAuthServerOffersGoogleAndEmailButNotApple() async throws {
        let transport = MockTransport(routes: UITestWorld.routes(for: .signedOut))
        let auth = AuthService(config: supabase, transport: transport, store: InMemorySecureStore())
        let providers = await auth.providers()
        XCTAssertEqual(providers, AuthProviders(google: true, apple: false, email: true, signupDisabled: false))

        try await auth.requestEmailCode(email: "sam@example.com")
        do {
            _ = try await auth.verifyEmailCode(email: "sam@example.com", code: "000000")
            XCTFail("The canned server turns every code down.")
        } catch let error as AuthError {
            XCTAssertEqual(error.errorDescription, "That code did not work, or it has expired. Check it, or ask for a new one.")
        }
    }

    func testTheSeededSessionRestores() async throws {
        let store = InMemorySecureStore()
        await store.set(try HVCoding.encoder(.verbatim).encode(UITestWorld.session()), for: "hypervault.session")
        let transport = MockTransport(routes: UITestWorld.routes(for: .signedIn))
        let auth = AuthService(config: supabase, transport: transport, store: store)
        let state = await auth.restore()
        XCTAssertEqual(state, .signedIn(UITestWorld.user))
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "uitest-access")
    }

    func testYoursNarrowsByFilterAndSearch() async throws {
        let api = client(.signedIn)
        let all = try await api.send(.yours(filter: .all, limit: 50))
        XCTAssertEqual(all.results.count, 7)
        XCTAssertEqual(all.recent.map(\.id), ["a1", "m1", "k1"])
        let memories = try await api.send(.yours(filter: .memory, limit: 50))
        XCTAssertEqual(memories.results.map(\.id), ["m1", "m2", "m3"])
        let files = try await api.send(.yours(filter: .file, limit: 50))
        XCTAssertEqual(files.results.map(\.id), ["a1", "g1", "a2"])
        let keys = try await api.send(.yours(filter: .key, limit: 50))
        XCTAssertEqual(keys.results.map(\.id), ["k1"])
        let bakery = try await api.send(.yours(filter: .all, query: "bakery", limit: 50))
        XCTAssertEqual(bakery.results.map(\.id), ["a1"])

        let empty = try await client(.signedInEmpty).send(.yours(filter: .all, limit: 50))
        XCTAssertTrue(empty.results.isEmpty)
        XCTAssertTrue(empty.recent.isEmpty)
    }

    func testCardsKeepsAndChatAnswer() async throws {
        let api = client(.signedIn)
        let memory = try await api.send(.card(kind: .memory, id: "m1"))
        XCTAssertEqual(memory.name, "Trip to Lisbon: ferry and passports")
        XCTAssertEqual(memory.digest, "Book the Friday ferry across the Tagus.")

        let first = try await api.send(.keep(content: UITestWorld.pasteText))
        XCTAssertEqual(first.title, "Lisbon trip checklist")
        XCTAssertEqual(first.url, "https://uitest.hypervault.invalid/a/lisbon-trip-checklist-k1")
        XCTAssertTrue(first.isPrivate)
        let second = try await api.send(.keep(content: "Another thing"))
        XCTAssertNotEqual(first.slug, second.slug)

        let backends = try await api.send(.canvasBackends)
        XCTAssertEqual(backends.map(\.id), ["b1"])
        let turn = try await api.send(.canvasChat(backendId: "b1", message: "Buy milk", conversationId: nil, pulled: []))
        XCTAssertEqual(turn.content, "Noted: Buy milk")

        let none = try await client(.signedInEmpty).send(.canvasBackends)
        XCTAssertTrue(none.isEmpty)
    }

    func testPagesAndTheirSourceAreThere() async throws {
        let transport = MockTransport(routes: UITestWorld.routes(for: .signedIn))
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let list = try await api.send(.artifacts)
        XCTAssertEqual(list.items.map(\.slug), ["bakery-landing-page-x1", "trip-to-lisbon-q7", "portfolio-site"])
        let content = try await api.send(.artifactContent(slug: "bakery-landing-page-x1"))
        XCTAssertTrue(content.mutable)

        let loader = ArtifactPageLoader(baseURL: UITestWorld.appURL, tokens: StaticTokenProvider(), transport: transport)
        let page = await loader.load(slug: "bakery-landing-page-x1")
        guard case .html(let html, _) = page else { return XCTFail("Expected markup, got \(page)") }
        XCTAssertTrue(html.contains("Fresh bread daily"))
    }

    func testTheWaitlistOpensOnlyForTheRightCode() async throws {
        let transport = MockTransport(routes: UITestWorld.routes(for: .waitlisted))
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let waiting = try await api.send(.capabilities)
        XCTAssertNil(waiting.user)
        do {
            _ = try await api.send(.yours(filter: .all, limit: 1))
            XCTFail("The gate should refuse until the code is redeemed.")
        } catch let error as HVError {
            XCTAssertTrue(error.isWaitlisted)
        }

        let redeemer = InviteRedeemer(config: supabase, transport: transport, tokens: StaticTokenProvider())
        let refused = try await redeemer.redeem("hv-nope-nope")
        XCTAssertEqual(refused, .invalid)
        let stillWaiting = try await api.send(.capabilities)
        XCTAssertNil(stillWaiting.user)

        let accepted = try await redeemer.redeem(" hv-open-door ")
        XCTAssertEqual(accepted, .ok)
        let letIn = try await api.send(.capabilities)
        XCTAssertEqual(letIn.user?.id, UITestWorld.user.id)
        let yours = try await api.send(.yours(filter: .all, limit: 1))
        XCTAssertFalse(yours.results.isEmpty)
    }

    func testThePasteIsLongEnoughToWaitAboveTheField() {
        XCTAssertTrue(PasteStaging.shouldStage(UITestWorld.pasteText))
    }

    func testOnlyTheCannedHostsAnswerAndEveryOtherIsRefused() async throws {
        UITestURLProtocol.transport = MockTransport(routes: UITestWorld.routes(for: .signedIn))
        defer { UITestURLProtocol.transport = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let (page, response) = try await session.data(from: UITestWorld.appURL.appendingPathComponent("a/bakery-landing-page-x1"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Fresh bread daily"))

        let (rows, _) = try await session.data(from: UITestWorld.supabaseURL.appendingPathComponent("rest/v1/profiles"))
        XCTAssertEqual(String(decoding: rows, as: UTF8.self), "[]")

        do {
            _ = try await session.data(from: URL(string: "https://hypervault.store/api/capabilities")!)
            XCTFail("A real server must be out of reach in UI-test mode.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }
}
