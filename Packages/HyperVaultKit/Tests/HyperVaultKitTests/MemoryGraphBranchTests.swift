import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// A branch's own links on the memory map: the rows the graph builder takes, read from the branch's state
/// (`GET /api/mind/state`, shaped by app/api/mind/state/route.ts) instead of from `/api/connections`, which has main's.
final class MemoryGraphBranchTests: XCTestCase {
    private func state(memories: [String], links: String) throws -> MindState {
        let rows = memories.map { #"{"id":"\#($0)","title":"Memory \#($0)","summary":"s","tags":[],"source":"manual","committed_at":"2026-10-20T10:00:00Z"}"# }
        let json = #"{"at":"draft","commit_id":"c7","memories":[\#(rows.joined(separator: ","))],"links":\#(links),"message":""}"#
        return try HVCoding.decoder().decode(MindState.self, from: Data(json.utf8))
    }

    private func items(_ ids: [String]) -> [MemoryItem] {
        ids.map { MemoryItem(id: $0, title: "Memory \($0)") }
    }

    func testABranchsLinksBecomeEdgesBetweenTheMemoriesTheyName() throws {
        let draft = try state(
            memories: ["a", "b", "c"],
            links: #"[{"a_id":"a","b_id":"b","kind":"manual"},{"a_id":"c","b_id":"b","kind":"auto"}]"#
        )
        let rows = MemoryGraphBuilder.links(in: draft)
        XCTAssertEqual(rows.map(\.aId), ["a", "c"])
        XCTAssertEqual(rows.map(\.bId), ["b", "b"])
        XCTAssertEqual(rows.map(\.kind), [.manual, .auto])
        XCTAssertEqual(rows.map(\.id), ["a:b", "b:c"], "the row is named as the state names the pair, whichever way round it is written")

        let graph = MemoryGraphBuilder.build(memories: items(["a", "b", "c"]), links: rows)
        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(graph.neighbours(of: "b"), ["a", "c"])
        XCTAssertEqual(graph.neighbours(of: "a"), ["b"])
        XCTAssertEqual(graph.edges.first { $0.source == "a" }?.isManual, true, "a link made by hand stays strong")
        XCTAssertEqual(graph.edges.first { $0.source == "c" }?.isManual, false)
        XCTAssertEqual(graph.node("b")?.degree, 2)
    }

    func testALinkToAMemoryTheBranchDoesNotHoldIsLeftOut() throws {
        // "gone" is on main and linked there; this branch forgot it, and "b" was never on it.
        let draft = try state(
            memories: ["a", "c", "gone-on-main"],
            links: #"[{"a_id":"a","b_id":"b","kind":"auto"},{"a_id":"a","b_id":"c","kind":"auto"},{"a_id":"zzz","b_id":"c","kind":"manual"}]"#
        )
        XCTAssertEqual(MemoryGraphBuilder.links(in: draft).map(\.id), ["a:c"])

        // The list of the branch is what the map shows, and a link to something outside it is no edge either.
        let graph = MemoryGraphBuilder.build(memories: items(["a", "c"]), links: MemoryGraphBuilder.links(in: draft))
        XCTAssertEqual(graph.edges.map { [$0.source, $0.target] }, [["a", "c"]])
    }

    func testABranchWithNoLinksOrNoMemoriesHasNoEdges() throws {
        XCTAssertEqual(MemoryGraphBuilder.links(in: try state(memories: ["a", "b"], links: "[]")), [])
        // Links with nothing on the branch to hold them: all of them name something that is not there.
        XCTAssertEqual(MemoryGraphBuilder.links(in: try state(memories: [], links: #"[{"a_id":"a","b_id":"b","kind":"manual"}]"#)), [])
        let bare = try HVCoding.decoder().decode(MindState.self, from: Data("{}".utf8))
        XCTAssertEqual(MemoryGraphBuilder.links(in: bare), [])
        XCTAssertTrue(MemoryGraphBuilder.build(memories: items(["a", "b"]), links: MemoryGraphBuilder.links(in: bare)).edges.isEmpty)
    }

    func testAKindTheAppDoesNotKnowReadsAsFoundByHyperVault() throws {
        let draft = try state(memories: ["a", "b"], links: #"[{"a_id":"a","b_id":"b","kind":"semantic"},{"a_id":"b","b_id":"a"}]"#)
        XCTAssertEqual(MemoryGraphBuilder.links(in: draft).map(\.kind), [.auto, .auto])
        // The same pair written both ways is one edge, and the first row is the one that counts.
        let graph = MemoryGraphBuilder.build(memories: items(["a", "b"]), links: MemoryGraphBuilder.links(in: draft))
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testTheStateOfABranchIsAskedForAtItsHeadOnThatBranch() async throws {
        let json = #"{"at":"draft","commit_id":"c7","memories":[],"links":[],"message":""}"#
        let transport = MockTransport(routes: [.json(.get, "/api/mind/state", json)])
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        _ = try await api.send(.mindState(at: .branch("draft"), branch: "draft"))
        let sent = await transport.requests
        let url = try XCTUnwrap(sent.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/api/mind/state")
        XCTAssertEqual(query.first { $0.name == "at" }?.value, "draft")
        XCTAssertEqual(query.first { $0.name == "branch" }?.value, "draft")
    }
}
