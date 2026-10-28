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
