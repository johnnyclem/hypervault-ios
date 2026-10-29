import HyperVaultKit
import XCTest
@testable import HyperVault

/// Where the Memory map gets its links: main's from `/api/connections`, another branch's own from that branch's state
/// (`/api/mind/state`), and main's again, said plainly, when the state cannot be read.
@MainActor
final class MemoryGraphModelTests: XCTestCase {
    private let items = ["a", "b", "c"].map { MemoryItem(id: $0, title: $0.uppercased()) }

    /// Main's links are a-b and b-c, and the memory "a" is bridged to a page. The pages are not kept per branch.
    private let connections = #"""
    {"connections":[],
     "memory_links":[
       {"id":"l1","a_id":"a","b_id":"b","kind":"auto"},
       {"id":"l2","a_id":"b","b_id":"c","kind":"auto"}],
     "memory_artifact_links":[{"id":"k1","memory_id":"a","artifact_id":"art1","kind":"auto"}]}
    """#

    private let yours = #"""
    {"recent":[],"results":[{"id":"art1","kind":"page","name":"Trip plan","summary":"","href":"/a/trip-plan"}]}
    """#

    /// What `GET /api/mind/state` answers for each branch's head: the memories it holds and the links between them.
    private func state(commit: String, links: String) -> String {
        let memories = ["a", "b", "c"].map { #"{"id":"\#($0)","title":"\#($0.uppercased())","summary":"s","tags":[],"source":"manual","committed_at":"2026-10-20T10:00:00Z"}"# }
        return #"{"at":"x","commit_id":"\#(commit)","memories":[\#(memories.joined(separator: ","))],"links":\#(links),"message":""}"#
    }

    /// The state route, answering by the branch asked for in `at`; a branch it does not know is a 404.
    private func stateRoute() -> MockRoute {
        let heads: [String: String] = [
            "draft": state(commit: "c1", links: #"[{"a_id":"a","b_id":"c","kind":"manual"}]"#),
            "ideas": state(commit: "c2", links: #"[{"a_id":"c","b_id":"b","kind":"auto"}]"#),
        ]
        return MockRoute(.get, "/api/mind/state") { request in
            let at = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "at" }?.value
            if let at, let body = heads[at] {
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(body.utf8))
            }
            return HTTPResponse(status: 404, headers: ["content-type": "application/json"], data: Data(#"{"error":"No such branch."}"#.utf8))
        }
    }

    private var routes: [MockRoute] {
        [
            .json(.get, "/api/connections", connections),
            .json(.get, "/api/yours", yours),
            stateRoute(),
        ]
    }

    private func environment(_ transport: HTTPTransport) -> AppEnvironment {
        let server = ServerConfig(baseURL: URL(string: "https://t.test")!)
        let client = HVClient(baseURL: server.baseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://s.test")!, anonKey: "k"),
            transport: transport, store: InMemorySecureStore()
        )
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-graph-\(UUID().uuidString)"))
        return AppEnvironment(
            client: client, auth: auth, capabilities: Capabilities(),
            user: AuthUser(id: "u1", email: "sam@example.com", displayName: nil), server: server, cache: cache
        )
    }

    /// The edges of the map, each as its two ends in order: "a-b".
    private func pairs(_ graph: MemoryGraph) -> [String] {
        graph.edges.map { [$0.source, $0.target].sorted().joined(separator: "-") }.sorted()
    }

    private func requests(_ transport: MockTransport, to path: String) async -> [URLRequest] {
        await transport.requests.filter { $0.url?.path == path }
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Never happened: \(what)", file: file, line: line)
    }

    // MARK: Main

    func testMainKeepsItsLinksFromTheConnectionsAndNeverAsksForAState() async {
        let transport = MockTransport(routes: routes)
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "main")

        XCTAssertEqual(model.linkSource, .main)
        XCTAssertNil(model.linkNote)
        XCTAssertFalse(model.isReadingLinks)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "a-b", "b-c"])
        let states = await requests(transport, to: "/api/mind/state")
        XCTAssertTrue(states.isEmpty, "main has no other source to ask")
    }

    // MARK: Another branch

    func testAnotherBranchBuildsItsEdgesFromItsOwnStateNotFromMains() async throws {
        let transport = MockTransport(routes: routes)
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "draft")

        XCTAssertEqual(model.linkSource, .branch)
        XCTAssertNil(model.linkNote, "these are the branch's own links, and the caption does not call them main's")
        XCTAssertFalse(model.isReadingLinks)
        let graph = model.graph(for: items)
        XCTAssertEqual(pairs(graph), ["a-art1", "a-c"], "draft links a and c; main's a-b and b-c are not drawn")
        XCTAssertEqual(graph.edges.first { $0.source == "a" && $0.target == "c" }?.isManual, true)
        XCTAssertEqual(graph.node("a")?.degree, 2)
        XCTAssertEqual(graph.node("b")?.degree, 0)

        // It asked for the state of the branch at its head, on that branch.
        let states = await requests(transport, to: "/api/mind/state")
        XCTAssertEqual(states.count, 1)
        let sent = try XCTUnwrap(states.first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(query(sent, "at"), "draft")
        XCTAssertEqual(query(sent, "branch"), "draft")
        // The connections still carry the pages the memories are bridged to (a page is not kept per branch), and only those.
        let connected = await requests(transport, to: "/api/connections")
        XCTAssertEqual(connected.count, 1)
        XCTAssertEqual(model.artifacts.map(\.title), ["Trip plan"])
    }

    func testTheMapIsNotDrawnFromMainsLinksWhileTheBranchsAreOnTheirWay() async {
        let mock = MockTransport(routes: routes)
        let hold = RequestHold()
        await hold.arm()
        let transport = HeldTransport(base: mock, hold: hold, holds: { $0.url?.path == "/api/mind/state" })
        let model = MemoryGraphModel(env: environment(transport))

        let run = Task { await model.load(branch: "draft") }
        await eventually("the state of the branch to be on its way") { await hold.waiting == 1 }
        XCTAssertEqual(model.linkSource, .reading)
        XCTAssertTrue(model.isReadingLinks, "the screen waits rather than draw the wrong map")
        XCTAssertFalse(pairs(model.graph(for: items)).contains("a-b"), "main's links are not the branch's")
        XCTAssertNil(model.linkNote)

        await hold.release()
        await run.value
        XCTAssertEqual(model.linkSource, .branch)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "a-c"])
    }

    func testSwitchingBranchesReadsTheNewBranchAndForgetsTheOldOnesLinks() async {
        let transport = MockTransport(routes: routes)
        let model = MemoryGraphModel(env: environment(transport))

        await model.load(branch: "draft")
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "a-c"])

        await model.load(branch: "ideas")
        XCTAssertEqual(model.linkSource, .branch)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "b-c"], "ideas links b and c; draft's a-c is gone")

        await model.load(branch: "main")
        XCTAssertEqual(model.linkSource, .main)
        XCTAssertTrue(model.branchLinks.isEmpty)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "a-b", "b-c"])

        let states = await requests(transport, to: "/api/mind/state")
        XCTAssertEqual(states.compactMap { query($0, "at") }, ["draft", "ideas"], "each branch was asked for by its own name, and main not at all")
    }

    func testABranchWithNoLinksOfItsOwnHasNoneEvenThoughMainHas() async {
        let bare = state(commit: "c3", links: "[]")
        let transport = MockTransport(routes: [.json(.get, "/api/mind/state", bare)] + routes)
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "draft")
        XCTAssertEqual(model.linkSource, .branch)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1"], "only the page is left")
    }

    // MARK: When the branch's state cannot be read

    func testWhenTheStateCannotBeReadMainsLinksStandInAndTheCaptionSaysSo() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/mind/state", status: 500, message: "Could not read the mind.")] + routes)
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "draft")

        XCTAssertEqual(model.linkSource, .mainInstead)
        XCTAssertFalse(model.isReadingLinks)
        XCTAssertEqual(pairs(model.graph(for: items)), ["a-art1", "a-b", "b-c"])
        XCTAssertEqual(model.linkNote, "this branch's links could not be read, so these are main's")
    }

    func testABranchThatNoLongerExistsFallsBackToMainsLinksToo() async {
        let transport = MockTransport(routes: routes)
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "deleted-elsewhere")
        XCTAssertEqual(model.linkSource, .mainInstead)
        XCTAssertEqual(model.linkNote, MemoryGraphModel.mainInsteadNote)
    }

    func testWithNeitherReadTheCaptionDoesNotClaimMainsLinks() async {
        let transport = MockTransport(routes: [
            .failure(.get, "/api/mind/state", status: 500, message: "Could not read the mind."),
            .failure(.get, "/api/connections", status: 500, message: "Could not list your connections."),
        ])
        let model = MemoryGraphModel(env: environment(transport))
        await model.load(branch: "draft")

        XCTAssertEqual(model.linkSource, .mainInstead)
        XCTAssertTrue(pairs(model.graph(for: items)).isEmpty)
        XCTAssertEqual(model.linkNote, "this branch's links could not be read", "there are no links of main's to say these are")
    }
}
