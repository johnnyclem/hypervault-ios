import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The saved-secrets vault (the Kit ports the server's rules, so the two are compared field by field),
// webhooks, claimed addresses, dreams, digest and background jobs.

final class LocalE2EAccountTests: LocalE2ECase {

    private func userId(of token: String) async throws -> String {
        let caps = try await send(.capabilities, client(token))
        return try XCTUnwrap(caps.user?.id)
    }

    // MARK: Vault secrets: the Kit's rules against the server's

    private struct Case {
        let kind: VaultItemKind
        let fields: VaultItems.Fields
        let note: String
    }

    /// Entries a person might type: messy spacing, a pasted card with dashes, a short year.
    private var acceptedCases: [Case] {
        [
            Case(kind: .login, fields: ["url": " https://Example.com/login ", "username": " alice ", "password": " pa ss ", "notes": "line1\r\nline2\u{07}"], note: "login with spaces in the password and a control character in the notes"),
            Case(kind: .login, fields: ["username": "bob", "password": "x"], note: "minimal login"),
            Case(kind: .login, fields: ["url": "http://localhost:3000/", "username": "dev@example.com", "password": "pw", "notes": "Üñïçødé ✓"], note: "unicode notes and a local URL"),
            Case(kind: .card, fields: ["cardholder": " A B ", "number": "4242 4242-4242 4242", "expMonth": "4", "expYear": "27", "cvc": "123"], note: "visa typed with spaces and dashes"),
            Case(kind: .card, fields: ["number": "5555555555554444", "expMonth": "12", "expYear": "2030"], note: "mastercard, no holder or code"),
            Case(kind: .card, fields: ["number": "378282246310005", "expMonth": "01", "expYear": "2031", "cvc": "1234"], note: "amex with a 4-digit code"),
            Case(kind: .contact, fields: ["fullName": "  Ada Lovelace ", "email": " ADA@Example.com ", "phone": "+1 (555) 010-0100", "address": "1 Main St\nTown"], note: "full contact"),
            Case(kind: .contact, fields: ["email": "only@example.org"], note: "email only"),
            Case(kind: .contact, fields: ["phone": "12345"], note: "shortest phone"),
            Case(kind: .contact, fields: ["address": "Somewhere"], note: "address only"),
            Case(kind: .contact, fields: ["fullName": "Grace"], note: "name only"),
        ]
    }

    private var rejectedCases: [Case] {
        [
            Case(kind: .login, fields: ["password": "x"], note: "no username"),
            Case(kind: .login, fields: ["username": "u"], note: "no password"),
            Case(kind: .login, fields: ["username": "u", "password": "   "], note: "blank password"),
            Case(kind: .login, fields: ["username": "u", "password": "p", "url": "example.com"], note: "url without a scheme"),
            Case(kind: .login, fields: ["username": "u", "password": "p", "url": "ftp://example.com"], note: "ftp url"),
            Case(kind: .login, fields: ["username": "u", "password": "p", "url": "https://"], note: "url with no host"),
            Case(kind: .card, fields: ["number": "4242424242424241", "expMonth": "12", "expYear": "2030"], note: "bad luhn"),
            Case(kind: .card, fields: ["number": "4242", "expMonth": "12", "expYear": "2030"], note: "too short"),
            Case(kind: .card, fields: ["number": "4242424242424242", "expMonth": "13", "expYear": "2030"], note: "month 13"),
            Case(kind: .card, fields: ["number": "4242424242424242", "expMonth": "00", "expYear": "2030"], note: "month 0"),
            Case(kind: .card, fields: ["number": "4242424242424242", "expMonth": "12", "expYear": "203"], note: "3-digit year"),
            Case(kind: .card, fields: ["number": "4242424242424242", "expMonth": "12", "expYear": "2030", "cvc": "12"], note: "2-digit code"),
            Case(kind: .card, fields: ["number": "4242424242424242", "expYear": "2030"], note: "no month"),
            Case(kind: .contact, fields: [:], note: "empty contact"),
            Case(kind: .contact, fields: ["email": "not-an-email"], note: "bad email"),
            Case(kind: .contact, fields: ["email": "a@b"], note: "email without a dot"),
            Case(kind: .contact, fields: ["phone": "1234"], note: "short phone"),
            Case(kind: .contact, fields: ["fullName": "   "], note: "blank name"),
        ]
    }

    private func jsonObject(_ fields: VaultItems.Fields) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func testTheKitsVaultRulesAcceptWhatTheServerAcceptsAndStoreTheSameBytes() async throws {
        let (api, token) = member(16)
        _ = try await userId(of: token)
        let agentKey = try await send(.createAgentKey(name: unique("vault reader")), api)
        let agent = client(agentKey.key)
        let myID = try await userId(of: token)
        let keys = try await AgentKeyDirectory.keys(rest: rest(token: token), userID: myID)
        let keyID = try XCTUnwrap(keys.first { $0.keyPrefix == agentKey.prefix }?.id)

        for (index, entry) in acceptedCases.enumerated() {
            let name = "e2e-\(entry.kind.rawValue)-\(index)-\(uniqueWord())"
            XCTAssertNil(VaultItems.validate(entry.kind, entry.fields), "the Kit refuses what the server takes: \(entry.note)")
            let canonical = VaultItems.serialize(entry.kind, entry.fields)

            // The canonical JSON the Kit writes is accepted, and the hint the server derives is the Kit's.
            let created = try await send(.createVaultSecret(name: name, kind: entry.kind.secretKind, value: canonical, description: "e2e \(entry.note)"), api)
            XCTAssertEqual(created.secret.name, name, entry.note)
            XCTAssertEqual(created.secret.kind, entry.kind.secretKind, entry.note)
            XCTAssertEqual(created.secret.hint, VaultItems.deriveHint(entry.kind, entry.fields), "hint differs for: \(entry.note)")
            XCTAssertEqual(created.secret.description, "e2e \(entry.note)")
            XCTAssertNotNil(created.secret.createdAt)
            XCTAssertNil(created.secret.lastAccessedAt)

            // A key that was granted reads exactly those bytes back.
            _ = try await send(.grantSecret(name: name, keyID: keyID), api)
            let value = try await send(Endpoint<JSONValue>(.get, "/api/secrets/\(name)", keys: .verbatim), agent)
            XCTAssertEqual(value["value"]?.string, canonical, "stored bytes differ for: \(entry.note)")
            XCTAssertEqual(value["kind"]?.string, entry.kind.rawValue)
            XCTAssertEqual(value["name"]?.string, name)

            // The same entry as the raw, messy JSON a form might send: the server canonicalises it to the Kit's bytes.
            let rawName = name + "-raw"
            _ = try await send(.createVaultSecret(name: rawName, kind: entry.kind.secretKind, value: jsonObject(entry.fields)), api)
            _ = try await send(.grantSecret(name: rawName, keyID: keyID), api)
            let rawValue = try await send(Endpoint<JSONValue>(.get, "/api/secrets/\(rawName)", keys: .verbatim), agent)
            XCTAssertEqual(rawValue["value"]?.string, canonical, "the server's canonical form differs from the Kit's for: \(entry.note)")
            // And what the server stored parses back as the Kit's own entry.
            if case .success(let parsed) = VaultItems.parse(entry.kind, value: rawValue["value"]?.string ?? "") {
                XCTAssertEqual(parsed, VaultItems.canonical(entry.kind, entry.fields))
            } else {
                XCTFail("the Kit cannot read what the server stored for: \(entry.note)")
            }
            _ = try await send(.deleteVaultSecret(name: name), api)
            _ = try await send(.deleteVaultSecret(name: rawName), api)
        }
    }

    func testTheServerRefusesWhatTheKitsVaultRulesRefuse() async throws {
        let (api, _) = member(16)
        for (index, entry) in rejectedCases.enumerated() {
            let problem = VaultItems.validate(entry.kind, entry.fields)
            XCTAssertNotNil(problem, "the Kit would let through: \(entry.note)")
            let name = "e2e-bad-\(index)-\(uniqueWord())"
            let failure = await expectFailure(400, .createVaultSecret(name: name, kind: entry.kind.secretKind, value: jsonObject(entry.fields)), api)
            if let failure, let problem, failure.message != problem {
                print("e2e vault wording differs for '\(entry.note)': kit '\(problem)' / server '\(failure.message)'")
            }
        }
        // A value that is not an object at all.
        await expectFailure(400, .createVaultSecret(name: "e2e-shape-\(uniqueWord())", kind: .login, value: "just a string"), api)
        await expectFailure(400, .createVaultSecret(name: "e2e-shape-\(uniqueWord())", kind: .card, value: "[1,2]"), api)
        // Names: the Kit's rule is the server's.
        for name in ["has space", "naïve", "", String(repeating: "a", count: 101), "slash/inside"] {
            XCTAssertFalse(VaultItems.isValidName(name), name)
            await expectFailure(400, .createVaultSecret(name: name, kind: .opaque, value: "v"), api)
        }
        for name in ["ok.name_1", "A-b", String(repeating: "a", count: 100)] {
            XCTAssertTrue(VaultItems.isValidName(name))
        }
    }

    func testKeysRenameUpdateGrantRevokeAndDelete() async throws {
        let (api, token) = member(17)
        let userID = try await userId(of: token)
        let name = "e2e-key-\(uniqueWord())"
        let created = try await send(.createVaultSecret(name: name, kind: .opaque, value: "sk-secret-value-123", description: "an API token"), api)
        XCTAssertEqual(created.secret.kind, .opaque)
        XCTAssertEqual(created.secret.description, "an API token")
        XCTAssertFalse(String(describing: created).contains("sk-secret-value-123"), "a stored value came back in the answer")
        await expectFailure(409, .createVaultSecret(name: name, kind: .opaque, value: "again"), api)

        let (list, raw) = try await fetch(.vaultSecrets, api)
        XCTAssertEqual(list.secrets.count, rawCount(raw, "secrets"))
        let row = try XCTUnwrap(list.secrets.first { $0.name == name })
        XCTAssertEqual(row.id, created.secret.id)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(raw), as: UTF8.self).contains("sk-secret-value-123"), "the list carries a value")

        // A person never reads the value through the machine route.
        await expectFailure(403, Endpoint<JSONValue>(.get, "/api/secrets/\(name)"), api)

        // Edit: description, then rename, then a new value.
        let described = try await send(.updateVaultSecret(name: name, description: "rotated"), api)
        XCTAssertEqual(described.secret.description, "rotated")
        let renamed = try await send(.updateVaultSecret(name: name, newName: name + "-v2"), api)
        XCTAssertEqual(renamed.secret.name, name + "-v2")
        _ = try await send(.updateVaultSecret(name: name + "-v2", value: "sk-new-value"), api)
        await expectFailure(404, .updateVaultSecret(name: name, description: "gone"), api)
        let other = try await send(.createVaultSecret(name: name + "-other", kind: .opaque, value: "x"), api)
        XCTAssertNotEqual(other.secret.id, renamed.secret.id)
        await expectFailure(409, .updateVaultSecret(name: name + "-other", newName: name + "-v2"), api)
        // A typed entry refuses a value of the wrong shape.
        let login = try await send(.createVaultSecret(name: name + "-login", kind: .login, value: VaultItems.serialize(.login, ["username": "u", "password": "p"])), api)
        XCTAssertEqual(login.secret.kind, .login)
        await expectFailure(400, .updateVaultSecret(name: name + "-login", value: "not json"), api)

        // Grants.
        let key = try await send(.createAgentKey(name: unique("grantee")), api)
        let myKeys = try await AgentKeyDirectory.keys(rest: rest(token: token), userID: userID)
        let keyRow = try XCTUnwrap(myKeys.first { $0.keyPrefix == key.prefix })
        let agent = client(key.key)
        await expectFailure(404, Endpoint<JSONValue>(.get, "/api/secrets/\(name)-v2"), agent)   // ungranted looks like absent
        let grant = try await send(.grantSecret(name: name + "-v2", keyID: keyRow.id), api)
        XCTAssertEqual(grant.grant.apiKeyId, keyRow.id)
        XCTAssertNotNil(grant.grant.createdAt)
        let grants = try await send(.secretGrants(name: name + "-v2"), api)
        XCTAssertEqual(grants.grants.map(\.apiKeyId), [keyRow.id])
        let read = try await send(Endpoint<JSONValue>(.get, "/api/secrets/\(name)-v2", keys: .verbatim), agent)
        XCTAssertEqual(read["value"]?.string, "sk-new-value")
        // Server finding: the route means to stamp last_accessed_at on a read, but writes `void admin.from(...).update(...)`,
        // and a PostgREST builder only sends its request when awaited, so the stamp is never written.
        let stamped = try await send(.vaultSecrets, api)
        print("e2e vault last_accessed_at after a read: \(String(describing: stamped.secrets.first { $0.name == name + "-v2" }?.lastAccessedAt))")
        _ = try await send(.revokeSecretGrant(name: name + "-v2", keyID: keyRow.id), api)
        await expectFailure(404, Endpoint<JSONValue>(.get, "/api/secrets/\(name)-v2"), agent)
        await expectFailure(404, .grantSecret(name: name + "-v2", keyID: "00000000-0000-4000-8000-000000000000"), api)

        // Another person's secrets are not reachable.
        let (bob, _) = try second()
        await expectFailure(404, .secretGrants(name: name + "-v2"), bob)
        await expectFailure(404, .deleteVaultSecret(name: name + "-v2"), bob)

        for suffix in ["-v2", "-other", "-login"] { _ = try await send(.deleteVaultSecret(name: name + suffix), api) }
        await expectFailure(404, .deleteVaultSecret(name: name + "-v2"), api)
        let after = try await send(.vaultSecrets, api)
        XCTAssertNil(after.secrets.first { $0.name.hasPrefix(name) })
    }

    // MARK: Webhooks

    func testWebhooksCreateInspectDisableAndDelete() async throws {
        let (api, _) = member(17)
        let (empty, rawEmpty) = try await fetch(.webhooks, api)
        XCTAssertEqual(empty.webhooks.count, rawCount(rawEmpty, "webhooks"))
        XCTAssertEqual(Set(WebhookRules.knownEvents), Set(empty.events), "the Kit's list of events differs from the server's")
        XCTAssertNotNil(empty.signing?.signatureHeader)

        let target = "https://hooks.e2e.invalid/\(uniqueWord())"
        XCTAssertNil(WebhookRules.validate(url: target))
        let created = try await send(.createWebhook(url: target, name: "E2E hook", events: ["truth.challenged", "truth.upheld"], authors: ["grok", "gemini"]), api)
        XCTAssertFalse(created.secret.isEmpty, "the signing secret is shown once")
        XCTAssertEqual(created.webhook.url, target)
        XCTAssertEqual(created.webhook.name, "E2E hook")
        XCTAssertEqual(Set(created.webhook.events), ["truth.challenged", "truth.upheld"])
        XCTAssertEqual(Set(created.webhook.authors), ["grok", "gemini"])
        XCTAssertTrue(created.webhook.enabled)
        XCTAssertEqual(created.webhook.consecutiveFailures, 0)
        XCTAssertNil(created.webhook.lastDeliveredAt)

        let list = try await send(.webhooks, api)
        let row = try XCTUnwrap(list.webhooks.first { $0.id == created.webhook.id })
        XCTAssertEqual(row.url, target)
        XCTAssertFalse(String(describing: row).contains(created.secret))

        let detail = try await send(.webhookDetail(id: created.webhook.id), api)
        XCTAssertEqual(detail.webhook.id, created.webhook.id)
        XCTAssertTrue(detail.deliveries.isEmpty)

        let off = try await send(.setWebhookEnabled(id: created.webhook.id, enabled: false), api)
        XCTAssertFalse(off.webhook.enabled)
        let on = try await send(.setWebhookEnabled(id: created.webhook.id, enabled: true), api)
        XCTAssertTrue(on.webhook.enabled)

        // A ping to a name that does not resolve fails; the answer is a result, not an error.
        let ping = try await send(.testWebhook(id: created.webhook.id), api)
        XCTAssertFalse(ping.ok)
        XCTAssertFalse(ping.summary.isEmpty)

        // Targets the server will not call.
        for bad in ["http://127.0.0.1:9/hook", "http://169.254.169.254/latest", "http://localhost/x", "ftp://example.com/x", "https://10.0.0.1/x"] {
            let failure = await expectFailure(400, .createWebhook(url: bad), api)
            XCTAssertFalse(failure?.message.isEmpty ?? true, bad)
        }
        await expectFailure(400, .createWebhook(url: target, events: ["bogus.event"]), api)
        let (bob, _) = try second()
        await expectFailure(404, .webhookDetail(id: created.webhook.id), bob)
        await expectFailure(404, .deleteWebhook(id: created.webhook.id), bob)

        _ = try await send(.deleteWebhook(id: created.webhook.id), api)
        await expectFailure(404, .webhookDetail(id: created.webhook.id), api)
        let after = try await send(.webhooks, api)
        XCTAssertNil(after.webhooks.first { $0.id == created.webhook.id })
    }

    // MARK: Addresses

    func testClaimingAnAddressStylingItAndPointingItAtAPage() async throws {
        let fresh = try await freshMember("claimer")
        let api = fresh.client
        let userID = fresh.userID
        let rest = try rest(token: fresh.token)
        let caps = try await send(.capabilities, api)
        let domain = try XCTUnwrap(RealmRules.ordered(caps.domains).first { $0.available }, "no claimable base domain")
        let stem = "e2e" + String(uniqueWord().dropFirst(2).prefix(7))
        let name = stem + "a"
        XCTAssertEqual(try? RealmRules.validate(name).get(), name)

        // Availability needs no sign-in; a reserved name and a bad name are not available.
        let free = try await send(.claimAvailability(name: name, base: domain.domain), client(nil))
        XCTAssertTrue(free.available, "\(String(describing: free.reason))")
        let reserved = try await send(.claimAvailability(name: "admin", base: domain.domain), client(nil))
        XCTAssertFalse(reserved.available)
        XCTAssertFalse(reserved.reason?.isEmpty ?? true)
        XCTAssertNotNil(RealmRules.validate("admin").failureMessage)
        let before = try await rest.profile(userID: userID)
        XCTAssertEqual(before?.plan, "free")
        XCTAssertNil(before?.vanitySubdomain)

        // Claiming is what makes an account Pro.
        let claim = try await send(.claimRealm(name: name, base: domain.domain), api)
        XCTAssertEqual(claim.domain, "\(name).\(domain.domain)")
        XCTAssertEqual(claim.claimed, 1)
        XCTAssertEqual(claim.maxSubdomains, caps.limits.maxProSubdomains)
        XCTAssertNotNil(claim.message)
        let after = try await rest.profile(userID: userID)
        XCTAssertEqual(after?.plan, "pro")
        XCTAssertEqual(after?.vanitySubdomain, name, "the first claim is the primary address")
        let again = try await send(.claimRealm(name: name, base: domain.domain), api)
        XCTAssertEqual(again.claimed, 1, "claiming your own address again is not a second claim")

        let taken = try await send(.claimAvailability(name: name, base: domain.domain), client(nil))
        XCTAssertFalse(taken.available)
        let (bob, _) = try second()
        let sniped = await expectFailure(409, .claimRealm(name: name, base: domain.domain), bob)
        XCTAssertTrue(sniped?.message.contains("taken") ?? false)
        await expectFailure(400, .claimRealm(name: "admin", base: domain.domain), api)
        await expectFailure(400, .claimRealm(name: "ab", base: "not-a-domain.example"), api)

        // Read back through the Kit's two direct reads.
        let snapshot = try await RealmDirectory.snapshot(rest: rest, userID: userID)
        let mine = try XCTUnwrap(snapshot.claims.first { $0.subdomain == name })
        XCTAssertEqual(mine.baseDomain, domain.domain)
        XCTAssertEqual(mine.host, "\(name).\(domain.domain)")
        XCTAssertNotNil(mine.claimedAt)
        XCTAssertTrue(snapshot.isPro)
        XCTAssertNil(mine.defaultArtifactSlug)
        let tables = ArtifactTables(config: SupabaseConfig(url: try XCTUnwrap(env.supabaseURL), anonKey: try XCTUnwrap(env.anonKey)), tokens: LocalStaticToken(token: fresh.token))
        let realms = try await ArtifactRealmReader(tables: tables, userId: userID).realms()
        XCTAssertEqual(realms.first?.host, "\(name).\(domain.domain)")

        // Look and home page.
        let theme = try XCTUnwrap(caps.themes.first)
        let styled = try await send(.setRealmTheme(subdomain: name, base: domain.domain, theme: theme.id), api)
        XCTAssertEqual(styled.theme, theme.id)
        let page = try await send(.saveArtifact(ArtifactSaveRequest(content: "<!doctype html><html><body><h1>home \(name)</h1></body></html>", title: "Home \(name)", makePwa: false, visibility: .public)), api)
        let homed = try await send(.setRealmHome(subdomain: name, base: domain.domain, artifactSlug: page.slug), api)
        XCTAssertEqual(homed.defaultArtifact, page.slug)
        let claimsNow = try await RealmDirectory.claims(rest: rest, userID: userID, legacySubdomain: nil)
        XCTAssertEqual(claimsNow.first { $0.subdomain == name }?.defaultArtifactSlug, page.slug)
        XCTAssertEqual(claimsNow.first { $0.subdomain == name }?.theme, theme.id, "setting the home page changed the look")
        let options = try await RealmDirectory.homeOptions(rest: rest, userID: userID)
        XCTAssertTrue(options.contains { $0.slug == page.slug })
        XCTAssertEqual(options.first { $0.slug == page.slug }?.visibility, "public")
        let cleared = try await send(.setRealmHome(subdomain: name, baseDomain: domain.domain, slug: nil), api)
        XCTAssertNil(cleared.defaultArtifact)
        _ = try await send(.setRealmTheme(subdomain: name, base: domain.domain, theme: nil), api)
        let reset = try await RealmDirectory.claims(rest: rest, userID: userID, legacySubdomain: nil)
        XCTAssertNil(reset.first { $0.subdomain == name }?.theme)
        XCTAssertNil(reset.first { $0.subdomain == name }?.defaultArtifactSlug)
        await expectFailure(404, .setRealmTheme(subdomain: "nosuch\(stem)", base: domain.domain, theme: nil), api)
        await expectFailure(400, .setRealmTheme(subdomain: name, base: domain.domain, theme: "not-a-theme"), api)

        // The limit: the account holds up to maxProSubdomains addresses.
        let limit = caps.limits.maxProSubdomains
        for index in 2...limit {
            let claimed = try await send(.claimRealm(name: "\(stem)\(index)x", base: domain.domain), api)
            XCTAssertEqual(claimed.claimed, index)
        }
        let over = await expectFailure(403, .claimRealm(name: "\(stem)over", base: domain.domain), api)
        XCTAssertTrue(over?.message.contains("\(limit)") ?? false, over?.message ?? "")
    }

    // MARK: Dreams

    func testTheDreamQueueIsReviewedConnectionByConnection() async throws {
        let (api, token) = member(19)
        let userID = try await userId(of: token)
        let word = uniqueWord()
        let m1 = try await send(.memoryCreate(MemoryDraft(content: "Octopuses have three hearts \(word)", title: "Octopus \(word)")), api)
        let m2 = try await send(.memoryCreate(MemoryDraft(content: "Cephalopod anatomy is strange", title: "Cephalopods \(word)")), api)
        let m3 = try await send(.memoryCreate(MemoryDraft(content: "Cooking rice well takes patience", title: "Rice \(word)")), api)
        let page = try await send(.saveArtifact(ArtifactSaveRequest(content: "<p>\(word)</p>", title: "Reef \(word)", makePwa: false)), api)
        let pageID = try await send(.card(slug: page.slug), api).id

        let settings0 = try await send(.dreamSettings, api)
        let on = try await send(.setDreaming(enabled: true), api)
        XCTAssertTrue(on.enabled)
        let off = try await send(.setDreaming(enabled: false), api)
        XCTAssertFalse(off.enabled)
        _ = settings0

        // The nightly pass fills the queue; here the rows are arranged the way the pass writes them.
        let runRows = try await arrange("dream_runs", ["user_id": .string(userID)])
        let run = try XCTUnwrap(runRows.first)
        let runID = try XCTUnwrap(run["id"]?.string)
        let rows = try await arrange("dream_connections", [
            ["user_id": .string(userID), "run_id": .string(runID), "edge_type": "memory_memory", "a_id": .string(m1.id), "b_id": .string(m2.id), "score": 0.91, "reason": "both about cephalopods"],
            ["user_id": .string(userID), "run_id": .string(runID), "edge_type": "memory_memory", "a_id": .string(m2.id), "b_id": .string(m3.id), "score": 0.2, "reason": "weak"],
            ["user_id": .string(userID), "run_id": .string(runID), "edge_type": "memory_artifact", "a_id": .string(m1.id), "b_id": .string(pageID), "score": 0.7, "reason": "the reef page"],
        ])
        let ids = rows.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids.count, 3)

        let (queue, raw) = try await fetch(.dreamQueue, api)
        XCTAssertEqual(queue.runs.count, rawCount(raw, "runs"))
        XCTAssertEqual(queue.pendingCount, raw["pending_count"]?.int)
        XCTAssertEqual(queue.pendingCount, 3)
        let decoded = try XCTUnwrap(queue.runs.first { $0.id == runID })
        XCTAssertEqual(decoded.connections.count, 3)
        XCTAssertEqual(decoded.connections.map(\.score), decoded.connections.map(\.score).sorted(by: >), "best first")
        let best = try XCTUnwrap(decoded.connections.first)
        XCTAssertEqual(best.edgeType, .memoryMemory)
        XCTAssertEqual(best.a.label, "Octopus \(word)")
        XCTAssertEqual(best.b.label, "Cephalopods \(word)")
        XCTAssertEqual(best.reason, "both about cephalopods")
        let bridge = try XCTUnwrap(decoded.connections.first { $0.edgeType == .memoryArtifact })
        XCTAssertEqual(bridge.b.slug, page.slug)
        XCTAssertEqual(bridge.b.kind, .artifact)

        // Accept the best: the edge is in the graph. Reject one: it is not, and it is not asked again.
        let accepted = try await send(.dreamDecide(connection: best.id, .accept), api)
        XCTAssertEqual(accepted.accepted, 1)
        XCTAssertTrue(accepted.failures.isEmpty, "\(accepted.failures)")
        let graph = try await send(.memoryConnections, api)
        XCTAssertTrue(graph.memoryLinks.contains { Set([$0.aId, $0.bId]) == Set([m1.id, m2.id]) }, "the accepted dream is not in the memory graph")
        let rejected = try await send(.dreamDecide(connection: try XCTUnwrap(decoded.connections.last).id, .reject), api)
        XCTAssertEqual(rejected.rejected, 1)
        let rest = try await send(.dreamQueue, api)
        XCTAssertEqual(rest.pendingCount, 1)
        // The rest of the run at once.
        let all = try await send(.dreamDecide(run: runID, .accept), api)
        XCTAssertEqual(all.accepted, 1)
        let drained = try await send(.dreamQueue, api)
        XCTAssertEqual(drained.pendingCount, 0)
        XCTAssertTrue(drained.runs.isEmpty)
        let edges = try await send(.artifactEdges, api)
        XCTAssertTrue(edges.memoryArtifactLinks.contains { $0.memoryId == m1.id && $0.artifactId == pageID }, "the accepted bridge is missing")
        await expectFailure(404, .dreamDecide(connection: "00000000-0000-4000-8000-000000000000", .accept), api)

        // "Dream now" runs the whole pass; with too little to connect it says so.
        let ran = try await send(.dreamNow, api)
        XCTAssertFalse(ran.message.isEmpty)
        report("dreamNow", [("total", ran.total), ("foundNothing", ran.foundNothing ? 1 : 0)])
    }

    // MARK: Digest

    func testDigestSplitsALongMemoryAndTheQueueShowsIt() async throws {
        let (api, _) = member(19)
        let word = uniqueWord()
        let text = """
        # Gardening \(word)

        Tomatoes need full sun and a deep watering twice a week. Stake them early.

        # Cooking \(word)

        A good risotto takes patience: add the stock a ladle at a time and keep stirring.

        # Astronomy \(word)

        Jupiter's moons were first seen by Galileo in 1610 through a small telescope.
        """
        let memory = try await send(.memoryCreate(MemoryDraft(content: text, title: "Three topics \(word)")), api)
        let settings = try await send(.digestSettings, api)
        _ = settings
        let on = try await send(.setDigesting(enabled: true), api)
        XCTAssertTrue(on.enabled)
        _ = try await send(.setDigesting(enabled: false), api)

        let proposal = try await send(.digestMemory(id: memory.id), api)
        XCTAssertTrue(proposal.staged, "a memory with three headings should be split: \(proposal.message)")
        XCTAssertEqual(proposal.segmentCount, 3)
        let runID = try XCTUnwrap(proposal.runId)
        let (queue, raw) = try await fetch(.digestQueue, api)
        XCTAssertEqual(queue.runs.count, rawCount(raw, "runs"))
        let run = try XCTUnwrap(queue.runs.first { $0.id == runID })
        XCTAssertEqual(run.sourceMemoryId, memory.id)
        XCTAssertEqual(run.sourceTitle, "Three topics \(word)")
        XCTAssertEqual(run.segments.count, 3)
        XCTAssertEqual(run.segments.map(\.ordinal), [0, 1, 2])
        XCTAssertTrue(run.segments.map(\.title).contains { $0.contains("Cooking") })

        // Asking again while a proposal waits does not stack a second one.
        let again = try await send(.digestMemory(id: memory.id), api)
        let afterAgain = try await send(.digestQueue, api)
        XCTAssertEqual(afterAgain.runs.filter { $0.sourceMemoryId == memory.id }.count, 1, "two proposals for one memory: \(again.message)")
        let runID2 = afterAgain.runs.first { $0.sourceMemoryId == memory.id }?.id
        XCTAssertNotNil(runID2)

        let applied = try await send(.digestDecide(run: runID2 ?? runID, .accept), api)
        XCTAssertTrue(applied.applied, applied.status)
        XCTAssertEqual(applied.created, 3)
        let list = try await send(.memoryList(), api)
        XCTAssertTrue(list.memories.contains { $0.title.contains("Cooking") }, "the split memories are missing")
        let drained = try await send(.digestQueue, api)
        XCTAssertNil(drained.runs.first { $0.id == runID })

        // Keep a short memory whole.
        let short = try await send(.memoryCreate(MemoryDraft(content: "One short thought \(word).", title: "Short \(word)")), api)
        let none = try await send(.digestMemory(id: short.id), api)
        XCTAssertFalse(none.staged)
        XCTAssertFalse(none.message.isEmpty)
        let missing = try await send(.digestMemory(id: "00000000-0000-4000-8000-000000000000"), api)
        XCTAssertFalse(missing.staged, "a memory that does not exist was staged")
    }

    // MARK: Background jobs

    func testBackgroundJobsAreListedReadAndAcknowledged() async throws {
        let (api, token) = member(19)
        let userID = try await userId(of: token)
        let finishedRows = try await arrange("jobs", [
            "user_id": .string(userID), "kind": "artifact_repair", "status": "succeeded", "label": "Repairing a page",
            "result": ["changed": true, "message": "Fixed it."], "finished_at": .string(HVDate.format(Date())),
        ])
        let failedRows = try await arrange("jobs", [
            "user_id": .string(userID), "kind": "artifact_repair", "status": "failed", "label": "Repairing another", "error": "the model said no",
            "finished_at": .string(HVDate.format(Date())),
        ])
        let runningRows = try await arrange("jobs", ["user_id": .string(userID), "kind": "artifact_repair", "status": "running", "label": "Still going"])
        let finished = try XCTUnwrap(finishedRows.first)
        let failed = try XCTUnwrap(failedRows.first)
        let running = try XCTUnwrap(runningRows.first)
        let finishedID = try XCTUnwrap(finished["id"]?.string)
        let failedID = try XCTUnwrap(failed["id"]?.string)
        let runningID = try XCTUnwrap(running["id"]?.string)

        let (list, raw) = try await fetch(.backgroundJobs, api)
        XCTAssertEqual(list.jobs.count, rawCount(raw, "jobs"))
        XCTAssertTrue(list.jobs.contains { $0.id == finishedID })
        XCTAssertTrue(list.jobs.contains { $0.id == failedID })
        XCTAssertFalse(list.jobs.contains { $0.id == runningID }, "only finished jobs are announced")
        let ok = try XCTUnwrap(list.jobs.first { $0.id == finishedID })
        XCTAssertEqual(ok.status, .succeeded)
        XCTAssertEqual(ok.kind, "artifact_repair")
        XCTAssertEqual(ok.label, "Repairing a page")
        XCTAssertEqual(ok.result?["message"]?.string, "Fixed it.")
        XCTAssertNotNil(ok.finishedAt)
        XCTAssertNil(ok.acknowledgedAt)
        let bad = try XCTUnwrap(list.jobs.first { $0.id == failedID })
        XCTAssertEqual(bad.status, .failed)
        XCTAssertEqual(bad.error, "the model said no")
        XCTAssertNotNil(bad.outcomeMessage)

        let one = try await send(.backgroundJob(id: runningID), api)
        XCTAssertEqual(one.status, .running)
        XCTAssertFalse(one.isFinished)
        let artifactJob = try await send(.artifactJob(id: finishedID), api)
        XCTAssertEqual(artifactJob.status, .succeeded)
        XCTAssertEqual(artifactJob.result?.changed, true)
        XCTAssertEqual(artifactJob.result?.message, "Fixed it.")

        _ = try await send(.acknowledgeBackgroundJob(id: finishedID), api)
        _ = try await send(.acknowledgeArtifactJob(id: failedID), api)
        let after = try await send(.backgroundJobs, api)
        XCTAssertFalse(after.jobs.contains { $0.id == finishedID })
        XCTAssertFalse(after.jobs.contains { $0.id == failedID })
        await expectFailure(404, .backgroundJob(id: "00000000-0000-4000-8000-000000000000"), api)
        let (bob, _) = try second()
        await expectFailure(404, .backgroundJob(id: runningID), bob)

        // Repairing a page needs the person's own model; with none connected the server says so.
        let page = try await send(.saveArtifact(ArtifactSaveRequest(content: "<p>x</p>", title: "Repair me", makePwa: false, mutable: true)), api)
        let repair = await expectFailure(400, .repairArtifact(slug: page.slug, renderError: "boom"), api)
        report("repair without a backend", [("status", repair?.status ?? 0)])
    }
}

extension Result {
    var failureMessage: String? {
        if case .failure(let error) = self { return (error as? RealmRules.ValidationError)?.message ?? "\(error)" }
        return nil
    }
}
