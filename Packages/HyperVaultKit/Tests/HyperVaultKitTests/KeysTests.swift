import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Agent keys: app/api/keys/route.ts, lib/api-keys.ts, lib/agent-setup.ts, and the PostgREST read the
/// account page does on the server (app/vault/account/page.tsx).
final class KeysTests: XCTestCase {
    func api(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    func rest(_ transport: MockTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    static let rawKey = "hv_Zk3pQ9vL2mX8aRt5NwYb7CdEfGhJ1sUo"  // 35 characters

    // MARK: Mint

    func testMintDecodesTheOneTimeKeyAndItsChallenge() throws {
        // app/api/keys/route.ts POST
        let json = #"{"key":"\#(Self.rawKey)","prefix":"hv_Zk3pQ9vL","challenge":{"slug":"agent-setup-ab12","url":"https://hv.test/a/agent-setup-ab12"},"message":"Copy this key now — it is never shown again. Use it as the X-HyperVault-Key header."}"#
        let minted = try HVCoding.decoder().decode(NewAgentKey.self, from: Data(json.utf8))
        XCTAssertEqual(minted.key, Self.rawKey)
        XCTAssertEqual(minted.prefix, "hv_Zk3pQ9vL")
        XCTAssertEqual(minted.challenge?.slug, "agent-setup-ab12")
        XCTAssertTrue(AgentKeyRules.looksLikeKey(minted.key))
    }

    func testAMintedKeyNeverPrintsItself() throws {
        let json = #"{"key":"\#(Self.rawKey)","prefix":"hv_Zk3pQ9vL","challenge":null}"#
        let minted = try HVCoding.decoder().decode(NewAgentKey.self, from: Data(json.utf8))
        XCTAssertNil(minted.challenge)
        for text in [String(describing: minted), "\(minted)", String(reflecting: minted)] {
            XCTAssertFalse(text.contains(Self.rawKey), text)
            XCTAssertTrue(text.contains("hv_Zk3pQ9vL"))
        }
        var dumped = ""
        dump(minted, to: &dumped)
        XCTAssertFalse(dumped.contains(Self.rawKey), dumped)
    }

    func testMintBodyCarriesAnOptionalNameAndScopes() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/keys", #"{"key":"\#(Self.rawKey)","prefix":"hv_Zk3pQ9vL","challenge":null}"#)])
        let hv = api(transport)
        _ = try await hv.send(.createAgentKey())
        _ = try await hv.send(.createAgentKey(name: "  Cursor  ", canSendMail: true))
        _ = try await hv.send(.createAgentKey(name: "   "))

        let sent = await transport.requests(matching: "/api/keys")
        func body(_ request: URLRequest) throws -> JSONValue {
            try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(request.httpBody))
        }
        XCTAssertEqual(try body(sent[0]), [:])
        XCTAssertEqual(try body(sent[1]), ["name": "Cursor", "scopes": ["mail:read", "mail:send"]])
        XCTAssertEqual(try body(sent[2]), [:], "a blank name is no name")
        XCTAssertEqual(sent[1].httpMethod, "POST")
    }

    func testANameIsCutToSixtyCharacters() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/keys", #"{"key":"\#(Self.rawKey)","prefix":"hv_Zk3pQ9vL"}"#)])
        _ = try await api(transport).send(.createAgentKey(name: String(repeating: "n", count: 90)))
        let sent = await transport.requests(matching: "/api/keys")
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody))
        XCTAssertEqual(body["name"]?.string?.count, 60)
    }

    func testMintRefusals() async {
        for (status, message) in [(429, "Too many keys too fast — take a breath."), (400, "scopes must be a list of mail:read and mail:send.")] {
            let transport = MockTransport(routes: [.failure(.post, "/api/keys", status: status, message: message)])
            do {
                _ = try await api(transport).send(.createAgentKey())
                XCTFail("expected a refusal")
            } catch let error as HVError {
                XCTAssertEqual(error.userMessage, message)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testARouteThatOnlyTakesTheWebSessionAnswersInItsOwnWords() async {
        // Until the backend accepts the app's token on /api/keys, the route says so itself. A fresh token
        // that is still refused is the route's refusal, not a signed-out person.
        struct Rotating: TokenProvider {
            func accessToken() async throws -> String? { "t1" }
            func refreshAfterUnauthorized(rejected: String?) async throws -> String? { "t2" }
        }
        let transport = MockTransport(routes: [.failure(.post, "/api/keys", status: 401, message: "Sign in to create API keys.")])
        let hv = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: Rotating(), retry: .none)
        do {
            _ = try await hv.send(.createAgentKey())
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "Sign in to create API keys.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testKeyShape() {
        XCTAssertTrue(AgentKeyRules.looksLikeKey(Self.rawKey))
        XCTAssertFalse(AgentKeyRules.looksLikeKey("hv_short"))
        XCTAssertFalse(AgentKeyRules.looksLikeKey("xx_Zk3pQ9vL2mX8aRt5NwYb7CdEfGhJ1sUo"))
        XCTAssertFalse(AgentKeyRules.looksLikeKey("hv_Zk3pQ9vL2mX8aRt5NwYb7CdEfGhJ1sU!"))
    }

    // MARK: Revoke and change

    func testRevokeAndMailScope() async throws {
        let transport = MockTransport(routes: [
            .json(.delete, "/api/keys", #"{"revoked":"k1"}"#),
            .json(.patch, "/api/keys", #"{"key":{"id":"k1","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":false}}"#),
        ])
        let hv = api(transport)
        let revoked = try await hv.send(.revokeAgentKey(id: "k1"))
        XCTAssertEqual(revoked.revoked, "k1")
        let changed = try await hv.send(.setAgentKeyMail(id: "k1", canSendMail: true))
        XCTAssertEqual(changed.key.scopes, ["mail:read", "mail:send"])

        let sent = await transport.requests(matching: "/api/keys")
        XCTAssertEqual(sent.map { $0.httpMethod }, ["DELETE", "PATCH"])
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody)), ["id": "k1"])
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[1].httpBody)), ["id": "k1", "scopes": ["mail:read", "mail:send"]])
    }

    func testRevokingAnAlreadyRevokedKey() async {
        let transport = MockTransport(routes: [.failure(.delete, "/api/keys", status: 404, message: "No such key — it may already be revoked.")])
        do {
            _ = try await api(transport).send(.revokeAgentKey(id: "k1"))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.userMessage, "No such key — it may already be revoked.")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Rows

    static let keysJSON = """
    [{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"Paired: Claude Code","created_at":"2026-10-20T10:00:00.123456+00:00","last_used_at":"2026-10-25T08:00:00+00:00","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":false},
     {"id":"k2","key_prefix":"hv_Aa1Bb2Cc","name":"default","created_at":"2026-10-18T10:00:00Z","last_used_at":null,"scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false}]
    """

    func testRowsFromPostgREST() throws {
        let keys = try HVCoding.decoder().decode([AgentKey].self, from: Data(Self.keysJSON.utf8))
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].displayName, "Paired: Claude Code")
        XCTAssertTrue(keys[0].isPaired)
        XCTAssertTrue(keys[0].canSendMail)
        XCTAssertNotNil(keys[0].lastUsedAt)
        XCTAssertEqual(keys[0].prefixLabel, "hv_Zk3pQ9vL…")
        XCTAssertNil(keys[1].displayName, "the unnamed key is called default and shows no name")
        XCTAssertFalse(keys[1].canSendMail)
        XCTAssertTrue(keys[1].hasMailControls)
        XCTAssertNil(keys[1].lastUsedAt)
    }

    func testRowsFromADatabaseWithoutTheMailColumns() throws {
        let json = #"[{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"default","created_at":"2026-10-20T10:00:00Z","last_used_at":null}]"#
        let key = try HVCoding.decoder().decode([AgentKey].self, from: Data(json.utf8))[0]
        XCTAssertFalse(key.hasMailControls)
        XCTAssertFalse(key.canSendMail)
    }

    func testListReadsOnlyLiveKeysOfThisPersonNewestFirst() async throws {
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/api_keys", Self.keysJSON)])
        let keys = try await AgentKeyDirectory.keys(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(keys.map(\.id), ["k1", "k2"])

        let sentRequests = await transport.requests(matching: "/rest/v1/api_keys")
        let sent = try XCTUnwrap(sentRequests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer preview-token")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["user_id"], "eq.user-1")
        XCTAssertEqual(items["revoked"], "eq.false")
        XCTAssertEqual(items["order"], "created_at.desc")
        XCTAssertEqual(items["select"], "id,key_prefix,name,created_at,last_used_at,scopes,mail_claim_id,mail_pin_cleared")
    }

    func testListFallsBackWhenTheMailColumnsDoNotExist() async throws {
        // A database that predates migration 0047: PostgREST answers 400 naming the column.
        let calls = CallCounter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/rest/v1/api_keys") { request in
                let select = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "select" }?.value ?? ""
                calls.increment()
                if select.contains("scopes") {
                    return HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column api_keys.scopes does not exist"}"#.utf8))
                }
                return HTTPResponse(status: 200, data: Data(#"[{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"default","created_at":"2026-10-20T10:00:00Z","last_used_at":null}]"#.utf8))
            }
        ])
        let keys = try await AgentKeyDirectory.keys(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(keys.count, 1)
        XCTAssertFalse(keys[0].hasMailControls)
        XCTAssertEqual(calls.value, 2)
    }

    func testListSurfacesAnyOtherRefusal() async {
        let transport = MockTransport(routes: [.failure(.get, "/rest/v1/api_keys", status: 401, message: "JWT expired")])
        do {
            _ = try await AgentKeyDirectory.keys(rest: rest(transport), userID: "user-1")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertNotNil(error as? HVError)
        }
    }

    // MARK: Setup status

    static func challengePage(prefix: String, status: String, id: String = "art-1", slug: String = "agent-setup-1") -> AgentSetup.ChallengePage {
        AgentSetup.ChallengePage(
            id: id, slug: slug, tags: [AgentSetup.challengeTag, prefix],
            content: "<!doctype html><html><head><title>t</title></head>\n<body data-setup-status=\"\(status)\">\n<!-- On the <body> tag, change data-setup-status from incomplete to complete -->\n</body></html>"
        )
    }

    func testTheCompleteMarkerIsAnchoredToTheBodyTag() {
        XCTAssertTrue(AgentSetup.isComplete(content: "<html><body data-setup-status=\"complete\">"))
        XCTAssertTrue(AgentSetup.isComplete(content: "<BODY class='x' data-setup-status = 'complete'>"))
        XCTAssertFalse(AgentSetup.isComplete(content: "<body data-setup-status=\"incomplete\">"))
        // The instructions inside the page describe the edit and must never satisfy the check.
        XCTAssertFalse(AgentSetup.isComplete(content: "<body data-setup-status=\"incomplete\"><!-- set data-setup-status=\"complete\" -->"))
        XCTAssertFalse(AgentSetup.isComplete(content: "<div data-setup-status=\"complete\">"))
    }

    func testAKeyIsConnectedOnlyWhenItsOwnAgentWroteTheCompletedPage() throws {
        let k1 = AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL")
        let k2 = AgentKey(id: "k2", keyPrefix: "hv_Aa1Bb2Cc")
        let k3 = AgentKey(id: "k3", keyPrefix: "hv_Dd3Ee4Ff")
        let done = Self.challengePage(prefix: "hv_Zk3pQ9vL", status: "complete", id: "a1", slug: "s1")
        let pending = Self.challengePage(prefix: "hv_Aa1Bb2Cc", status: "incomplete", id: "a2", slug: "s2")
        let editedByHand = Self.challengePage(prefix: "hv_Dd3Ee4Ff", status: "complete", id: "a3", slug: "s3")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let heads = [
            "a1": AgentSetup.HeadVersion(artifactId: "a1", authorKind: "agent", authorKeyId: "k1", createdAt: when),
            "a2": AgentSetup.HeadVersion(artifactId: "a2", authorKind: "system", authorKeyId: nil, createdAt: when),
            "a3": AgentSetup.HeadVersion(artifactId: "a3", authorKind: "user", authorKeyId: nil, createdAt: when),
        ]
        let statuses = AgentSetup.resolve(keys: [k1, k2, k3], pages: [done, pending, editedByHand], heads: heads)
        XCTAssertEqual(statuses["k1"], AgentSetupStatus(slug: "s1", complete: true, completedAt: when))
        XCTAssertEqual(statuses["k2"], AgentSetupStatus(slug: "s2", complete: false))
        XCTAssertEqual(statuses["k3"]?.complete, false, "a dashboard edit cannot pass for a working agent")

        // A database from before commits: the marker alone decides.
        XCTAssertEqual(AgentSetup.resolve(keys: [k3], pages: [editedByHand], heads: nil)["k3"]?.complete, true)
        // A key with no challenge (minted before challenges existed) has no status at all.
        XCTAssertNil(AgentSetup.resolve(keys: [AgentKey(id: "k9", keyPrefix: "hv_Zz9Zz9Zz")], pages: [done], heads: heads)["k9"])
    }

    func testTheNewestChallengePerPrefixWins() {
        let key = AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL")
        let newer = Self.challengePage(prefix: "hv_Zk3pQ9vL", status: "complete", id: "new", slug: "newer")
        let older = Self.challengePage(prefix: "hv_Zk3pQ9vL", status: "incomplete", id: "old", slug: "older")
        let heads = ["new": AgentSetup.HeadVersion(artifactId: "new", authorKind: "agent", authorKeyId: "k1", createdAt: nil)]
        XCTAssertEqual(AgentSetup.resolve(keys: [key], pages: [newer, older], heads: heads)["k1"]?.slug, "newer")
    }

    func testSnapshotReadsKeysPagesAndCommits() async throws {
        let pagesJSON = """
        [{"id":"a1","slug":"agent-setup-1","tags":["agent-setup-challenge","hv_Zk3pQ9vL"],"content":"<body data-setup-status=\\"complete\\">"},
         {"id":"a2","slug":"agent-setup-2","tags":["agent-setup-challenge","hv_Aa1Bb2Cc"],"content":"<body data-setup-status=\\"incomplete\\">"}]
        """
        let versionsJSON = #"[{"artifact_id":"a1","author_kind":"agent","author_key_id":"k1","created_at":"2026-10-25T09:00:00.5+00:00"},{"artifact_id":"a1","author_kind":"system","author_key_id":null,"created_at":"2026-10-20T10:00:00Z"}]"#
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", Self.keysJSON),
            .json(.get, "/rest/v1/artifacts", pagesJSON),
            .json(.get, "/rest/v1/artifact_versions", versionsJSON),
        ])
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(snapshot.keys.count, 2)
        XCTAssertEqual(snapshot.statuses["k1"]?.complete, true)
        XCTAssertNotNil(snapshot.statuses["k1"]?.completedAt)
        XCTAssertEqual(snapshot.statuses["k2"]?.complete, false)
        XCTAssertEqual(snapshot.connectedCount, 1)

        let artifactRequests = await transport.requests(matching: "/rest/v1/artifacts")
        let artifactRequest = try XCTUnwrap(artifactRequests.first)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(artifactRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["tags"], "cs.{agent-setup-challenge}")
        let versionRequests = await transport.requests(matching: "/rest/v1/artifact_versions")
        let versionRequest = try XCTUnwrap(versionRequests.first)
        let versionItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(versionRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(versionItems["artifact_id"], "in.(a1,a2)")
    }

    func testStatusIsLeftOutWhenTheChallengePagesCannotBeRead() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", Self.keysJSON),
            .failure(.get, "/rest/v1/artifacts", status: 500, message: "boom"),
        ])
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(snapshot.keys.count, 2)
        XCTAssertTrue(snapshot.statuses.isEmpty, "no status rather than a wrong one")
    }

    func testStatusFallsBackToTheMarkerWhenCommitsDoNotExist() async throws {
        let pagesJSON = #"[{"id":"a1","slug":"agent-setup-1","tags":["agent-setup-challenge","hv_Zk3pQ9vL"],"content":"<body data-setup-status=\"complete\">"}]"#
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", Self.keysJSON),
            .json(.get, "/rest/v1/artifacts", pagesJSON),
            .json(.get, "/rest/v1/artifact_versions", #"{"code":"PGRST205","message":"Could not find the table 'public.artifact_versions' in the schema cache"}"#, status: 404),
        ])
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(snapshot.statuses["k1"]?.complete, true)
    }

    // MARK: Onboarding

    func testOnboardingFlagsAreRecordedOnce() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/onboarding", #"{"persisted":true,"onboarding":{}}"#)])
        let hv = api(transport)
        let dismissed = try await hv.send(.recordOnboarding(connectDismissed: true))
        XCTAssertEqual(dismissed.persisted, true)
        _ = try await hv.send(.recordOnboarding(connectCompleted: true))
        let sent = await transport.requests(matching: "/api/onboarding")
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody)), ["connect_dismissed": true])
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[1].httpBody)), ["connect_completed": true])
    }
}

/// A counter a `@Sendable` route handler can bump.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
