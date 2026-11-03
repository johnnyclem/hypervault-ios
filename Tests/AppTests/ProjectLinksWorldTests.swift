import HyperVaultKit
import XCTest
@testable import HyperVault

/// The UI-test world with `-HV_UITEST_PROJECT_LINKS`: the Eurorack Choir Module project has things that go with it, and a launch
/// without the flag does not (the Library graph journey counts the canned pages and the links among them).
@MainActor
final class ProjectLinksWorldTests: XCTestCase {
    private func overview(projectLinks: Bool) async throws -> ProjectRelated {
        let env = AppEnvironment.preview(routes: UITestWorld.routes(for: .signedIn, projectLinks: projectLinks))
        let model = ProjectOverviewModel(env: env, project: "eurorack-choir")
        await model.start()
        guard case .loaded(let related) = model.related else {
            XCTFail("What goes with the project should have loaded.")
            return .empty
        }
        return related
    }

    func testWithTheFlagTheProjectHasPagesAMemoryAChatAndAGuess() async throws {
        let related = try await overview(projectLinks: true)
        XCTAssertEqual(related.pages.map(\.title), ["Bakery landing page", "Panel drawings"])
        XCTAssertEqual(related.pages.map(\.relation), [.linked, .tagged])
        XCTAssertEqual(related.memories.map(\.title), ["Auth decision: passkeys first"])
        XCTAssertEqual(related.memories.map(\.relation), [.linked])
        XCTAssertEqual(related.chats.map(\.title), ["Eurorack choir front panel quotes"])
        XCTAssertEqual(related.possibly.map(\.title), ["Trip to Lisbon"])
    }

    func testWithoutTheFlagNothingGoesWithTheProject() async throws {
        let related = try await overview(projectLinks: false)
        XCTAssertTrue(related.isEmpty)
    }

    func testTheFlagLeavesTheLibraryGraphsPagesAndEverythingElseAnswered() async throws {
        let routes = UITestWorld.routes(for: .signedIn, projectLinks: true)
        let env = AppEnvironment.preview(routes: routes)
        // A read of the table that is not the graph's is the covered route's: the home page options of an address.
        let options = try await env.keysRest.rows(
            LibraryGraphRow.self, from: "artifacts", query: [URLQueryItem(name: "select", value: "id,slug,title,type,visibility"), URLQueryItem(name: "type", value: "neq.group")]
        )
        XCTAssertEqual(options.map(\.slug), ["bakery-landing-page-x1", "trip-to-lisbon-q7"])
        // The chats are the canned ones with one more.
        let chats = try await env.client.send(.conversations)
        XCTAssertEqual(chats.first?.title, "Eurorack choir front panel quotes")
        XCTAssertTrue(chats.contains { $0.title == "Three days in Lisbon" })
    }
}
