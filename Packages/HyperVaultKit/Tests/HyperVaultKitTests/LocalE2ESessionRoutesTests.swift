import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The routes that took only a signed-in browser session until the server learned to read a bearer token
// (hypervault#180): agent keys, invite redeem, onboarding, the artifact source and admin. Plus the
// Kit's own sign-in and its direct reads of the database. Setup is in LocalServerE2ETests.swift.

final class LocalE2ESessionRoutesTests: LocalE2ECase {

    /// Who a token is, as the server says it (a member), or as the token itself says (a waitlisted account
    /// is refused before it is named).
    private func userId(of token: String) async throws -> String {
        let caps = try await send(.capabilities, client(token))
        if let id = caps.user?.id { return id }
        return try XCTUnwrap(jwtSubject(token), "the token names no one")
    }

    private func supabaseConfig() throws -> SupabaseConfig {
        guard let url = env.supabaseURL, let anon = env.anonKey else {
            throw XCTSkip("Set HV_E2E_SUPABASE_URL and HV_E2E_ANON_KEY.")
        }
        return SupabaseConfig(url: url, anonKey: anon)
    }

    // MARK: Agent keys

    func testMintAKeyListItThroughTheKitsOwnReadUseItThenRevokeIt() async throws {
        let (api, token) = member(2)
        let userID = try await userId(of: token)
        let rest = try rest(token: token)
        let name = unique("E2E agent")

        let minted = try await send(.createAgentKey(name: name), api)
        XCTAssertTrue(minted.key.hasPrefix("hv_"))
        XCTAssertTrue(AgentKeyRules.looksLikeKey(minted.key), "the Kit does not recognise the key the server minted: \(minted.key.count) chars")
        XCTAssertEqual(minted.prefix, String(minted.key.prefix(11)))
        XCTAssertNotNil(minted.challenge, "a new key comes with its setup challenge page")
        XCTAssertFalse(minted.message?.isEmpty ?? true)

        // The Kit lists keys by reading api_keys through PostgREST with the person's own token.
        let listed = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        let row = try XCTUnwrap(listed.first { $0.keyPrefix == minted.prefix }, "the new key is missing from the keys list")
        XCTAssertEqual(row.name, name)
        XCTAssertNotNil(row.createdAt)
        XCTAssertNil(row.lastUsedAt)
        XCTAssertFalse(row.isPaired)
        XCTAssertEqual(row.scopes, ["mail:read"], "a key reads its mail and cannot send until its owner says so")
        XCTAssertFalse(row.canSendMail)
        XCTAssertTrue(row.hasMailControls)
        // The hash is not readable by a signed-in person: `*` includes it, and asking for it by name is refused too.
        for columns in ["*", "key_hash"] {
            do {
                let _: [JSONValue] = try await rest.rows(from: "api_keys", query: [URLQueryItem(name: "select", value: columns), URLQueryItem(name: "id", value: "eq.\(row.id)")])
                XCTFail("select=\(columns) on api_keys was allowed")
            } catch let error as HVError {
                XCTAssertEqual(error.status, 403, "select=\(columns): \(error)")
                XCTAssertEqual(error.code, "42501")
            }
        }

        // The key is an identity of its own kind.
        let agent = client(minted.key)
        let caps = try await send(.capabilities, agent)
        XCTAssertEqual(caps.user?.via, "api-key")
        XCTAssertEqual(caps.user?.id, userID)
        _ = try await send(.yours(), agent)
        let used = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        XCTAssertNotNil(used.first { $0.id == row.id }?.lastUsedAt, "using the key did not stamp last_used_at")

        // A key cannot mint, change or revoke keys: those take a person.
        await expectFailure(401, .createAgentKey(name: "nope"), agent)
        await expectFailure(403, .setAgentKeyMail(id: row.id, canSendMail: true), agent)
        await expectFailure(401, .revokeAgentKey(id: row.id), agent)

        // Revoke: gone from the list, and the key stops working.
        let revoked = try await send(.revokeAgentKey(id: row.id), api)
        XCTAssertEqual(revoked.revoked, row.id)
        let after = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        XCTAssertNil(after.first { $0.id == row.id })
        await expectFailure(401, .yours(), agent)
        await expectFailure(404, .revokeAgentKey(id: row.id), api, message: "already be revoked")
    }

    func testAKeyCanBeGivenTheRightToSendMailAndTheListShowsIt() async throws {
        let (api, token) = member(2)
        let userID = try await userId(of: token)
        let rest = try rest(token: token)
        let minted = try await send(.createAgentKey(name: unique("Mailer"), canSendMail: true), api)
        var keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        let row = try XCTUnwrap(keys.first { $0.keyPrefix == minted.prefix })
        XCTAssertTrue(row.canSendMail, "scopes: \(String(describing: row.scopes))")

        let update = try await send(.setAgentKeyMail(id: row.id, canSendMail: false), api)
        XCTAssertEqual(update.key.id, row.id)
        XCTAssertEqual(update.key.scopes, ["mail:read"])
        keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        XCTAssertFalse(try XCTUnwrap(keys.first { $0.id == row.id }).canSendMail)
        _ = try await send(.revokeAgentKey(id: row.id), api)
    }

    func testAnAgentFinishesItsSetupChallengeAndTheKeysListSaysConnected() async throws {
        let (api, token) = member(3)
        let userID = try await userId(of: token)
        let rest = try rest(token: token)
        let minted = try await send(.createAgentKey(name: unique("Connector")), api)
        let challenge = try XCTUnwrap(minted.challenge)
        var keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        let row = try XCTUnwrap(keys.first { $0.keyPrefix == minted.prefix })

        // Before: the challenge exists and is not complete.
        var statuses = await AgentKeyDirectory.setupStatuses(rest: rest, userID: userID, keys: keys)
        XCTAssertEqual(statuses[row.id]?.slug, challenge.slug)
        XCTAssertEqual(statuses[row.id]?.complete, false)

        // The agent, holding only the key, reads the page and writes it back completed.
        let agent = client(minted.key)
        let page = try await send(.artifactContent(slug: challenge.slug), agent)
        XCTAssertFalse(AgentSetup.isComplete(content: page.content))
        let done = page.content.replacingOccurrences(of: "data-setup-status=\"incomplete\"", with: "data-setup-status=\"complete\"")
        XCTAssertNotEqual(done, page.content)
        let head = try XCTUnwrap(page.headVersionId ?? page.version?.id)
        let written = try await send(.writeArtifact(slug: challenge.slug, ArtifactWriteRequest(content: done, message: "agent setup complete", baseVersionId: head)), agent)
        XCTAssertFalse(written.unchanged)

        keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        statuses = await AgentKeyDirectory.setupStatuses(rest: rest, userID: userID, keys: keys)
        XCTAssertEqual(statuses[row.id]?.complete, true, "the Kit's two PostgREST reads did not agree the agent connected")
        XCTAssertNotNil(statuses[row.id]?.completedAt)
        let snapshot = try await AgentKeyDirectory.snapshot(rest: rest, userID: userID)
        XCTAssertEqual(snapshot.keys.count, keys.count)
        XCTAssertGreaterThanOrEqual(snapshot.connectedCount, 1)

        // A hand edit by the person does not count as the agent connecting.
        let second = try await send(.createAgentKey(name: unique("Forged")), api)
        let secondPage = try await send(.artifactContent(slug: try XCTUnwrap(second.challenge).slug), api)
        let forged = secondPage.content.replacingOccurrences(of: "data-setup-status=\"incomplete\"", with: "data-setup-status=\"complete\"")
        _ = try await send(.writeArtifact(slug: try XCTUnwrap(second.challenge).slug, ArtifactWriteRequest(content: forged, baseVersionId: secondPage.headVersionId)), api)
        keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
        statuses = await AgentKeyDirectory.setupStatuses(rest: rest, userID: userID, keys: keys)
        let forgedRow = try XCTUnwrap(keys.first { $0.keyPrefix == second.prefix })
        XCTAssertEqual(statuses[forgedRow.id]?.complete, false, "a page edited by hand passed for a connected agent")
    }

    // MARK: The artifact source route (hypervault#180)

    func testTheArtifactSourceRouteTakesABearerAndRefusesOthers() async throws {
        let (api, _) = member(4)
        let word = uniqueWord()
        let kept = try await send(.keep(content: "<!doctype html><html><head><title>S \(word)</title></head><body><p>\(word)</p></body></html>"), api)
        let (source, raw) = try await fetch(.artifactSource(slug: kept.slug), api)
        XCTAssertTrue(source.content.contains(word))
        XCTAssertEqual(source.content, raw["content"]?.string)

        // Not mine: a page is invisible to someone it was not shared with.
        let (other, _) = try second()
        await expectFailure(404, .artifactSource(slug: kept.slug), other)
        await expectFailure(404, .artifactSource(slug: "no-such-\(unique("page"))"), api)
        await expectFailure(401, .artifactSource(slug: kept.slug), client("bad-token"))
    }

    // MARK: Onboarding

    func testOnboardingStampsEachFlagOnceAndRefusesAnEmptyBody() async throws {
        let (api, token) = member(5)
        let userID = try await userId(of: token)
        let rest = try rest(token: token)
        struct OnboardingRow: Decodable, Sendable { let onboarding: JSONValue? }
        func read() async throws -> JSONValue {
            let rows: [OnboardingRow] = try await rest.rows(from: "profiles", query: [
                URLQueryItem(name: "select", value: "onboarding"), URLQueryItem(name: "id", value: "eq.\(userID)"),
            ])
            return try XCTUnwrap(rows.first?.onboarding)
        }
        // A person who ran this before already has a stamp; it must not move.
        let before = try await read()
        let first = try await send(.recordOnboarding(connectDismissed: true), api)
        XCTAssertEqual(first.persisted, true)
        let stamped = try await read()
        let dismissedAt = try XCTUnwrap(stamped["connect_dismissed_at"]?.string, "the dismiss was not stamped: \(stamped)")
        XCTAssertNotNil(HVDate.parse(dismissedAt))
        if let earlier = before["connect_dismissed_at"]?.string { XCTAssertEqual(dismissedAt, earlier) }

        _ = try await send(.recordOnboarding(connectDismissed: true, connectCompleted: true), api)
        let again = try await read()
        XCTAssertEqual(again["connect_dismissed_at"]?.string, dismissedAt, "a second dismiss moved the date")
        XCTAssertNotNil(again["connect_completed_at"]?.string)

        await expectFailure(400, .recordOnboarding(), api, message: "Nothing to record")
        await expectFailure(401, .recordOnboarding(connectDismissed: true), client("nope"))
    }

    // MARK: Invites and the waitlist

    func testAnInviteCodeLetsAWaitlistedAccountIn() async throws {
        let (admin, _) = try admin()
        let (carol, carolToken) = try waitlisted()
        let carolID = try await userId(of: carolToken)
        let config = try supabaseConfig()
        let redeemer = InviteRedeemer(config: config, transport: URLSessionTransport(), tokens: LocalStaticToken(token: carolToken))

        // Start from the waitlist, however the last run ended.
        _ = try await send(.changeAccount(id: carolID, .revoke), admin)
        await expectFailure(403, .yours(), carol, message: "waitlist")

        // A wrong code, then a real one minted by the administrator.
        let invalid = try await redeemer.redeem("HV-NOPE-NOPE")
        XCTAssertEqual(invalid, .invalid)
        let invite = try await send(.createInvite(maxUses: 1, note: "e2e \(unique("note"))"), admin).invite
        XCTAssertTrue(invite.code.range(of: #"^HV-[A-Z2-9]{4}-[A-Z2-9]{4}$"#, options: .regularExpression) != nil, invite.code)
        XCTAssertEqual(invite.maxUses, 1)
        XCTAssertEqual(invite.useCount, 0)
        XCTAssertEqual(invite.status, .active)
        XCTAssertNotNil(invite.createdAt)
        XCTAssertEqual(InviteCode.extract(from: "my code is \(invite.code.lowercased())!"), invite.code)

        let ok = try await redeemer.redeem(invite.code.lowercased())
        XCTAssertEqual(ok, .ok)
        XCTAssertTrue(ok.isAccepted)
        _ = try await send(.yours(), carol)          // let in
        let again = try await redeemer.redeem(invite.code)
        XCTAssertEqual(again, .alreadyApproved)

        // The row now counts the use, and a used-up code is exhausted for the next person.
        let after = try await send(.setInvite(id: invite.id, disabled: false), admin).invite
        XCTAssertEqual(after.useCount, 1)
        XCTAssertEqual(after.status, .usedUp)
        _ = try await send(.changeAccount(id: carolID, .revoke), admin)
        let exhausted = try await redeemer.redeem(invite.code)
        XCTAssertEqual(exhausted, .exhausted)

        // Turned off, a code is disabled; turned on again it is spent.
        let off = try await send(.setInvite(id: invite.id, disabled: true), admin).invite
        XCTAssertEqual(off.status, .disabled)
        let disabled = try await redeemer.redeem(invite.code)
        XCTAssertEqual(disabled, .disabled)

        // The web's own route, with a bearer, with a fresh code.
        let multi = try await send(.createInvite(maxUses: 5, note: nil), admin).invite
        let viaRoute = Endpoint<JSONValue>(.post, "/api/invite/redeem", body: .jsonValue(["code": .string(multi.code)]))
        let result = try await send(viaRoute, carol)
        XCTAssertEqual(result["result"]?.string, "ok")
        _ = try await send(.yours(), carol)
        _ = try await send(.changeAccount(id: carolID, .revoke), admin)
        let bad = Endpoint<JSONValue>(.post, "/api/invite/redeem", body: .jsonValue(["code": "HV-ZZZZ-ZZZZ"]))
        let failure = await expectFailure(400, bad, carol)
        XCTAssertEqual(failure?.body?["result"]?.string, "invalid")
        await expectFailure(400, Endpoint<JSONValue>(.post, "/api/invite/redeem", body: .jsonValue(["code": ""])), carol, message: "invite code")

        // Cleanup: both codes go, and the account is let in again as the administrator would.
        let gone = try await send(.deleteInvite(id: invite.id), admin)
        XCTAssertEqual(gone.ok, true)
        _ = try await send(.deleteInvite(id: multi.id), admin)
        await expectFailure(404, .setInvite(id: invite.id, disabled: true), admin, message: "No such invite")
    }

    // MARK: Admin

    func testAdminRoutesRefuseAMemberAndTheProbeTellsThemApart() async throws {
        let (admin, _) = try admin()
        let (member, _) = self.member(6)
        let memberProbe = await expectFailure(403, .adminProbe, member)
        XCTAssertEqual(AdminProbe.verdict(status: memberProbe?.status), .notAdmin)
        await expectFailure(403, .createInvite(maxUses: 1, note: nil), member)
        await expectFailure(403, .changeAccount(id: AdminProbe.probeID, .approve), member)
        await expectFailure(403, .deleteAccount(id: AdminProbe.probeID), member)

        let adminProbe = await expectFailure(400, .adminProbe, admin)
        XCTAssertEqual(AdminProbe.verdict(status: adminProbe?.status), .admin)
        await expectFailure(401, .adminProbe, client("garbage"))
        // A key is never an administrator.
        let (_, token) = self.member(6)
        let key = try await send(.createAgentKey(name: unique("not admin")), client(token))
        await expectFailure(401, .adminProbe, client(key.key))
    }

    func testAdminChangesAnAccountsPlanAndNameAndTheAccountReadSeesIt() async throws {
        let (admin, _) = try admin()
        let (_, token) = member(7)
        let userID = try await userId(of: token)
        let rest = try rest(token: token)
        _ = try await send(.changeAccount(id: userID, .plan(.free)), admin)   // a known start, however the last run ended

        _ = try await send(.changeAccount(id: userID, .plan(.pro)), admin)
        var profile = try await rest.profile(userID: userID)
        XCTAssertEqual(profile?.plan, "pro")
        XCTAssertTrue(profile?.isPro ?? false)
        _ = try await send(.changeAccount(id: userID, .displayName("  Pool Seven  ")), admin)
        struct NameRow: Decodable, Sendable { let displayName: String? }
        let names: [NameRow] = try await rest.rows(from: "profiles", query: [
            URLQueryItem(name: "select", value: "display_name"), URLQueryItem(name: "id", value: "eq.\(userID)"),
        ])
        XCTAssertEqual(names.first?.displayName, "Pool Seven")
        _ = try await send(.changeAccount(id: userID, .plan(.free)), admin)
        profile = try await rest.profile(userID: userID)
        XCTAssertEqual(profile?.plan, "free")
        await expectFailure(400, .changeAccount(id: userID, .displayName("")), admin)
        // The route updates zero rows for an account that does not exist and still answers ok (a server quirk, noted in the report).
        let unknown = try await send(.changeAccount(id: "00000000-0000-4000-8000-0000000000ff", .plan(.pro)), admin)
        XCTAssertEqual(unknown.ok, true)
    }

    // MARK: The Kit's own sign-in against the fake auth server

    func testSignInWithAnEmailCodeRefreshAndSignOut() async throws {
        let config = try supabaseConfig()
        let store = InMemorySecureStore()
        let auth = AuthService(config: config, transport: URLSessionTransport(), store: store)
        let email = "\(unique("newcomer"))@e2e.test"

        let providers = await auth.providers()
        XCTAssertTrue(providers.email, "the stand-in's settings offer email")
        XCTAssertTrue(providers.google)
        XCTAssertFalse(providers.signupDisabled)

        try await auth.requestEmailCode(email: email)
        do {
            _ = try await auth.verifyEmailCode(email: email, code: "000000")
            XCTFail("a wrong code signed in")
        } catch let error as AuthError {
            if case .failed(let message) = error { XCTAssertFalse(message.isEmpty) } else { XCTFail("\(error)") }
        }
        let session = try await auth.verifyEmailCode(email: email, code: "424 242")
        XCTAssertEqual(session.user.email, email)
        XCTAssertFalse(session.user.id.isEmpty)
        XCTAssertGreaterThan(session.expiresAt.timeIntervalSinceNow, 3000)
        let state = await auth.state
        XCTAssertEqual(state.user?.id, session.user.id)

        // The app server accepts the token the auth server made, and tells a new account it is on the waitlist.
        let api = HVClient(baseURL: env.server.baseURL, transport: URLSessionTransport(), tokens: auth, retry: .none)
        let (admin, _) = try admin()
        let caps = try await send(.capabilities, api)
        XCTAssertNil(caps.user, "an account on the waitlist is not named by capabilities")
        await expectFailure(403, .yours(), api, message: "waitlist")
        _ = try await send(.changeAccount(id: session.user.id, .approve), admin)
        let named = try await send(.capabilities, api)
        XCTAssertEqual(named.user?.id, session.user.id)
        XCTAssertEqual(named.user?.email, email)
        _ = try await send(.yours(), api)

        // Refresh: a new pair, the old refresh token is spent.
        let refreshed = try await auth.refreshSession()
        XCTAssertNotEqual(refreshed.accessToken, session.accessToken)
        XCTAssertNotEqual(refreshed.refreshToken, session.refreshToken)
        XCTAssertEqual(refreshed.user.id, session.user.id)
        let capsAfter = try await send(.capabilities, api)
        XCTAssertEqual(capsAfter.user?.id, session.user.id)

        // A second service holding the spent refresh token is refused, the way a stolen token would be.
        let staleStore = InMemorySecureStore()
        let spent = AuthSession(accessToken: session.accessToken, refreshToken: session.refreshToken, expiresAt: Date().addingTimeInterval(-10), user: session.user)
        await staleStore.set(try HVCoding.encoder(.verbatim).encode(spent), for: AuthService.sessionKey)
        let stale = AuthService(config: config, transport: URLSessionTransport(), store: staleStore)
        await stale.restore()
        do {
            _ = try await stale.refreshSession()
            XCTFail("a spent refresh token was accepted")
        } catch let error as AuthError {
            guard case .failed = error else { return XCTFail("\(error)") }
        }

        // An administrator deletes the account: the token stops working and the profile is gone.
        let removed = try await send(.deleteAccount(id: session.user.id), admin)
        XCTAssertEqual(removed.ok, true)
        await expectFailure(401, .yours(), api)

        await auth.signOut()
        let finalState = await auth.state
        XCTAssertEqual(finalState, .signedOut)
    }

    func testAnExpiringTokenIsRefreshedBeforeTheCallAndOn401() async throws {
        let config = try supabaseConfig()
        let auth = AuthService(config: config, transport: URLSessionTransport(), store: InMemorySecureStore(), refreshMargin: 7200)
        let email = "\(unique("refresher"))@e2e.test"
        try await auth.requestEmailCode(email: email)
        let session = try await auth.verifyEmailCode(email: email, code: "424242")
        // The margin is two hours and the token lasts one: every call refreshes first.
        let token = try await auth.accessToken()
        XCTAssertNotEqual(token, session.accessToken)
        let (admin, _) = try admin()
        _ = try await send(.changeAccount(id: session.user.id, .approve), admin)
        let api = HVClient(baseURL: env.server.baseURL, transport: URLSessionTransport(), tokens: auth, retry: .none)
        let caps = try await send(.capabilities, api)
        XCTAssertEqual(caps.user?.id, session.user.id)

        // A 401 from the server (a token it has never heard of) makes one refresh and one retry.
        let provider = ShortLivedThenFresh(auth: auth, bad: env.expiredToken ?? "bad.token.value")
        let retrying = HVClient(baseURL: env.server.baseURL, transport: URLSessionTransport(), tokens: provider, retry: .none)
        _ = try await send(.yours(), retrying)
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(refreshes, 1, "a 401 should refresh exactly once")

        _ = try await send(.deleteAccount(id: session.user.id), admin)
    }
}

// MARK: Helpers for this file

/// Hands out a token the server will refuse first, and a fresh one after the Kit asks to refresh.
actor ShortLivedThenFresh: TokenProvider {
    private let auth: AuthService
    private let bad: String
    private var refreshes = 0
    private var served = false

    init(auth: AuthService, bad: String) {
        self.auth = auth
        self.bad = bad
    }

    func accessToken() async throws -> String? {
        if !served {
            served = true
            return bad
        }
        return try await auth.accessToken()
    }

    func refreshAfterUnauthorized(rejected: String?) async throws -> String? {
        refreshes += 1
        return try await auth.accessToken()
    }

    func refreshCount() -> Int { refreshes }
}
