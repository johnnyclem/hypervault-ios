import HyperVaultKit
import XCTest
@testable import HyperVault

/// Which canned worlds of the UI-test mode (App/Core/UITestWorld.swift) the Home connect card shows in: only the one
/// built for it. The first-run world and the signed-in worlds hold keys, so their journeys are not given a card to step
/// around.
@MainActor
final class ConnectCardWorldTests: XCTestCase {
    private let suite = "hv.test.connectcardworld.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func card(in scenario: UITestScenario) -> ConnectCardModel {
        let transport = MockTransport(routes: UITestWorld.routes(for: scenario))
        let tables = HVClient(baseURL: UITestWorld.supabaseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return ConnectCardModel(
            client: api, rest: AccountRest(client: tables, anonKey: UITestWorld.anonKey), userID: UITestWorld.user.id,
            defaults: UserDefaults(suiteName: suite) ?? .standard
        )
    }

    func testTheCardIsInTheWorldBuiltForItAndInNoOther() async {
        let wanted = card(in: .signedInNoKeys)
        await wanted.refresh()
        XCTAssertTrue(wanted.isVisible, "a person with no key, who has stamped nothing, is asked")

        for scenario in [UITestScenario.signedInEmpty, .signedIn, .signedInAdmin, .waitlisted] {
            let other = card(in: scenario)
            await other.refresh()
            XCTAssertFalse(other.isVisible, "\(scenario.rawValue) has keys, so it has no card")
        }
    }

    func testTheNoKeysWorldTakesTheDismissal() async throws {
        let transport = MockTransport(routes: UITestWorld.routes(for: .signedInNoKeys))
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let saved = try await api.send(.recordOnboarding(connectDismissed: true))
        XCTAssertEqual(saved.persisted, true)
    }
}
