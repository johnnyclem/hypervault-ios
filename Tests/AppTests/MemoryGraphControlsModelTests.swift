import HyperVaultKit
import Observation
import XCTest
@testable import HyperVault

/// What an observation reported, in order. (The report is made from a closure that may run anywhere, so what it writes to is a class.)
private final class ChangeLog: @unchecked Sendable {
    private(set) var names: [String] = []

    func note(_ name: String) { names.append(name) }
}

/// What the Memory map lets a person set: the kinds of node left off, the nodes with no links left out, and a memory found by
/// part of its name. The model holds the settings and gives back the map they make; the pieces of logic under it are tested
/// in the Kit (`MemoryGraphControlsTests`).
@MainActor
final class MemoryGraphControlsModelTests: XCTestCase {
    /// m1 and m2 are the person's own, m3 came from a chat, m4 from a coding agent, and m5 has no links.
    private let items = [
        MemoryItem(id: "m1", title: "Trip to Lisbon", source: "manual"),
        MemoryItem(id: "m2", title: "Caf\u{E9} notes", source: "manual"),
        MemoryItem(id: "m3", title: "Planning chat", source: "chat"),
        MemoryItem(id: "m4", title: "Auth decision", source: "coding"),
        MemoryItem(id: "m5", title: "Loose end", source: "manual"),
    ]

    /// m1-m2, m2-m3 and m3-m4 are linked, and m1 is bridged to the page art1.
    private let connections = #"""
    {"connections":[],
     "memory_links":[
       {"id":"l1","a_id":"m1","b_id":"m2","kind":"manual"},
       {"id":"l2","a_id":"m2","b_id":"m3","kind":"auto"},
       {"id":"l3","a_id":"m3","b_id":"m4","kind":"auto"}],
     "memory_artifact_links":[{"id":"k1","memory_id":"m1","artifact_id":"art1","kind":"auto"}]}
    """#

    private let yours = #"""
    {"recent":[],"results":[{"id":"art1","kind":"page","name":"Trip plan","summary":"","href":"/a/trip-plan"}]}
    """#

    private var routes: [MockRoute] {
        [.json(.get, "/api/connections", connections), .json(.get, "/api/yours", yours)]
    }

    private func environment(_ transport: HTTPTransport) -> AppEnvironment {
        let server = ServerConfig(baseURL: URL(string: "https://t.test")!)
        let client = HVClient(baseURL: server.baseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://s.test")!, anonKey: "k"),
            transport: transport, store: InMemorySecureStore()
        )
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-graph-controls-\(UUID().uuidString)"))
        return AppEnvironment(
            client: client, auth: auth, capabilities: Capabilities(),
            user: AuthUser(id: "u1", email: "sam@example.com", displayName: nil), server: server, cache: cache
        )
    }

    /// A model that has read the canned connections on main.
    private func loadedModel() async -> MemoryGraphModel {
        let model = MemoryGraphModel(env: environment(MockTransport(routes: routes)))
        await model.load(branch: "main")
        return model
    }

    private func ids(_ graph: MemoryGraph) -> [String] { graph.nodes.map(\.id) }

    // MARK: Starting out

    func testTheMapStartsWithEverythingOnItAndNothingTyped() async {
        let model = await loadedModel()
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.hiddenTypes.isEmpty)
        XCTAssertFalse(model.hideUnlinked)
        let graph = model.graph(for: items)
        XCTAssertEqual(ids(graph), ["m1", "m2", "m3", "m4", "m5", "art1"])
        XCTAssertEqual(graph.types.map(\.name), ["You", "Chat", "Coding", "Page"])
        XCTAssertEqual(graph.types.map(\.count), [3, 1, 1, 1])
        XCTAssertTrue(model.matches(in: graph).isEmpty, "nothing is typed, so nothing is found")
    }

    // MARK: Leaving a type off

    func testLeavingATypeOffTakesItsNodesOffTheMapAndPuttingItBackBringsThemBack() async {
        let model = await loadedModel()
        model.toggle(type: "Chat")
        XCTAssertEqual(model.hiddenTypes, ["Chat"])
        let without = model.graph(for: items)
        XCTAssertEqual(ids(without), ["m1", "m2", "m4", "m5", "art1"])
        XCTAssertEqual(without.types.map(\.name), ["You", "Chat", "Coding", "Page"], "the pill stays, so it can be tapped again")

        model.toggle(type: "Chat")
        XCTAssertTrue(model.hiddenTypes.isEmpty)
        XCTAssertEqual(ids(model.graph(for: items)), ["m1", "m2", "m3", "m4", "m5", "art1"])
    }

    func testPagesCanBeLeftOffToo() async {
        let model = await loadedModel()
        model.toggle(type: "Page")
        let graph = model.graph(for: items)
        XCTAssertNil(graph.node("art1"))
        XCTAssertEqual(graph.edges.count, 3, "the three links between memories")
    }

    func testSeveralTypesCanBeOffAtOnce() async {
        let model = await loadedModel()
        model.toggle(type: "You")
        model.toggle(type: "Page")
        XCTAssertEqual(ids(model.graph(for: items)), ["m3", "m4"])
        model.toggle(type: "You")
        XCTAssertEqual(model.hiddenTypes, ["Page"])
    }

    // MARK: Leaving out what has no links

    func testHideUnlinkedLeavesOutAMemoryThatHasNoLinks() async {
        let model = await loadedModel()
        model.setHideUnlinked(true)
        XCTAssertTrue(model.hideUnlinked)
        XCTAssertEqual(ids(model.graph(for: items)), ["m1", "m2", "m3", "m4", "art1"])
        model.setHideUnlinked(false)
        XCTAssertEqual(ids(model.graph(for: items)).count, 6)
    }

    func testAMemoryWhoseOnlyNeighbourIsOffTheMapCountsAsUnlinked() async {
        let model = await loadedModel()
        model.toggle(type: "Chat")
        model.setHideUnlinked(true)
        // m4 was linked to m3 alone, and m3 is off the map; m5 never had a link.
        XCTAssertEqual(ids(model.graph(for: items)), ["m1", "m2", "art1"])
    }

    func testWhenTheControlsLeaveNothingTheMapIsEmptyAndTheTypesAreStillOffered() async {
        let model = await loadedModel()
        for type in ["You", "Chat", "Coding", "Page"] { model.toggle(type: type) }
        let graph = model.graph(for: items)
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertEqual(graph.types.count, 4)
        XCTAssertEqual(graph.memoryTotal, 5)
    }

    // MARK: Show everything

    func testShowEverythingPutsBackWhatWasLeftOffAndOutButKeepsWhatWasTyped() async {
        let model = await loadedModel()
        model.toggle(type: "You")
        model.toggle(type: "Page")
        model.setHideUnlinked(true)
        model.query = "planning"
        model.showEverything()
        XCTAssertTrue(model.hiddenTypes.isEmpty)
        XCTAssertFalse(model.hideUnlinked)
        XCTAssertEqual(model.query, "planning", "the search is a different thing from what is shown")
        XCTAssertEqual(ids(model.graph(for: items)).count, 6)
    }

    // MARK: Finding a memory

    func testTheSearchFindsPartOfANameWhateverTheCapitalsOrAccents() async {
        let model = await loadedModel()
        let graph = model.graph(for: items)
        model.query = "LISBON"
        XCTAssertEqual(model.matches(in: graph).map(\.id), ["m1"])
        model.query = "cafe"
        XCTAssertEqual(model.matches(in: graph).map(\.id), ["m2"], "an accent is not in the way")
        model.query = "  planning "
        XCTAssertEqual(model.matches(in: graph).map(\.id), ["m3"], "nor are spaces round it")
        model.query = "zzz"
        XCTAssertTrue(model.matches(in: graph).isEmpty)
        model.query = ""
        XCTAssertTrue(model.matches(in: graph).isEmpty)
    }

    func testTheBestConnectedMatchComesFirst() async {
        let model = await loadedModel()
        let graph = model.graph(for: items)
        // The memory is linked to a memory and to the page (two), the page to the memory (one).
        model.query = "trip"
        XCTAssertEqual(model.matches(in: graph).map(\.id), ["m1", "art1"])
        // m2 has two links, m3 two, m1 two; "n" is in all three titles, and the ones with equal links keep the map's order.
        model.query = "n"
        XCTAssertEqual(Array(model.matches(in: graph).map(\.id).prefix(3)), ["m1", "m2", "m3"])
    }

    func testTheSearchSeesOnlyWhatIsOnTheMap() async {
        let model = await loadedModel()
        model.query = "loose"
        XCTAssertEqual(model.matches(in: model.graph(for: items)).map(\.id), ["m5"])
        model.setHideUnlinked(true)
        XCTAssertTrue(model.matches(in: model.graph(for: items)).isEmpty, "m5 is off the map")
        model.setHideUnlinked(false)
        model.query = "trip"
        model.toggle(type: "You")
        XCTAssertTrue(model.matches(in: model.graph(for: items)).isEmpty, "m1 is off, and the page with it")
    }

    func testTheSearchCannotSeeAMemoryPastTheCapAndTheMapSaysSo() async {
        let model = await loadedModel()
        // A cap of 3 keeps the three best connected of the six: m1, m2 and m3, with two links each.
        let graph = model.graph(for: items, cap: 3)
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertTrue(graph.isCapped)
        XCTAssertEqual(graph.eligible, 6)
        model.query = "auth"
        XCTAssertTrue(model.matches(in: graph).isEmpty, "m4 is past the cap, so a search for it finds nothing")
    }

    func testTheSearchListsNoMoreThanItsLimit() async {
        let model = await loadedModel()
        let many = (0..<20).map { MemoryItem(id: "n\($0)", title: "Note \($0)") }
        let graph = model.graph(for: many)
        model.query = "note"
        XCTAssertEqual(MemoryGraphModel.matchLimit, 6)
        XCTAssertEqual(model.matches(in: graph).count, MemoryGraphModel.matchLimit)
    }

    // MARK: Being watched

    /// The screen reads all of this through `graph(for:)` and `matches(in:)`, so a change must reach whoever read them.
    func testEachSettingIsSeenByWhoeverIsDrawingTheMap() async {
        let model = await loadedModel()
        let graph = model.graph(for: items)

        let log = ChangeLog()
        func watch(_ name: String, _ read: () -> Void) {
            withObservationTracking {
                read()
            } onChange: {
                log.note(name)
            }
        }
        watch("hiddenTypes") { _ = model.graph(for: items) }
        model.toggle(type: "Chat")
        watch("hideUnlinked") { _ = model.graph(for: items) }
        model.setHideUnlinked(true)
        watch("query") { _ = model.matches(in: graph) }
        model.query = "trip"
        XCTAssertEqual(log.names, ["hiddenTypes", "hideUnlinked", "query"])
    }

    // MARK: When the links cannot be read

    func testLinksAreUnavailableOnlyWhenTheyCouldNotBeRead() async {
        let healthy = await loadedModel()
        XCTAssertFalse(healthy.linksUnavailable)

        let broken = MemoryGraphModel(env: environment(MockTransport(routes: [
            .failure(.get, "/api/connections", status: 500, message: "Could not list your connections."),
        ])))
        await broken.load(branch: "main")
        XCTAssertTrue(broken.linksUnavailable)
        XCTAssertTrue(broken.graph(for: items).edges.isEmpty)

        // A branch has links of its own, read from its state, so main's route failing takes none of them away.
        let state = #"{"at":"x","commit_id":"c1","memories":[{"id":"m1","title":"Trip","summary":"s","tags":[],"source":"manual","committed_at":"2026-10-20T10:00:00Z"},{"id":"m2","title":"Cafe","summary":"s","tags":[],"source":"manual","committed_at":"2026-10-20T10:00:00Z"}],"links":[{"a_id":"m1","b_id":"m2","kind":"manual"}],"message":""}"#
        let onBranch = MemoryGraphModel(env: environment(MockTransport(routes: [
            .failure(.get, "/api/connections", status: 500, message: "Could not list your connections."),
            .json(.get, "/api/mind/state", state),
        ])))
        await onBranch.load(branch: "draft")
        XCTAssertEqual(onBranch.linkSource, .branch)
        XCTAssertFalse(onBranch.linksUnavailable)
        XCTAssertEqual(onBranch.graph(for: items).edges.count, 1)

        // And a branch whose state could not be read either has none.
        let neither = MemoryGraphModel(env: environment(MockTransport(routes: [
            .failure(.get, "/api/connections", status: 500, message: "Could not list your connections."),
            .failure(.get, "/api/mind/state", status: 500, message: "Could not read the mind."),
        ])))
        await neither.load(branch: "draft")
        XCTAssertTrue(neither.linksUnavailable)
    }
}
