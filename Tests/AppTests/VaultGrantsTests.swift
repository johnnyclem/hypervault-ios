import HyperVaultKit
import XCTest
@testable import HyperVault

/// The allow switches of an entry (App/Features/Vault/VaultAllowedKeysModel.swift): a switch moves only when the server
/// agrees, a read that fails is not an empty answer, and the 404s of the grants routes never reach the person as
/// "No such grant.". The Kit classifies the HTTP results (`SecretGrantOutcome`); these tests are about what the model does
/// with them.
@MainActor
final class VaultGrantsTests: XCTestCase {
    private let github = "/api/secrets/github.com/grants"

    private func loaded(_ world: VaultWorld, name: String = "github.com") async -> VaultAllowedKeysModel {
        let model = world.allowedKeys()
        await model.load(name: name)
        return model
    }

    private let granted = MockRoute.json(.post, "/api/secrets/github.com/grants", #"{"grant":{"id":"g9","api_key_id":"k2","created_at":"2026-10-25T10:00:00Z"}}"#)
    private let revoked = MockRoute.json(.delete, "/api/secrets/github.com/grants", #"{"ok":true}"#)

    // MARK: Reading

    func testTheSwitchesAreTheActiveKeysAndTheOnesTheServerSaysMayRead() async {
        let world = VaultWorld()
        let model = await loaded(world)

        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.keys.map(\.id), ["k1", "k2", "k3"])
        XCTAssertTrue(model.isAllowed("k1"))
        XCTAssertFalse(model.isAllowed("k2"))
        XCTAssertFalse(model.isAllowed("k3"))
        XCTAssertNil(model.changeError)
        XCTAssertFalse(model.entryIsGone)
    }

    func testAGrantToAKeyRevokedSinceIsNotASwitch() async {
        // Revoking a key keeps its grant rows, so the list holds one for a key the person no longer sees.
        let world = VaultWorld(extra: [
            .json(.get, github, #"{"grants":[{"id":"g1","api_key_id":"k1"},{"id":"g7","api_key_id":"k-revoked"}]}"#),
        ])
        let model = await loaded(world)

        XCTAssertEqual(model.phase, .ready(keys: model.keys, allowed: ["k1"]))
        XCTAssertFalse(model.isAllowed("k-revoked"))
    }

    func testNoneAllowedIsAnAnswerOfItsOwn() async {
        let world = VaultWorld(extra: [.json(.get, github, #"{"grants":[]}"#)])
        let model = await loaded(world)

        XCTAssertTrue(model.isReady, "an empty list that the server sent is a real answer")
        XCTAssertFalse(model.keys.isEmpty)
        XCTAssertTrue(model.keys.allSatisfy { !model.isAllowed($0.id) })
    }

    func testNoKeysAtAllIsReadyAndEmptyAndOnlyThenTheNoKeysLineIsTrue() async {
        let world = VaultWorld(extra: [.json(.get, "/rest/v1/api_keys", "[]")])
        let model = await loaded(world)

        XCTAssertEqual(model.phase, .ready(keys: [], allowed: []))
    }

    func testAFailedGrantsReadIsNotAnEmptyList() async {
        let world = VaultWorld(extra: [.failure(.get, github, status: 500, message: "Internal Server Error")])
        let model = await loaded(world)

        guard case .failed(let message) = model.phase else { return XCTFail("expected a failed read, got \(model.phase)") }
        XCTAssertEqual(message, "Internal Server Error")
        XCTAssertFalse(model.isReady, "no switch is drawn for a state nobody confirmed")
        XCTAssertFalse(model.isAllowed("k1"))
        XCTAssertEqual(world.announcer.spoken, [message], "the error is said to VoiceOver")
    }

    func testAFailedKeysReadIsNotNoKeys() async {
        let world = VaultWorld(extra: [.failure(.get, "/rest/v1/api_keys", status: 502, message: "Bad gateway")])
        let model = await loaded(world)

        XCTAssertEqual(model.phase, .failed("Bad gateway"))
        XCTAssertTrue(model.keys.isEmpty)
    }

    func testAReadWithNoSignalSaysTheProductsLoadLine() async {
        let world = VaultWorld(wrapping: { _ in NoSignal() })
        let model = await loaded(world)

        XCTAssertEqual(model.phase, .failed(HVCopy.yoursOfflineLine))
    }

    func testTryAgainReadsAgainAndRecovers() async {
        let flaky = Sequenced([Sequenced.error("Bad gateway", status: 502), Sequenced.json(#"{"grants":[{"id":"g1","api_key_id":"k1"}]}"#)])
        let world = VaultWorld(extra: [flaky.route(.get, github)])
        let model = await loaded(world)
        XCTAssertFalse(model.isReady)

        await model.load(name: "github.com")

        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.isAllowed("k1"))
    }

    func testAGrantsReadThatAnswers404IsAnEntryThatIsGone() async {
        let world = VaultWorld(extra: [.failure(.get, github, status: 404, message: "No such secret.")])
        let model = await loaded(world)

        XCTAssertTrue(model.entryIsGone)
        XCTAssertNil(model.changeError, "'No such secret.' is never shown as a line")
        XCTAssertTrue(world.announcer.spoken.isEmpty)
    }

    func testEveryEntryInThePreviewHasItsOwnGrantsRoute() async {
        let world = VaultWorld()
        for name in ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"] {
            let model = await loaded(world, name: name)
            XCTAssertTrue(model.isReady, "\(name) would render a failed allowed-keys card in every snapshot")
        }
    }

    // MARK: A switch moves when the server agrees

    func testAnAllowIsNotShownUntilTheServerAnswers() async throws {
        var held: HeldWrites?
        let world = VaultWorld(extra: [granted], wrapping: { canned in
            let gate = HeldWrites(inner: canned)
            held = gate
            return gate
        })
        let gate = try XCTUnwrap(held)
        let model = await loaded(world)

        let tap = Task { await model.setAllowed(true, keyID: "k2", name: "github.com") }
        let onTheWire = await vaultEventually { await gate.held == 1 }
        XCTAssertTrue(onTheWire)

        XCTAssertTrue(model.isPending("k2"))
        XCTAssertFalse(model.isAllowed("k2"), "the thumb waits for the server")

        await gate.open()
        await tap.value

        XCTAssertFalse(model.isPending("k2"))
        XCTAssertTrue(model.isAllowed("k2"))
        XCTAssertNil(model.changeError)
        XCTAssertTrue(world.announcer.spoken.isEmpty, "a change that worked says nothing")
    }

    func testARevokeIsNotShownUntilTheServerAnswers() async throws {
        var held: HeldWrites?
        let world = VaultWorld(extra: [revoked], wrapping: { canned in
            let gate = HeldWrites(inner: canned)
            held = gate
            return gate
        })
        let gate = try XCTUnwrap(held)
        let model = await loaded(world)

        let tap = Task { await model.setAllowed(false, keyID: "k1", name: "github.com") }
        _ = await vaultEventually { await gate.held == 1 }
        XCTAssertTrue(model.isAllowed("k1"), "still on while the request is out")

        await gate.open()
        await tap.value

        XCTAssertFalse(model.isAllowed("k1"))
        XCTAssertFalse(model.isPending("k1"))
    }

    func testARefusedAllowLeavesTheSwitchWhereTheServerSaysAndSaysWhy() async {
        let world = VaultWorld(extra: [.failure(.post, github, status: 500, message: "The database is busy.")])
        let model = await loaded(world)

        await model.setAllowed(true, keyID: "k2", name: "github.com")

        XCTAssertFalse(model.isAllowed("k2"))
        XCTAssertFalse(model.isPending("k2"))
        XCTAssertEqual(model.changeError, "The database is busy.")
        XCTAssertEqual(world.announcer.spoken, ["The database is busy."])
    }

    func testARefusedRevokeLeavesTheSwitchOn() async {
        let world = VaultWorld(extra: [.failure(.delete, github, status: 503, message: "Try again in a moment.")])
        let model = await loaded(world)

        await model.setAllowed(false, keyID: "k1", name: "github.com")

        XCTAssertTrue(model.isAllowed("k1"))
        XCTAssertEqual(model.changeError, "Try again in a moment.")
    }

    func testAChangeWithNoSignalSaysTheProductsLine() async {
        let world = VaultWorld(wrapping: { OfflineWrites(inner: $0) })
        let model = await loaded(world)

        await model.setAllowed(true, keyID: "k2", name: "github.com")

        XCTAssertFalse(model.isAllowed("k2"))
        XCTAssertEqual(model.changeError, VaultCopy.keyChangeOfflineLine)
    }

    func testARevokeThatFindsNothingToRevokeEndsOffAndSaysNothing() async throws {
        // The first read has k1 on; the revoke answers 404 "No such grant." (a repeat that already went through, or a
        // switch drawn from stale state); reading again shows k1 off.
        let reads = Sequenced([
            Sequenced.json(#"{"grants":[{"id":"g1","api_key_id":"k1"}]}"#),
            Sequenced.json(#"{"grants":[]}"#),
        ])
        let world = VaultWorld(extra: [
            reads.route(.get, github),
            .failure(.delete, github, status: 404, message: "No such grant."),
        ])
        let model = await loaded(world)
        XCTAssertTrue(model.isAllowed("k1"))

        await model.setAllowed(false, keyID: "k1", name: "github.com")

        XCTAssertFalse(model.isAllowed("k1"), "off, as the server has it")
        XCTAssertNil(model.changeError)
        XCTAssertTrue(world.announcer.spoken.isEmpty)
        XCTAssertFalse(model.entryIsGone)
    }

    func testNoSuchGrantIsNeverShownWhateverTheStatus() async {
        // The same words on another status are not shown either.
        let world = VaultWorld(extra: [.failure(.delete, github, status: 500, message: "No such grant.")])
        let model = await loaded(world)

        await model.setAllowed(false, keyID: "k1", name: "github.com")

        XCTAssertEqual(model.changeError, VaultCopy.keyChangeFailedLine)
        XCTAssertFalse((model.changeError ?? "").lowercased().contains("grant"))
    }

    func testAnAllowForAKeyThatIsGoneReadsTheKeysAgain() async {
        let world = VaultWorld(extra: [.failure(.post, github, status: 404, message: "No such API key.")])
        let model = await loaded(world)
        let before = await world.transport.requests(matching: "/rest/v1/api_keys").count

        await model.setAllowed(true, keyID: "k2", name: "github.com")

        let after = await world.transport.requests(matching: "/rest/v1/api_keys").count
        XCTAssertEqual(after, before + 1, "the key list is read again")
        XCTAssertFalse(model.isAllowed("k2"))
        XCTAssertNil(model.changeError)
        XCTAssertTrue(model.isReady)
    }

    func testAChangeToAnEntryThatIsGoneClosesIt() async {
        let world = VaultWorld(extra: [
            .failure(.post, github, status: 404, message: "No such secret."),
        ])
        let model = await loaded(world)
        // The entry was deleted after the page opened: reading its grants again is a 404 too.
        await world.transport.add(.failure(.get, github, status: 404, message: "No such secret."))

        await model.setAllowed(true, keyID: "k2", name: "github.com")

        XCTAssertTrue(model.entryIsGone)
        XCTAssertNil(model.changeError)
        XCTAssertTrue(world.announcer.spoken.isEmpty)
    }

    func testNothingIsSentBeforeTheReadsHaveAnswered() async {
        let world = VaultWorld(extra: [granted])
        let model = world.allowedKeys()

        await model.setAllowed(true, keyID: "k2", name: "github.com")

        let seen = await world.seen()
        XCTAssertFalse(seen.contains("POST \(github)"))
        XCTAssertFalse(model.isAllowed("k2"))
    }

    func testASecondTapOnAKeyThatIsPendingDoesNothing() async throws {
        var held: HeldWrites?
        let world = VaultWorld(extra: [granted], wrapping: { canned in
            let gate = HeldWrites(inner: canned)
            held = gate
            return gate
        })
        let gate = try XCTUnwrap(held)
        let model = await loaded(world)

        let first = Task { await model.setAllowed(true, keyID: "k2", name: "github.com") }
        _ = await vaultEventually { await gate.held == 1 }
        await model.setAllowed(true, keyID: "k2", name: "github.com")
        await gate.open()
        await first.value

        let posts = await world.seen().filter { $0 == "POST \(github)" }
        XCTAssertEqual(posts.count, 1)
    }

    func testTwoKeysChangeIndependently() async throws {
        var held: HeldWrites?
        let world = VaultWorld(extra: [granted, revoked], wrapping: { canned in
            let gate = HeldWrites(inner: canned)
            held = gate
            return gate
        })
        let gate = try XCTUnwrap(held)
        let model = await loaded(world)

        let allow = Task { await model.setAllowed(true, keyID: "k2", name: "github.com") }
        let revoke = Task { await model.setAllowed(false, keyID: "k1", name: "github.com") }
        _ = await vaultEventually { await gate.held == 2 }
        XCTAssertTrue(model.isPending("k1") && model.isPending("k2"))

        await gate.open()
        await allow.value
        await revoke.value

        XCTAssertTrue(model.isAllowed("k2"))
        XCTAssertFalse(model.isAllowed("k1"))
    }

    // MARK: A read and a change in the same moment

    /// A loaded model on a server whose reads of the entry's grants can be held after they are served (see `HeldReads`).
    private func worldWithHeldReads(
        extra: [MockRoute]
    ) async throws -> (world: VaultWorld, model: VaultAllowedKeysModel, gate: HeldReads) {
        let path = github
        var held: HeldReads?
        let world = VaultWorld(extra: extra, wrapping: { canned in
            let gate = HeldReads(inner: canned, path: path)
            held = gate
            return gate
        })
        let gate = try XCTUnwrap(held)
        return (world, await loaded(world), gate)
    }

    func testAReadSentBeforeAChangeDoesNotTakeItBackWhenItAnswersAfter() async throws {
        // The reload read the grants while k2 was off. k2 is then allowed and the server agrees, and only then does the
        // reload's answer arrive: it still says k2 is off.
        let (_, model, gate) = try await worldWithHeldReads(extra: [granted])
        XCTAssertFalse(model.isAllowed("k2"))

        await gate.hold()
        let reload = Task { await model.load(name: "github.com", quietly: true) }
        let sent = await vaultEventually { await gate.held == 1 }
        XCTAssertTrue(sent)

        await model.setAllowed(true, keyID: "k2", name: "github.com")
        XCTAssertTrue(model.isAllowed("k2"))

        await gate.open()
        await reload.value

        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.isAllowed("k2"), "the answer was read before the allow and does not undo it")
        XCTAssertTrue(model.isAllowed("k1"), "what it says of the key nobody touched is taken")
    }

    func testAReadSentBeforeARevokeDoesNotTurnTheSwitchBackOnButStillBringsInANewKey() async throws {
        let (world, model, gate) = try await worldWithHeldReads(extra: [revoked])
        XCTAssertTrue(model.isAllowed("k1"))
        // A key made since (on the Connect an agent screen) is in the list the reload reads.
        await world.transport.add(.json(.get, "/rest/v1/api_keys", """
        [{"id":"k4","key_prefix":"hv_Gg7Hh8Ii","name":"Made later","created_at":"2026-10-26T10:00:00Z","last_used_at":null,"scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false},
         {"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"Claude Code","created_at":"2026-10-20T10:00:00Z","last_used_at":null,"scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false}]
        """))

        await gate.hold()
        let reload = Task { await model.load(name: "github.com", quietly: true) }
        let sent = await vaultEventually { await gate.held == 1 }
        XCTAssertTrue(sent)

        await model.setAllowed(false, keyID: "k1", name: "github.com")
        XCTAssertFalse(model.isAllowed("k1"))

        await gate.open()
        await reload.value

        XCTAssertEqual(Set(model.keys.map(\.id)), ["k1", "k4"], "the new key is taken from the answer")
        XCTAssertFalse(model.isAllowed("k1"), "the answer still lists k1 as allowed, which was true before the revoke")
        XCTAssertFalse(model.isAllowed("k4"))
    }

    func testAReadSentAfterAChangeWasAnsweredIsTakenAsItIs() async {
        // Nothing is newer than the read, so the server's word stands (here: a revoke made on another device).
        let reads = Sequenced([
            Sequenced.json(#"{"grants":[{"id":"g1","api_key_id":"k1"}]}"#),
            Sequenced.json(#"{"grants":[]}"#),
        ])
        let world = VaultWorld(extra: [reads.route(.get, github), granted])
        let model = await loaded(world)
        await model.setAllowed(true, keyID: "k2", name: "github.com")
        XCTAssertTrue(model.isAllowed("k2"))

        await model.load(name: "github.com", quietly: true)

        XCTAssertFalse(model.isAllowed("k1"))
        XCTAssertFalse(model.isAllowed("k2"), "the read began after the allow and says it is off: the server's word")
    }

    // MARK: The label

    func testASwitchIsNamedByItsPrefixFirstAndItsNameUnlessItIsDefault() {
        let named = AgentKey(id: "k1", keyPrefix: "hv_Zk3pQ9vL", name: "Claude Code")
        let unnamed = AgentKey(id: "k3", keyPrefix: "hv_Dd3Ee4Ff", name: "default")
        let paired = AgentKey(id: "k2", keyPrefix: "hv_Aa1Bb2Cc", name: "Paired: Cursor on Sam's Mac")

        XCTAssertEqual(named.allowSwitchLabel, "hv_Zk3pQ9vL\u{2026}, Claude Code")
        XCTAssertEqual(unnamed.allowSwitchLabel, "hv_Dd3Ee4Ff\u{2026}")
        XCTAssertEqual(paired.allowSwitchLabel, "hv_Aa1Bb2Cc\u{2026}, Paired: Cursor on Sam's Mac")
    }
}
