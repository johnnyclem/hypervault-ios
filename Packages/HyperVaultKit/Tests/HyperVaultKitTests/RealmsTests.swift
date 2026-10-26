import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Realms: app/api/claim-domain/route.ts, lib/domains.ts and the reads app/vault/account/page.tsx does.
final class RealmsTests: XCTestCase {
    func api(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    func rest(_ transport: MockTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    // MARK: Names

    func testValidateIsLibDomainsValidateSubdomain() throws {
        func error(_ name: String) -> String? {
            if case .failure(let e) = RealmRules.validate(name) { return e.message }
            return nil
        }
        XCTAssertEqual(try RealmRules.validate("  Nova ").get(), "nova")
        XCTAssertEqual(try RealmRules.validate("a-b-9").get(), "a-b-9")
        XCTAssertEqual(error("a"), "Pick at least 2 characters.")
        XCTAssertEqual(error(""), "Pick at least 2 characters.")
        XCTAssertEqual(error(String(repeating: "a", count: 64)), "Subdomains max out at 63 characters.")
        XCTAssertNil(error(String(repeating: "a", count: 63)))
        for bad in ["-ab", "ab-", "a_b", "a b", "a.b", "né"] {
            XCTAssertEqual(error(bad), "Use only lowercase letters, numbers, and hyphens (no leading/trailing hyphen).", bad)
        }
        XCTAssertEqual(error("admin"), "\"admin\" is reserved.")
        XCTAssertEqual(error("WWW"), "\"www\" is reserved.")
        XCTAssertEqual(error("www2"), "\"www2\" is reserved.", "everything starting with www is")
        XCTAssertEqual(error("vault"), "\"vault\" is reserved.")
    }

    func testThePortfolioShowsTheFeaturedAddressFirstThenTheOpenOnes() {
        let domains = [
            Capabilities.PortfolioDomain(domain: "later.example", available: false),
            Capabilities.PortfolioDomain(domain: "cleon.wiki", tagline: "wiki"),
            Capabilities.PortfolioDomain(domain: "vault.cool", tagline: "original", featured: true),
            Capabilities.PortfolioDomain(domain: "agentvault.cloud"),
        ]
        XCTAssertEqual(RealmRules.ordered(domains).map(\.domain), ["vault.cool", "cleon.wiki", "agentvault.cloud", "later.example"])
        XCTAssertTrue(RealmRules.ordered([]).isEmpty)
    }

    // MARK: Wire

    func testAvailability() async throws {
        let transport = MockTransport(routes: [MockRoute(.get, "/api/claim-domain") { request in
            let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
            let body = name == "nova" ? #"{"available":true}"# : #"{"available":false,"reason":"\#(name ?? "").vault.cool is already taken."}"#
            return HTTPResponse(status: 200, data: Data(body.utf8))
        }])
        let hv = api(transport)
        let free = try await hv.send(.claimAvailability(name: "nova", base: "vault.cool"))
        XCTAssertTrue(free.available)
        let taken = try await hv.send(.claimAvailability(name: "sam", base: "vault.cool"))
        XCTAssertFalse(taken.available)
        XCTAssertEqual(taken.reason, "sam.vault.cool is already taken.")

        let requests = await transport.requests(matching: "/api/claim-domain")
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.url?.query, "name=nova&base=vault.cool")
        XCTAssertNil(first.value(forHTTPHeaderField: "Authorization"), "availability is public")
    }

    func testClaim() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/claim-domain", #"{"domain":"nova.vault.cool","url":"https://nova.vault.cool","claimed":1,"max_subdomains":10,"message":"nova.vault.cool is yours, effective immediately."}"#)])
        let claimed = try await api(transport).send(.claimRealm(name: "nova", base: "vault.cool"))
        XCTAssertEqual(claimed.domain, "nova.vault.cool")
        XCTAssertEqual(claimed.claimed, 1)
        XCTAssertEqual(claimed.maxSubdomains, 10)
        let requests = await transport.requests(matching: "/api/claim-domain")
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body, ["desired_name": "nova", "base_domain": "vault.cool"])
    }

    func testClaimRefusalsKeepTheServersSentence() async {
        let cases: [(Int, String)] = [
            (409, "nova.vault.cool is already taken — so close! Try a variation."),
            (403, "Pro accounts can hold up to 10 subdomains, and you've claimed them all. Release one from your vault to make room."),
            (400, "\"example.org\" isn't claimable yet. Available today: vault.cool."),
        ]
        for (status, message) in cases {
            let transport = MockTransport(routes: [.failure(.post, "/api/claim-domain", status: status, message: message)])
            do {
                _ = try await api(transport).send(.claimRealm(name: "nova", base: "vault.cool"))
                XCTFail("expected a refusal")
            } catch let error as HVError {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.userMessage, message)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testThemeAndHomeAreChangedIndependently() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/claim-domain", #"{"domain":"nova.vault.cool","theme":"glassmorphism","message":"nova.vault.cool now wears glassmorphism. ✨"}"#)
        ])
        let hv = api(transport)
        let themed = try await hv.send(.setRealmTheme(subdomain: "nova", base: "vault.cool", theme: "glassmorphism"))
        XCTAssertEqual(themed.theme, "glassmorphism")
        _ = try await hv.send(.setRealmTheme(subdomain: "nova", base: "vault.cool", theme: nil))
        _ = try await hv.send(.setRealmHome(subdomain: "nova", base: "vault.cool", artifactSlug: "my-page"))
        _ = try await hv.send(.setRealmHome(subdomain: "nova", base: "vault.cool", artifactSlug: nil))

        let sent = await transport.requests(matching: "/api/claim-domain")
        func body(_ i: Int) throws -> JSONValue { try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[i].httpBody)) }
        XCTAssertEqual(try body(0), ["subdomain": "nova", "base_domain": "vault.cool", "theme": "glassmorphism"])
        XCTAssertEqual(try body(1), ["subdomain": "nova", "base_domain": "vault.cool", "theme": nil], "null goes back to the domain default")
        XCTAssertEqual(try body(2), ["subdomain": "nova", "base_domain": "vault.cool", "default_artifact": "my-page"], "a home change leaves the theme out so the theme is left alone")
        XCTAssertEqual(try body(3), ["subdomain": "nova", "base_domain": "vault.cool", "default_artifact": nil])
    }

    func testAHomePageThatIsPrivateComesBackWithAWarning() throws {
        let json = #"{"domain":"nova.vault.cool","theme":null,"default_artifact":"secret","url":"https://nova.vault.cool","warning":"\"Secret\" is private, so visitors to nova.vault.cool will see the lock page instead of the artifact. Make it public to serve it here.","message":"x"}"#
        let update = try HVCoding.decoder().decode(RealmUpdate.self, from: Data(json.utf8))
        XCTAssertEqual(update.defaultArtifact, "secret")
        XCTAssertTrue(update.warning?.contains("lock page") ?? false)
    }

    // MARK: Reads

    func testClaimsAreReadOldestFirstForThisPerson() async throws {
        let json = #"[{"id":"c1","subdomain":"nova","base_domain":"vault.cool","theme":"glassmorphism","default_artifact_slug":"my-page","claimed_at":"2026-10-01T10:00:00Z"},{"id":"c2","subdomain":"nova","base_domain":"cleon.wiki","theme":null,"default_artifact_slug":null,"claimed_at":"2026-10-02T10:00:00+00:00"}]"#
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/domain_claims", json)])
        let claims = try await RealmDirectory.claims(rest: rest(transport), userID: "user-1", legacySubdomain: nil)
        XCTAssertEqual(claims.map(\.host), ["nova.vault.cool", "nova.cleon.wiki"])
        XCTAssertEqual(claims[0].theme, "glassmorphism")
        XCTAssertEqual(claims[0].defaultArtifactSlug, "my-page")
        XCTAssertEqual(claims[0].url?.absoluteString, "https://nova.vault.cool")
        let requests = await transport.requests(matching: "/rest/v1/domain_claims")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["user_id"], "eq.user-1")
        XCTAssertEqual(items["order"], "claimed_at.asc")
    }

    func testClaimsFallBackWithoutTheHomeColumn() async throws {
        let calls = CallCounter()
        let transport = MockTransport(routes: [MockRoute(.get, "/rest/v1/domain_claims") { request in
            let select = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "select" }?.value ?? ""
            calls.increment()
            if select.contains("default_artifact_slug") {
                return HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column domain_claims.default_artifact_slug does not exist"}"#.utf8))
            }
            return HTTPResponse(status: 200, data: Data(#"[{"id":"c1","subdomain":"nova","base_domain":"vault.cool","theme":null,"claimed_at":"2026-10-01T10:00:00Z"}]"#.utf8))
        }])
        let claims = try await RealmDirectory.claims(rest: rest(transport), userID: "user-1", legacySubdomain: nil)
        XCTAssertEqual(claims.count, 1)
        XCTAssertNil(claims[0].defaultArtifactSlug)
        XCTAssertEqual(calls.value, 2)
    }

    func testAProfileFromBeforeTheClaimsTableStillHasItsRealm() async throws {
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/domain_claims", "[]")])
        let claims = try await RealmDirectory.claims(rest: rest(transport), userID: "user-1", legacySubdomain: "oldname")
        XCTAssertEqual(claims.map(\.host), ["oldname.vault.cool"])
        let none = try await RealmDirectory.claims(rest: rest(transport), userID: "user-1", legacySubdomain: nil)
        XCTAssertTrue(none.isEmpty)
    }

    func testSnapshotReadsPlanClaimsAndHomeOptions() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/profiles", #"[{"plan":"pro","vanity_subdomain":"nova"}]"#),
            .json(.get, "/rest/v1/domain_claims", #"[{"id":"c1","subdomain":"nova","base_domain":"vault.cool","theme":null,"default_artifact_slug":null,"claimed_at":"2026-10-01T10:00:00Z"}]"#),
            .json(.get, "/rest/v1/artifacts", #"[{"slug":"my-page","title":"My page","type":"html","visibility":"public"},{"slug":"locked","title":"","type":"html","visibility":"private"},{"slug":"old","title":"Old","type":"html"}]"#),
        ])
        let snapshot = try await RealmDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertTrue(snapshot.isPro)
        XCTAssertEqual(snapshot.claims.count, 1)
        XCTAssertEqual(snapshot.homeOptions.map(\.title), ["My page", "Untitled artifact", "Old"])
        XCTAssertEqual(snapshot.homeOptions.map(\.isGated), [false, true, false])

        let requests = await transport.requests(matching: "/rest/v1/artifacts")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "neq.group", "a group cannot be a home page")
        XCTAssertEqual(items["limit"], "30")
    }

    func testAFreePersonIsNotPro() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/profiles", #"[{"plan":"free","vanity_subdomain":null}]"#),
            .json(.get, "/rest/v1/domain_claims", "[]"),
            .json(.get, "/rest/v1/artifacts", "[]"),
        ])
        let snapshot = try await RealmDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertFalse(snapshot.isPro)
        XCTAssertTrue(snapshot.claims.isEmpty)
    }

    func testThePlanWordsAreTheUpgradePages() {
        XCTAssertEqual(RealmPlanCopy.proFeatures.count, 6)
        XCTAssertEqual(RealmPlanCopy.proFeatures[1], "Up to 10 legendary addresses (you.vault.cool)")
        XCTAssertEqual(RealmPlanCopy.freeFeatures.count, 4)
        XCTAssertEqual(RealmPlanCopy.proPrice, "$8 / month")
    }
}
