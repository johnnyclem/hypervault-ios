import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Agent keys: app/api/keys/route.ts, lib/api-keys.ts, lib/agent-setup.ts (whose verdict the app does not work out
/// again), and the PostgREST read the account page does on the server (app/vault/account/page.tsx).
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

    // MARK: The address a key mails as

    static let claimA = "11111111-1111-4111-8111-111111111111"
    static let claimB = "22222222-2222-4222-8222-222222222222"

    func testPinningAKeySendsOnlyTheClaimAndUnpinningSendsNull() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/keys", #"{"key":{"id":"k1","scopes":["mail:read"],"mail_claim_id":"\#(Self.claimA)","mail_pin_cleared":false}}"#),
        ])
        let hv = api(transport)
        let pinned = try await hv.send(.setAgentKeyMailAddress(id: "k1", claimId: Self.claimA))
        XCTAssertEqual(pinned.key.mailClaimId, Self.claimA)
        XCTAssertEqual(pinned.key.mailPinCleared, false)
        _ = try await hv.send(.setAgentKeyMailAddress(id: "k1", claimId: nil))

        let sent = await transport.requests(matching: "/api/keys")
        XCTAssertEqual(sent.map { $0.httpMethod }, ["PATCH", "PATCH"])
        XCTAssertEqual(
            try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody)),
            ["id": "k1", "mail_claim_id": .string(Self.claimA)],
            "no scopes ride along: the switch and the picker are separate changes"
        )
        let unpin = try XCTUnwrap(sent[1].httpBody)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: unpin), ["id": "k1", "mail_claim_id": .null])
        XCTAssertTrue(String(decoding: unpin, as: UTF8.self).contains(#""mail_claim_id":null"#), "an explicit null, not a missing field")
    }

    func testAClaimThatIsNotTheirsIsRefused() async {
        let transport = MockTransport(routes: [.failure(.patch, "/api/keys", status: 404, message: "That address isn't one of yours.")])
        do {
            _ = try await api(transport).send(.setAgentKeyMailAddress(id: "k1", claimId: Self.claimB))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.userMessage, "That address isn't one of yours.")
        } catch {
            XCTFail("\(error)")
        }
    }

    private func mailbox(_ id: String, claim: String?, address: String?, primary: Bool = false) -> OwnerMailbox {
        OwnerMailbox(id: id, claimId: claim, address: address, isPrimary: primary)
    }

    func testTheChoicesAreTheMailboxesThatHaveAClaimAndAnAddress() {
        let mailboxes = [
            mailbox("m1", claim: Self.claimA, address: "ana@vault.cool", primary: true),
            mailbox("m2", claim: nil, address: nil),
            mailbox("m3", claim: Self.claimB, address: "studio@vault.cool"),
            mailbox("m4", claim: Self.claimB, address: ""),
            mailbox("m5", claim: nil, address: "orphan@vault.cool"),
        ]
        let pin = AgentKeyMailPin(key: AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL", scopes: ["mail:read"]), mailboxes: mailboxes)
        XCTAssertEqual(pin.choices.map(\.address), ["ana@vault.cool", "studio@vault.cool"])
        XCTAssertEqual(pin.choices.map(\.claimId), [Self.claimA, Self.claimB], "a pin is a claim, not a mailbox")
        XCTAssertTrue(pin.isOffered)

        let none = AgentKeyMailPin(key: AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL"), mailboxes: [mailbox("m2", claim: nil, address: nil)])
        XCTAssertFalse(none.isOffered, "with no claimed address the picker would hold only Default address")
        XCTAssertFalse(AgentKeyMailPin(key: AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL"), mailboxes: []).isOffered)
    }

    func testWhatThePickerHasChosen() {
        let mailboxes = [mailbox("m1", claim: Self.claimA, address: "ana@vault.cool")]
        func pin(claim: String? = nil, cleared: Bool = false) -> AgentKeyMailPin {
            AgentKeyMailPin(key: AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL", scopes: ["mail:read"], mailClaimId: claim, mailPinCleared: cleared), mailboxes: mailboxes)
        }

        XCTAssertEqual(pin().selection, .defaultAddress)
        XCTAssertNil(pin().unlistedClaimId)

        XCTAssertEqual(pin(claim: Self.claimA).selection, .claim(Self.claimA))
        XCTAssertNil(pin(claim: Self.claimA).unlistedClaimId)

        // The claim was released: there is no address to show, and Default address must still be a change.
        XCTAssertEqual(pin(cleared: true).selection, .choosing)
        XCTAssertNil(pin(cleared: true).unlistedClaimId)

        // Pinned to an address the list does not carry: "Another address", chosen.
        XCTAssertEqual(pin(claim: Self.claimB).selection, .claim(Self.claimB))
        XCTAssertEqual(pin(claim: Self.claimB).unlistedClaimId, Self.claimB)

        // A claim wins over the flag: the person has chosen again.
        XCTAssertEqual(pin(claim: Self.claimA, cleared: true).selection, .claim(Self.claimA))
    }

    func testTheAddressPickersWordsAreTheWebs() {
        XCTAssertEqual(AccountWords.mailPinLabel, "Mail address")
        XCTAssertEqual(AccountWords.mailPinDefault, "Default address")
        XCTAssertEqual(AccountWords.mailPinChoose, "Pick an address")
        XCTAssertEqual(AccountWords.mailPinOther, "Another address")
        XCTAssertEqual(AccountWords.mailPinClearedLine, "Its address was released. This key can read but not send until you pick an address for it.")
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

    // MARK: Setup challenge pages

    static let challengeTag = SetupChallengePages.tag

    func testEachKeyFindsItsOwnChallengePageByPrefixAndTheNewestWins() {
        let keys = [
            AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL"), AgentKey(id: "k2", keyPrefix: "hv_Aa1Bb2Cc"), AgentKey(id: "k3", keyPrefix: "hv_Dd3Ee4Ff"),
        ]
        let pages = [
            SetupChallengePages.Page(slug: "newer", tags: [Self.challengeTag, "hv_Zk3pQ9vL"]),
            SetupChallengePages.Page(slug: "second", tags: [Self.challengeTag, "hv_Aa1Bb2Cc"]),
            SetupChallengePages.Page(slug: "older", tags: [Self.challengeTag, "hv_Zk3pQ9vL"]),
        ]
        let slugs = SetupChallengePages.slugs(keys: keys, pages: pages)
        XCTAssertEqual(slugs, ["k1": "newer", "k2": "second"], "the key with no page has no entry, and says nothing about its setup")
    }

    func testSnapshotReadsKeysAndOnlyTheSlugsAndTagsOfTheirPages() async throws {
        let pagesJSON = """
        [{"slug":"agent-setup-1","tags":["agent-setup-challenge","hv_Zk3pQ9vL"]},
         {"slug":"agent-setup-2","tags":["agent-setup-challenge","hv_Aa1Bb2Cc"]}]
        """
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", Self.keysJSON),
            .json(.get, "/rest/v1/artifacts", pagesJSON),
        ])
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(snapshot.keys.count, 2)
        XCTAssertEqual(snapshot.challengeSlugs, ["k1": "agent-setup-1", "k2": "agent-setup-2"])

        let artifactRequests = await transport.requests(matching: "/rest/v1/artifacts")
        let artifactRequest = try XCTUnwrap(artifactRequests.first)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(artifactRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["tags"], "cs.{agent-setup-challenge}")
        XCTAssertEqual(items["select"], "slug,tags", "a page's content is never read, so the app cannot work out whether an agent finished")
        let versionRequests = await transport.requests(matching: "/rest/v1/artifact_versions")
        XCTAssertTrue(versionRequests.isEmpty, "who wrote a page is not read either")
    }

    func testNoSlugsWhenTheChallengePagesCannotBeRead() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/api_keys", Self.keysJSON),
            .failure(.get, "/rest/v1/artifacts", status: 500, message: "boom"),
        ])
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest(transport), userID: "user-1")
        XCTAssertEqual(snapshot.keys.count, 2)
        XCTAssertTrue(snapshot.challengeSlugs.isEmpty)
    }

    func testASnapshotSavedByAnOlderVersionStillReads() throws {
        // The saved copy used to carry a verdict per key. It is ignored, not shown.
        let saved = #"{"keys":[{"id":"k1","keyPrefix":"hv_Zk3pQ9vL","name":"Claude Code","mailPinCleared":false}],"statuses":{"k1":{"slug":"s1","complete":true}}}"#
        let snapshot = try HVCoding.decoder().decode(AgentKeysSnapshot.self, from: Data(saved.utf8))
        XCTAssertEqual(snapshot.keys.map(\.id), ["k1"])
        XCTAssertTrue(snapshot.challengeSlugs.isEmpty)

        let round = try HVCoding.decoder().decode(AgentKeysSnapshot.self, from: try HVCoding.encoder().encode(AgentKeysSnapshot(keys: snapshot.keys, challengeSlugs: ["k1": "s1"])))
        XCTAssertEqual(round.challengeSlugs, ["k1": "s1"])
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

final class AccountWordsTests: XCTestCase {
    func testAgoLine() {
        let cases: [(TimeInterval, String)] = [
            (0, "Just now"), (59, "Just now"), (-30, "Just now"), (.nan, "Just now"),
            (60, "1 min ago"), (59 * 60, "59 min ago"), (3600, "1 hr ago"), (23 * 3600, "23 hr ago"),
            (24 * 3600, "Yesterday"), (47 * 3600, "Yesterday"), (48 * 3600, "2 days ago"), (29 * 86400, "29 days ago"),
            (30 * 86400, "1 month ago"), (90 * 86400, "3 months ago"), (365 * 86400, "1 year ago"), (800 * 86400, "2 years ago"),
        ]
        for (seconds, line) in cases { XCTAssertEqual(AccountWords.agoLine(seconds: seconds), line, "\(seconds)") }
    }

    func testLastUsedLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AccountWords.lastUsedLine(nil, now: now), "Never used")
        XCTAssertEqual(AccountWords.lastUsedLine(now.addingTimeInterval(-3 * 86400), now: now), "Last used 3 days ago")
        XCTAssertEqual(AccountWords.lastUsedLine(now.addingTimeInterval(-86400), now: now), "Last used yesterday")
        XCTAssertEqual(AccountWords.lastUsedLine(now, now: now), "Last used just now")
    }
}
