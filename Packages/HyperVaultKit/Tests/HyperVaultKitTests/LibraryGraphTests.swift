import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The Library's Files graph: pages beside memories, the three kinds of link among them, the type filter, hide-unlinked,
/// the cap and the search, in the order the web's `vault-graph.tsx` applies them.
final class LibraryGraphTests: XCTestCase {
    private let base = URL(string: "https://proj.supabase.test")!

    private func page(_ id: String, _ type: String = "html") -> LibraryGraphPage {
        LibraryGraphPage(id: id, slug: "slug-\(id)", title: "Page \(id)", type: type)
    }

    private func memory(_ id: String) -> MemoryItem {
        MemoryItem(id: id, title: "Memory \(id)")
    }

    private func edge(_ a: String, _ b: String, _ kind: String = "manual") -> ArtifactEdge {
        ArtifactEdge(id: "\(a)-\(b)", aId: a, bId: b, kind: kind)
    }

    // MARK: Nodes and edges

    func testAVaultOfPagesWithNoMemoriesStillHasAMap() {
        let graph = LibraryGraphBuilder.build(pages: [page("a"), page("b"), page("c")], memories: [], pageLinks: [edge("a", "b")])
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(graph.edges, [LibraryGraph.Edge(source: "a", target: "b", isManual: true)])
        XCTAssertEqual(graph.node("a")?.degree, 1)
        XCTAssertEqual(graph.node("c")?.degree, 0, "a page nothing links to is still drawn")
        XCTAssertEqual(graph.node("a")?.slug, "slug-a", "a page opens by its slug, which is not what its connections name it by")
        XCTAssertEqual(graph.total, 3)
        XCTAssertFalse(graph.isCapped)
    }

    func testPagesComeBeforeMemoriesAndEveryKindOfLinkJoinsThem() {
        let graph = LibraryGraphBuilder.build(
            pages: [page("a"), page("b")], memories: [memory("m1"), memory("m2")],
            pageLinks: [edge("a", "b")],
            memoryLinks: [MemoryLinkRow(id: "l1", aId: "m1", bId: "m2", kind: .manual)],
            bridges: [MemoryBridgeRow(id: "br", memoryId: "m1", artifactId: "a", kind: .auto)]
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b", "m1", "m2"])
        XCTAssertEqual(graph.nodes.map(\.kind), [.page, .page, .memory, .memory])
        XCTAssertEqual(graph.nodes.map(\.type), ["html", "html", "memory", "memory"])
        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertEqual(graph.node("a")?.degree, 2)
        XCTAssertEqual(graph.node("m1")?.degree, 2)
        XCTAssertNil(graph.node("m1")?.slug)
    }

    func testOnlyRealEdgesAreKeptAndAPairIsKeptOnceWithTheHandMadeOneWinning() {
        let graph = LibraryGraphBuilder.build(
            pages: [page("a"), page("b"), page("c")], memories: [],
            pageLinks: [
                edge("b", "a", "auto"),      // a found link first...
                edge("a", "b", "manual"),    // ...and the same pair made by hand
                edge("c", "c"),              // a loop
                edge("a", "gone"),           // a page that is not drawn
            ]
        )
        XCTAssertEqual(graph.edges, [LibraryGraph.Edge(source: "a", target: "b", isManual: true)])
    }

    // MARK: Types

    func testTheChipsListEveryTypeByHowManyWhateverIsHidden() {
        let pages = [page("a"), page("b"), page("c", "react"), page("d", "markdown"), page("e", "markdown"), page("f", "markdown")]
        let graph = LibraryGraphBuilder.build(pages: pages, memories: [memory("m")], hiddenTypes: ["markdown"])
        XCTAssertEqual(
            graph.types,
            [
                LibraryGraphType(name: "markdown", count: 3), LibraryGraphType(name: "html", count: 2),
                LibraryGraphType(name: "react", count: 1), LibraryGraphType(name: "memory", count: 1),
            ],
            "the most common first, the memories last, and a hidden type still listed so it can be shown again"
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b", "c", "m"])
        XCTAssertEqual(graph.total, 7)
    }

    func testHidingATypeTakesItsNodesAndTheirEdgesOut() {
        let graph = LibraryGraphBuilder.build(
            pages: [page("a"), page("b", "react")], memories: [memory("m")],
            pageLinks: [edge("a", "b")], bridges: [MemoryBridgeRow(id: "br", memoryId: "m", artifactId: "a", kind: .manual)],
            hiddenTypes: ["react"]
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "m"])
        XCTAssertEqual(graph.edges.map { [$0.source, $0.target] }, [["m", "a"]])
    }

    func testMemoriesCanBeHiddenAsATypeAndTypeNamesAreNotCaseSensitive() {
        let graph = LibraryGraphBuilder.build(pages: [page("a", "HTML")], memories: [memory("m")], hiddenTypes: ["Memory"])
        XCTAssertEqual(graph.nodes.map(\.id), ["a"])
        let none = LibraryGraphBuilder.build(pages: [page("a", "HTML")], memories: [memory("m")], hiddenTypes: ["html"])
        XCTAssertEqual(none.nodes.map(\.id), ["m"])
    }

    // MARK: Unlinked

    func testHidingTheUnlinkedKeepsOnlyWhatHasALink() {
        let graph = LibraryGraphBuilder.build(
            pages: [page("a"), page("b"), page("c")], memories: [memory("m")], pageLinks: [edge("a", "b")], hideUnlinked: true
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(graph.total, 4)
        XCTAssertEqual(graph.eligible, 2)
        XCTAssertFalse(graph.isCapped, "a page left out because it is unlinked is not left out for want of room")
    }

    func testAPageWhoseOnlyNeighbourIsAHiddenTypeCountsAsUnlinked() {
        let graph = LibraryGraphBuilder.build(
            pages: [page("a"), page("b", "react"), page("c"), page("d")], memories: [],
            pageLinks: [edge("a", "b"), edge("c", "d")], hiddenTypes: ["react"], hideUnlinked: true
        )
        XCTAssertEqual(graph.nodes.map(\.id), ["c", "d"], "the type filter comes first, as on the web")
    }

    func testNothingLinkedLeavesAnEmptyGraphThatKnowsWhatItHolds() {
        let graph = LibraryGraphBuilder.build(pages: [page("a")], memories: [memory("m")], hideUnlinked: true)
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertEqual(graph.total, 2)
        XCTAssertEqual(graph.types.map(\.name), ["html", "memory"])
    }

    // MARK: The cap

    func testPastTheCapTheBestConnectedStayAndTheNewestWinATie() {
        let pages = (0..<6).map { page("p\($0)") }
        // p0 is the newest; p3 and p4 are the hubs.
        let links = [edge("p3", "p4"), edge("p3", "p5"), edge("p4", "p5"), edge("p3", "p1")]
        let graph = LibraryGraphBuilder.build(pages: pages, memories: [], pageLinks: links, cap: 4)
        XCTAssertEqual(graph.nodes.map(\.id), ["p1", "p3", "p4", "p5"])
        XCTAssertEqual(graph.eligible, 6)
        XCTAssertTrue(graph.isCapped)
        XCTAssertEqual(graph.node("p3")?.degree, 3, "degrees are those of the graph as drawn")
        XCTAssertEqual(graph.edges.count, 4)
        let tied = LibraryGraphBuilder.build(pages: pages, memories: [], cap: 2)
        XCTAssertEqual(tied.nodes.map(\.id), ["p0", "p1"], "with no links the newest are kept")
    }

    func testANodeKeptForItsLinksWhoseNeighboursWereCutIsUnlinkedToo() {
        // a, b and c are the hubs (two links each); x has one link, to the oldest page, which the cap cuts.
        let pages = [page("x"), page("a"), page("b"), page("c"), page("old")]
        let links = [edge("a", "b"), edge("b", "c"), edge("a", "c"), edge("x", "old")]
        let capped = LibraryGraphBuilder.build(pages: pages, memories: [], pageLinks: links, cap: 4)
        XCTAssertEqual(capped.nodes.map(\.id), ["x", "a", "b", "c"], "x and old tie on one link, and the newest wins")
        XCTAssertEqual(capped.node("x")?.degree, 0)
        let hidden = LibraryGraphBuilder.build(pages: pages, memories: [], pageLinks: links, hideUnlinked: true, cap: 4)
        XCTAssertEqual(hidden.nodes.map(\.id), ["a", "b", "c"], "with unlinked hidden it does not sit on the map with no link")
        XCTAssertTrue(hidden.isCapped)
    }

    func testTheDefaultCapIs150AndANegativeCapDrawsNothing() {
        XCTAssertEqual(LibraryGraphBuilder.defaultCap, 150)
        let pages = (0..<200).map { page("p\($0)") }
        XCTAssertEqual(LibraryGraphBuilder.build(pages: pages, memories: []).nodes.count, 150)
        XCTAssertTrue(LibraryGraphBuilder.build(pages: pages, memories: [], cap: -3).nodes.isEmpty)
    }

    func testAnIdThatCameTwiceIsOneNode() {
        let graph = LibraryGraphBuilder.build(pages: [page("a"), page("a")], memories: [])
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.total, 1)
    }

    // MARK: Search

    func testSearchFindsANodeByPartOfItsNameTheBestConnectedFirst() {
        let pages = [
            LibraryGraphPage(id: "a", slug: "a", title: "Lisbon trip plan"),
            LibraryGraphPage(id: "b", slug: "b", title: "Bakery landing page"),
            LibraryGraphPage(id: "c", slug: "c", title: "Trip budget"),
        ]
        let graph = LibraryGraphBuilder.build(
            pages: pages, memories: [MemoryItem(id: "m", title: "Passports for the TRIP")], pageLinks: [edge("c", "b")]
        )
        XCTAssertEqual(graph.matches("trip").map(\.id), ["c", "a", "m"])
        XCTAssertEqual(graph.matches("  BAKERY ").map(\.id), ["b"])
        XCTAssertEqual(graph.matches("trip", limit: 1).map(\.id), ["c"])
        XCTAssertTrue(graph.matches("   ").isEmpty)
        XCTAssertTrue(graph.matches("zebra").isEmpty)
    }

    // MARK: Reading what the server sends

    func testAllThreeKindsOfEdgeAreReadFromOneConnectionsAnswer() async throws {
        let json = #"""
        {"connections":[{"id":"c1","a_id":"p1","b_id":"p2","kind":"auto","created_at":"2026-10-01T00:00:00Z"}],
         "memory_links":[{"id":"l1","a_id":"m1","b_id":"m2","kind":"manual","created_at":"2026-10-01T00:00:00Z"}],
         "memory_artifact_links":[{"id":"b1","memory_id":"m1","artifact_id":"p1","kind":"auto","created_at":"2026-10-01T00:00:00Z"}]}
        """#
        let transport = MockTransport(routes: [.json(.get, "/api/connections", json)])
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let all = try await client.send(.libraryConnections)
        XCTAssertEqual(all.pageLinks.map(\.aId), ["p1"])
        XCTAssertTrue(all.pageLinks[0].isAuto)
        XCTAssertEqual(all.memoryLinks.map(\.bId), ["m2"])
        XCTAssertEqual(all.bridges.map(\.artifactId), ["p1"])
        let empty = try HVCoding.decoder().decode(LibraryConnections.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, LibraryConnections())
    }

    func testThePagesAreReadFromTheTableWithTheirRowIdsAndTheSystemsOwnAreLeftOut() async throws {
        let json = #"""
        [{"id":"r1","slug":"bakery-x1","title":"Bakery landing page","type":"html","tags":["shop"],"is_jsx":false},
         {"id":"r2","slug":"timer-x2","title":"Pomodoro Timer","type":"html","tags":[],"is_jsx":true},
         {"id":"r3","slug":"setup-x3","title":"Agent setup","type":"html","tags":["agent-setup-challenge"],"is_jsx":false},
         {"id":"r4","slug":"board-x4","title":"Balcony garden","type":"html","tags":["tasklist"],"is_jsx":false},
         {"id":"r5","slug":"scan-x5","title":"","type":"PDF","tags":null,"is_jsx":null}]
        """#
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/artifacts", json)])
        let rest = AccountRest(client: HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
        let read = try await LibraryGraphRow.pages(rest: rest, userID: "u1")
        let pages = read.pages
        XCTAssertFalse(read.isTruncated)
        XCTAssertEqual(pages.map(\.id), ["r1", "r2", "r5"], "the setup challenge and a task board's data are pages the system keeps for itself")
        XCTAssertEqual(pages.map(\.type), ["html", "react", "pdf"], "a component is a react page whatever type it was stored as")
        XCTAssertEqual(pages.map(\.slug), ["bakery-x1", "timer-x2", "scan-x5"])
        XCTAssertEqual(pages[2].title, "Untitled")
        let sent = await transport.requests
        let items = URLComponents(url: try XCTUnwrap(sent.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "user_id" }?.value, "eq.u1")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "neq.group", "groups are not nodes")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "301", "one row more than the map keeps, to know whether it cut any")
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "select" }?.value).hasPrefix("id,slug"))
    }

    func testADatabaseWithoutTheTagColumnsStillGivesThePages() async throws {
        let asked = AskCount()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/rest/v1/artifacts") { _ in
                if asked.next() == 1 {
                    return HTTPResponse(status: 400, headers: ["content-type": "application/json"], data: Data(#"{"message":"column artifacts.is_jsx does not exist"}"#.utf8))
                }
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"[{"id":"r1","slug":"s1","title":"Kept","type":"html"}]"#.utf8))
            },
        ])
        let rest = AccountRest(client: HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
        let read = try await LibraryGraphRow.pages(rest: rest, userID: "u1")
        XCTAssertEqual(read.pages, [LibraryGraphPage(id: "r1", slug: "s1", title: "Kept", type: "html")])
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 2, "asked again without the columns that were missing")
        let second = URLComponents(url: try XCTUnwrap(sent.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(second.first { $0.name == "select" }?.value, "id,slug,title,type")
    }

    func testMorePagesThanTheMapKeepsAreSaidSoAndTheNewestAreKept() async throws {
        let rows = (0...LibraryGraphRow.limit).map { #"{"id":"r\#($0)","slug":"s\#($0)","title":"T\#($0)","type":"html"}"# }
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/artifacts", "[" + rows.joined(separator: ",") + "]")])
        let rest = AccountRest(client: HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
        let read = try await LibraryGraphRow.pages(rest: rest, userID: "u1")
        XCTAssertTrue(read.isTruncated)
        XCTAssertEqual(read.pages.count, LibraryGraphRow.limit)
        XCTAssertEqual(read.pages.first?.id, "r0")
        XCTAssertEqual(read.pages.last?.id, "r299", "the extra row, the oldest, is the one left out")
    }

    func testAGroupOrAPageTheSystemKeepsIsNotAPage() {
        XCTAssertNil(LibraryGraphRow(id: "g", slug: "g", type: "group").page)
        XCTAssertNil(LibraryGraphRow(id: "s", slug: "s", tags: ["agent-setup-challenge"]).page)
        XCTAssertNil(LibraryGraphRow(id: "t", slug: "t", tags: ["tasklist"]).page)
        XCTAssertEqual(LibraryGraphRow(id: "p", slug: "p", type: "HTML", isJsx: true).page?.type, "react")
    }
}

/// A count a mock route can keep between its answers.
private final class AskCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
