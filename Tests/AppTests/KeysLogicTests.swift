import HyperVaultKit
import UIKit
import XCTest
@testable import HyperVault

/// Agent keys says only what the server states about a key, asks before it revokes, copies a key that was just
/// made the way a secret is copied, and sends a pairing to the website instead of answering it.
@MainActor
final class KeysLogicTests: XCTestCase {
    private func loadedModel(extra: [MockRoute] = []) async -> AgentsAndKeysModel {
        let env = AppEnvironment.preview(routes: extra + KeysPreviewData.routes)
        let model = AgentsAndKeysModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id)
        await model.load()
        return model
    }

    // MARK: What it says

    func testThePaneDescriptionIsTheDefaultOneAndClaimsNothing() {
        XCTAssertEqual(
            KeysCopy.paneDescription,
            "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."
        )
        XCTAssertFalse(KeysCopy.paneDescription.lowercased().contains("connected"))
    }

    func testAKeyIsKnownByItsFactsAndTheSlugOfItsChallengePage() async throws {
        let model = await loadedModel()
        XCTAssertEqual(model.keys.map(\.id), ["k1", "k2", "k3"])
        let first = try XCTUnwrap(model.keys.first)
        let last = try XCTUnwrap(model.keys.last)
        XCTAssertEqual(model.challengeSlug(of: first), "agent-setup-1")
        XCTAssertNil(model.challengeSlug(of: last), "a key with no challenge page has none to open")
    }

    // MARK: Revoking

    func testRevokingIsAskedInTheWebsWords() {
        XCTAssertEqual(KeysCopy.revoke, "Revoke")
        XCTAssertEqual(KeysCopy.reallyRevoke, "Really revoke?")
        XCTAssertEqual(KeysCopy.revoking, "Revoking...")
        XCTAssertEqual(
            KeysCopy.revokeMessage(for: AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL", name: "Claude Code")),
            "The agent using Claude Code stops working at once. This cannot be undone."
        )
        XCTAssertEqual(
            KeysCopy.revokeMessage(for: AgentKey(id: "k3", keyPrefix: "hv_Dd3Ee4Ff")),
            "The agent using hv_Dd3Ee4Ff\u{2026} stops working at once. This cannot be undone."
        )
    }

    func testAKeyGoesOnlyWhenTheServerAgreesToRevokeIt() async throws {
        let refusing = MockRoute.failure(.delete, "/api/keys", status: 404, message: "No such key.")
        let refused = await loadedModel(extra: [refusing])
        let key = try XCTUnwrap(refused.keys.first)
        do {
            try await refused.revoke(key)
            XCTFail("the server said no")
        } catch {}
        XCTAssertEqual(refused.keys.map(\.id), ["k1", "k2", "k3"], "a refused revoke leaves the key where it was")
        XCTAssertTrue(refused.revoking.isEmpty)

        let agreeing = MockRoute.json(.delete, "/api/keys", #"{"revoked":"k1"}"#)
        let agreed = await loadedModel(extra: [agreeing])
        try await agreed.revoke(try XCTUnwrap(agreed.keys.first))
        XCTAssertEqual(agreed.keys.map(\.id), ["k2", "k3"])
        XCTAssertNil(agreed.snapshot.challengeSlugs["k1"])
        XCTAssertTrue(agreed.revoking.isEmpty)
    }

    // MARK: The address a key mails as

    private static let claim = "11111111-1111-4111-8111-111111111111"

    /// A model over a transport the test can read the requests of.
    private func inspectedModel(keys: String = KeysPreviewData.keysJSON, routes: [MockRoute] = []) async -> (AgentsAndKeysModel, MockTransport) {
        let transport = MockTransport(routes: routes + [.json(.get, "/rest/v1/api_keys", keys), .json(.get, "/rest/v1/artifacts", KeysPreviewData.pagesJSON)])
        let client = HVClient(baseURL: URL(string: "https://t.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-keys-\(UUID().uuidString)"))
        let model = AgentsAndKeysModel(client: client, rest: AccountRest(client: client, anonKey: "preview"), cache: cache, userID: "u1")
        await model.load()
        return (model, transport)
    }

    private func sentBody(_ request: URLRequest) throws -> JSONValue {
        try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(request.httpBody))
    }

    func testPinningAKeySendsTheClaimAndTakesTheServersAnswer() async throws {
        let answer = #"{"key":{"id":"k1","scopes":["mail:read","mail:send"],"mail_claim_id":"\#(Self.claim)","mail_pin_cleared":false}}"#
        let (model, transport) = await inspectedModel(routes: [.json(.patch, "/api/keys", answer)])
        try await model.setMailAddress(try XCTUnwrap(model.keys.first), claimId: Self.claim)

        let pinned = try XCTUnwrap(model.keys.first)
        XCTAssertEqual(pinned.mailClaimId, Self.claim)
        XCTAssertFalse(pinned.mailPinCleared)
        XCTAssertTrue(pinned.canSendMail, "the address does not move the Can send mail switch")
        XCTAssertTrue(model.changing.isEmpty)
        let sent = await transport.requests(matching: "/api/keys")
        XCTAssertEqual(sent.map { $0.httpMethod }, ["PATCH"])
        XCTAssertEqual(try sentBody(sent[0]), ["id": "k1", "mail_claim_id": .string(Self.claim)])
    }

    func testPickingTheDefaultAddressAfterAReleaseSendsNullAndEndsTheWarning() async throws {
        let answer = #"{"key":{"id":"k1","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":false}}"#
        let (model, transport) = await inspectedModel(keys: KeysPreviewData.releasedKeysJSON, routes: [.json(.patch, "/api/keys", answer)])
        let released = try XCTUnwrap(model.keys.first)
        XCTAssertTrue(released.mailPinCleared)
        XCTAssertEqual(AgentKeyMailPin(key: released, mailboxes: []).selection, .choosing)

        try await model.setMailAddress(released, claimId: nil)

        let chosen = try XCTUnwrap(model.keys.first)
        XCTAssertNil(chosen.mailClaimId)
        XCTAssertFalse(chosen.mailPinCleared, "choosing again, even the default address, ends the released state")
        XCTAssertEqual(AgentKeyMailPin(key: chosen, mailboxes: []).selection, .defaultAddress)
        let sent = await transport.requests(matching: "/api/keys")
        XCTAssertEqual(try sentBody(sent[0]), ["id": "k1", "mail_claim_id": .null])
    }

    func testARefusedAddressPutsTheKeyBackAsItWas() async throws {
        let refusing = MockRoute.failure(.patch, "/api/keys", status: 404, message: "That address isn't one of yours.")
        let (model, _) = await inspectedModel(keys: KeysPreviewData.releasedKeysJSON, routes: [refusing])
        do {
            try await model.setMailAddress(try XCTUnwrap(model.keys.first), claimId: Self.claim)
            XCTFail("the server said no")
        } catch {
            XCTAssertEqual(keysMessage(for: error), "That address isn't one of yours.")
        }
        let key = try XCTUnwrap(model.keys.first)
        XCTAssertNil(key.mailClaimId)
        XCTAssertTrue(key.mailPinCleared, "the released address is still released")
        XCTAssertTrue(model.changing.isEmpty)
    }

    func testTheMailboxesAreReadWhenAKeyOpensAndAFailedReadKeepsWhatWasThere() async throws {
        let listing = MockRoute.json(.get, "/api/mail/owner/mailboxes", MailPreviewData.mailboxes)
        let (model, transport) = await inspectedModel(routes: [listing])
        XCTAssertTrue(model.mailboxes.isEmpty, "nothing is asked for until a key's screen opens")

        await model.loadMailboxes()
        XCTAssertEqual(model.mailboxes.compactMap(\.address), ["ana@vault.cool", "studio@vault.cool"])
        let key = try XCTUnwrap(model.keys.first)
        XCTAssertEqual(AgentKeyMailPin(key: key, mailboxes: model.mailboxes).choices.map(\.claimId), ["c1", "c2"])

        await transport.add(.failure(.get, "/api/mail/owner/mailboxes", status: 503, message: "Agent Mail is not set up on this server yet."))
        await model.loadMailboxes()
        XCTAssertEqual(model.mailboxes.count, 2, "a read that fails leaves the picker as it was")
    }

    // MARK: A key that was just made

    func testAKeyJustMadeStaysOnThisPhoneAndLeavesThePasteboardInAMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let options = KeysPasteboard.secretOptions(now: now)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(60))
    }

    func testAKeyJustMadeLivesOnlyInTheModelUntilTheSheetCloses() async throws {
        let env = AppEnvironment.preview(routes: ConnectPreviewData.routes)
        let model = ConnectAgentModel(client: env.client, cache: env.cache, origin: ServerOrigin.string(of: env.server.baseURL))
        model.keyName = "Cursor"
        await model.makeKey()

        let fresh = try XCTUnwrap(model.fresh)
        XCTAssertEqual(fresh.prefix, "hv_Zk3pQ9vL")
        XCTAssertEqual(fresh.challengeSlug, "agent-setup-ab12")
        XCTAssertTrue(model.hasUncopiedKey, "closing now would lose the key, so the sheet asks first")
        model.markCopied()
        XCTAssertFalse(model.hasUncopiedKey)

        model.wipe()
        XCTAssertNil(model.fresh)
        XCTAssertEqual(model.keyName, "")
        XCTAssertFalse(model.hasUncopiedKey)
    }

    // MARK: Pairing

    func testAPairLinkOpensTheWebsitePageInsteadOfAnsweringItInTheApp() {
        let router = AppRouter()
        router.open(.pair(code: "BCDF-2346"))
        XCTAssertEqual(router.sheet, .pair(code: "BCDF-2346"))
        XCTAssertEqual(router.tab, .you)
        XCTAssertEqual(router.sheet?.id, "pair-BCDF-2346")
    }
}
