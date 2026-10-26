import HyperVaultKit
import XCTest
@testable import HyperVault

/// What an entry's page knows about which agent keys may read it. A read that fails must not look like an
/// empty answer: a column of switches that all read off would tell the person no agent can read a card when
/// nobody knows.
@MainActor
final class VaultGrantsTests: XCTestCase {
    private func loadedModel(extra: [MockRoute]) async -> VaultItemsModel {
        let env = AppEnvironment.preview(routes: extra + VaultPreviewData.routes)
        let model = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id)
        await model.load()
        return model
    }

    func testAReadThatWorksListsTheAllowedKeys() async throws {
        let model = await loadedModel(extra: [])
        let secret = try XCTUnwrap(model.secret(named: "github.com"))

        let phase = await model.grantsPhase(for: secret)

        XCTAssertEqual(phase, .loaded(["k1"]))
        XCTAssertEqual(phase.granted, ["k1"])
        XCTAssertTrue(phase.isLoaded)
        XCTAssertFalse(phase.hasFailed)
    }

    func testANoneAllowedAnswerIsLoadedAndEmpty() async throws {
        let none = MockRoute.json(.get, "/api/secrets/visa-4242/grants", #"{"grants":[]}"#)
        let model = await loadedModel(extra: [none])
        let secret = try XCTUnwrap(model.secret(named: "visa-4242"))

        let phase = await model.grantsPhase(for: secret)

        XCTAssertEqual(phase, .loaded([]), "an empty list that the server sent is a real answer")
        XCTAssertTrue(phase.isLoaded)
    }

    func testAFailedReadIsNotAnEmptyList() async throws {
        let broken = MockRoute.failure(.get, "/api/secrets/visa-4242/grants", status: 500, message: "Internal Server Error")
        let model = await loadedModel(extra: [broken])
        let secret = try XCTUnwrap(model.secret(named: "visa-4242"))

        let phase = await model.grantsPhase(for: secret)

        XCTAssertEqual(phase, .failed)
        XCTAssertTrue(phase.hasFailed)
        XCTAssertFalse(phase.isLoaded, "the switches stay off the screen until there is something true to show")
        XCTAssertTrue(phase.granted.isEmpty)
    }

    func testARouteTheServerDoesNotHaveIsAFailureToo() async throws {
        // No grants route at all: the canned server answers 404 with a developer's sentence.
        let env = AppEnvironment.preview(routes: [.json(.get, "/api/secrets", VaultPreviewData.secretsJSON)])
        let model = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id)
        await model.load()
        let secret = try XCTUnwrap(model.secret(named: "home"))

        let phase = await model.grantsPhase(for: secret)

        XCTAssertEqual(phase, .failed)
    }

    func testEveryEntryInThePreviewHasItsOwnGrantsRoute() async throws {
        let model = await loadedModel(extra: [])
        for secret in model.secrets {
            let phase = await model.grantsPhase(for: secret)
            XCTAssertTrue(phase.isLoaded, "\(secret.name) would render a failed grants card in every snapshot")
        }
    }

    // MARK: A switch refused on its own

    func testASwitchSetsOnlyItself() {
        let start = VaultGrantsPhase.loaded(["a"])
        XCTAssertEqual(start.setting("b", to: true).granted, ["a", "b"])
        XCTAssertEqual(start.setting("a", to: false).granted, [])
        XCTAssertEqual(start.setting("a", to: true), start, "already on")
    }

    func testAFailedSwitchGoesBackWithoutUndoingOneTurnedAndAcceptedSince() {
        // Key A is turned on and its request is slow. Key B is turned on and accepted. Then A is refused.
        var phase = VaultGrantsPhase.loaded([])
        phase = phase.setting("a", to: true)
        phase = phase.setting("b", to: true)
        phase = phase.setting("a", to: false)
        XCTAssertEqual(phase.granted, ["b"], "the server holds B, and the switch must say so")
    }

    func testTwoFailuresInARowEachPutBackOnlyTheirOwnSwitch() {
        var phase = VaultGrantsPhase.loaded(["c"])
        phase = phase.setting("a", to: true)
        phase = phase.setting("b", to: true)
        phase = phase.setting("a", to: false)
        phase = phase.setting("b", to: false)
        XCTAssertEqual(phase.granted, ["c"], "A is not left on because B's snapshot had it on")
    }

    func testNothingIsSetWhileTheKeysAreLoadingOrWhenTheyFailedToLoad() {
        XCTAssertEqual(VaultGrantsPhase.loading.setting("a", to: true), .loading)
        XCTAssertEqual(VaultGrantsPhase.failed.setting("a", to: false), .failed)
    }
}
