import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures follow app/api/shares/route.ts, app/api/artifacts/[slug]/passwords/**, app/api/connections/route.ts.
final class ArtifactAccessTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), sleep: { _ in })
    }

    func firstRequest(_ transport: MockTransport) async throws -> URLRequest {
        let requests = await transport.requests
        return try XCTUnwrap(requests.first)
    }

    // MARK: Shares

    let sharesJSON = #"""
    {"shares":[
      {"id":"s1","email":"maya@example.com","display_name":"Maya","role":"edit","created_at":"2026-10-01T00:00:00.000Z"},
      {"id":"s2","email":null,"display_name":"Jon","role":"use","created_at":"2026-10-02T00:00:00.000Z"},
      {"id":"s3","email":null,"display_name":null,"role":"owner-of-the-universe","created_at":"2026-10-03T00:00:00.000Z"}
     ],"roles":["view","use","edit","superuser"],"roles_enforced":true}
    """#

    func testShareListReadsRolesClosed() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/shares", sharesJSON)])
        let list = try await client(transport).send(.artifactShares(slug: "p-1"))
        XCTAssertEqual(list.roles, [.view, .use, .edit], "a word that is not a role is dropped")
        XCTAssertEqual(list.people.map(\.name), ["maya@example.com", "Jon", "Someone"])
        XCTAssertEqual(list.people[2].role, .view, "a role this build does not know is a view")
        XCTAssertEqual(list.offeredRoles, [.view, .use, .edit])
        XCTAssertEqual(list.effectiveRole(of: list.people[0]), .edit)
        let query = await transport.requests.first?.url?.query
        XCTAssertEqual(query, "artifact=p-1")
    }

    func testRolesThatDoNothingAreNeitherOfferedNorPromised() throws {
        let json = #"{"shares":[{"id":"s1","email":"a@b.co","role":"edit"}],"roles":["view","use","edit"],"roles_enforced":false}"#
        let list = try HVCoding.decoder().decode(ArtifactShareList.self, from: Data(json.utf8))
        XCTAssertEqual(list.offeredRoles, [.view])
        XCTAssertEqual(list.effectiveRole(of: list.people[0]), .view, "with roles off every share is a view")

        let frozen = try HVCoding.decoder().decode(ArtifactShareList.self, from: Data(#"{"shares":[{"id":"s1","email":"a@b.co","role":"edit"}],"roles":["view"],"roles_enforced":true}"#.utf8))
        XCTAssertEqual(frozen.effectiveRole(of: frozen.people[0]), .view, "a role the page can no longer have reads as view")

        let older = try HVCoding.decoder().decode(ArtifactShareList.self, from: Data(#"{"shares":[],"roles":["view"]}"#.utf8))
        XCTAssertFalse(older.enforced, "an answer that does not say roles are on means off")
    }

    func testAddingAPersonNamesTheRole() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/shares", #"{"shared_with":{"email":"maya@example.com","display_name":"Maya"},"role":"use","message":"Invited Maya with the “use” role — “P” now opens for their account too."}"#),
        ])
        let added = try await client(transport).send(.shareArtifact(slug: "p-1", email: "  Maya@Example.com ", role: .use))
        XCTAssertEqual(added.role, .use)
        XCTAssertTrue(added.message.contains("Invited Maya"))
        let sent = try await firstRequest(transport)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(body["artifact"], "p-1")
        XCTAssertEqual(body["email"], "Maya@Example.com")
        XCTAssertEqual(body["role"], "use")
        XCTAssertNil(body["public"], "a share is for people you add")
    }

    func testShareRefusalsAreTheRoutesWords() async {
        let transport = MockTransport(routes: [
            .failure(.post, "/api/shares", status: 404, message: "No HyperVault account for x@y.co yet \u{2014} they'll need to sign up (free) before you can invite them."),
            .failure(.get, "/api/shares", status: 404, message: "No artifact matching \"p-1\" in your vault."),
        ])
        do {
            _ = try await client(transport).send(.shareArtifact(slug: "p-1", email: "x@y.co", role: .view))
            XCTFail("expected 404")
        } catch {
            XCTAssertTrue((error as? HVError)?.userMessage.hasPrefix("No HyperVault account") == true)
        }
        do {
            _ = try await client(transport).send(.artifactShares(slug: "p-1"))
            XCTFail("expected 404")
        } catch {
            XCTAssertTrue((error as? HVError)?.isNotFound == true)
        }
    }

    func testEndingAShareNamesTheShare() async throws {
        let transport = MockTransport(routes: [.json(.delete, "/api/shares", #"{"message":"Access removed."}"#)])
        let result = try await client(transport).send(.endShare(id: "s1"))
        XCTAssertEqual(result.message, "Access removed.")
        let sent = try await firstRequest(transport)
        XCTAssertEqual(String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self), #"{"share_id":"s1"}"#)
    }

    func testEmailCheckMatchesTheRoutes() {
        XCTAssertTrue(ArtifactShareEmail.isValid("maya@example.com"))
        XCTAssertTrue(ArtifactShareEmail.isValid(" maya+tag@sub.example.co "))
        XCTAssertFalse(ArtifactShareEmail.isValid("maya"))
        XCTAssertFalse(ArtifactShareEmail.isValid("maya@example"))
        XCTAssertFalse(ArtifactShareEmail.isValid("@example.com"))
        XCTAssertFalse(ArtifactShareEmail.isValid("ma ya@example.com"))
        XCTAssertFalse(ArtifactShareEmail.isValid("maya@example."))
        XCTAssertFalse(ArtifactShareEmail.isValid("a@b@c.com"))
    }

    func testRoleWordsAreThePRDs() {
        XCTAssertEqual(ArtifactShareRole.allCases.map(\.title), ["View", "Use", "Edit"])
        XCTAssertEqual(ArtifactShareRole.view.line, "They can open it.")
        XCTAssertEqual(ArtifactShareRole.use.line, "They can add and change the contents, not the sharing.")
        XCTAssertEqual(ArtifactShareRole.edit.line, "They can change how it works, including who is on it.")
    }

    // MARK: Passwords

    func testPasswordsListWithRecentVisits() async throws {
        let json = #"""
        {"passwords":[
          {"id":"p1","label":"Team","max_uses":5,"use_count":2,"disabled":false,"created_at":"2026-10-01T00:00:00.000Z"},
          {"id":"p2","label":null,"max_uses":null,"use_count":1,"disabled":true,"created_at":"2026-10-02T00:00:00.000Z"},
          {"id":"p3","label":"Full","max_uses":1,"use_count":1,"disabled":false,"created_at":"2026-10-03T00:00:00.000Z"}
        ],"recentVisits":[{"id":"v1","artifact_password_id":"p1","label":"Team","created_at":"2026-10-04T00:00:00.000Z"}]}
        """#
        let transport = MockTransport(routes: [.json(.get, "/api/artifacts/p-1/passwords", json)])
        let list = try await client(transport).send(.artifactPasswords(slug: "p-1"))
        XCTAssertEqual(list.passwords.map(\.displayLabel), ["Team", "Untitled", "Full"])
        XCTAssertEqual(list.passwords[0].usageLine, "2 visits / 5 max")
        XCTAssertEqual(list.passwords[1].usageLine, "1 visit")
        XCTAssertTrue(list.passwords[1].disabled)
        XCTAssertTrue(list.passwords[2].isUsedUp)
        XCTAssertEqual(list.recentVisits.first?.label, "Team")
    }

    func testMintingReturnsThePasswordOnce() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/artifacts/p-1/passwords", #"{"password":{"id":"p9","label":"Guests","max_uses":3,"use_count":0,"disabled":false,"created_at":"2026-10-05T00:00:00.000Z"},"plaintext":"swift-otter-42","message":"Copy this password now — it won't be shown again."}"#),
        ])
        let minted = try await client(transport).send(.mintArtifactPassword(slug: "p-1", password: nil, label: "Guests", maxUses: 3))
        XCTAssertEqual(minted.plaintext, "swift-otter-42")
        XCTAssertEqual(minted.password.maxUses, 3)
        let sent = try await firstRequest(transport)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["label"] as? String, "Guests")
        XCTAssertEqual(body["maxUses"] as? Int, 3, "the route reads maxUses in camel case")
        XCTAssertNil(body["password"], "a blank password has the server generate one")
    }

    func testDeactivatingAndDeletingAPassword() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/artifacts/p-1/passwords/p1", #"{"password":{"id":"p1","label":"Team","max_uses":5,"use_count":2,"disabled":true,"created_at":"2026-10-01T00:00:00.000Z"}}"#),
            .json(.delete, "/api/artifacts/p-1/passwords/p1", #"{"ok":true}"#),
        ])
        let api = client(transport)
        let updated = try await api.send(.setArtifactPasswordDisabled(slug: "p-1", id: "p1", disabled: true))
        XCTAssertTrue(updated.disabled)
        _ = try await api.send(.deleteArtifactPassword(slug: "p-1", id: "p1"))
    }

    func testThePasswordLimitIsTheRoutes() async {
        let transport = MockTransport(routes: [
            .failure(.post, "/api/artifacts/p-1/passwords", status: 400, message: "An artifact can have at most 20 passwords \u{2014} delete one first."),
        ])
        do {
            _ = try await client(transport).send(.mintArtifactPassword(slug: "p-1"))
            XCTFail("expected 400")
        } catch {
            XCTAssertTrue((error as? HVError)?.userMessage.contains("at most \(ArtifactPasswordRules.maxPasswords)") == true)
        }
    }

    // MARK: Connections

    func testEdgesCountAndFilter() async throws {
        let json = #"""
        {"connections":[
          {"id":"e1","a_id":"A","b_id":"B","kind":"manual","created_at":"2026-10-01T00:00:00.000Z"},
          {"id":"e2","a_id":"A","b_id":"C","kind":"auto","created_at":"2026-10-01T00:00:00.000Z"},
          {"id":"e3","a_id":"C","b_id":"D","kind":"auto","created_at":"2026-10-01T00:00:00.000Z"}],
         "memory_links":[{"id":"m1","a_id":"x","b_id":"y","kind":"auto","created_at":"2026-10-01T00:00:00.000Z"}],
         "memory_artifact_links":[{"id":"b1","memory_id":"M1","artifact_id":"A","kind":"manual","created_at":"2026-10-01T00:00:00.000Z"}]}
        """#
        let transport = MockTransport(routes: [.json(.get, "/api/connections", json)])
        let edges = try await client(transport).send(.artifactEdges)
        XCTAssertEqual(edges.counts, ["A": 2, "B": 1, "C": 2, "D": 1])
        XCTAssertEqual(edges.edges(touching: "A").map(\.id), ["e1", "e2"])
        XCTAssertEqual(edges.edges(touching: "A").compactMap { $0.other(from: "A") }, ["B", "C"])
        XCTAssertTrue(edges.connections[1].isAuto)
        XCTAssertEqual(edges.bridges(touching: "A").map(\.memoryId), ["M1"])
        XCTAssertEqual(edges.bridges(touching: "B").count, 0)
        XCTAssertNil(edges.connections[0].other(from: "Z"))
    }

    func testConnectAndDisconnect() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/connections", #"{"connected":["A","B"],"message":"Connected — check the graph view!"}"#),
            .json(.delete, "/api/connections", #"{"deleted":"e1"}"#),
        ])
        let api = client(transport)
        let done = try await api.send(.connectArtifact(source: "p-1", target: "B"))
        XCTAssertTrue(done.message.hasPrefix("Connected"))
        _ = try await api.send(.disconnect(edge: "e1"))
        let requests = await transport.requests
        XCTAssertEqual(String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self), #"{"source":"p-1","target":"B"}"#)
        XCTAssertEqual(String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self), #"{"id":"e1"}"#)
    }

    func testConnectingToYourselfIsTheRoutesSentence() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/connections", status: 400, message: "An item cannot connect to itself.")])
        do {
            _ = try await client(transport).send(.connectArtifact(source: "p-1", target: "p-1"))
            XCTFail("expected 400")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "An item cannot connect to itself.")
        }
    }
}
