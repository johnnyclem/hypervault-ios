import XCTest
@testable import HyperVaultKit

/// What the Memory map lets a person leave out and find: a type of node (where a memory came from, or "Page"), the nodes
/// with no links, and a memory by part of its name.
final class MemoryGraphControlsTests: XCTestCase {
    /// m1 and m2 are the person's own, m3 came from a chat, m4 from a file and m5 from a repository.
    /// Links: m1-m2, m2-m3, m4-m5 (so m3 reaches m1 only through m2). m1 and m3 are bridged to pages p1 and p2.
    private let memories = [
        MemoryItem(id: "m1", title: "Trip to Lisbon", source: "manual"),
        MemoryItem(id: "m2", title: "Passport checklist", source: "manual"),
        MemoryItem(id: "m3", title: "Planning chat", source: "chat"),
        MemoryItem(id: "m4", title: "Quarterly report", source: "file"),
        MemoryItem(id: "m5", title: "owner/hypervault-ios", source: "github"),
        MemoryItem(id: "m6", title: "Lonely note", source: "manual"),
    ]
    private let links = [
        MemoryLinkRow(id: "l1", aId: "m1", bId: "m2", kind: .manual),
        MemoryLinkRow(id: "l2", aId: "m2", bId: "m3"),
        MemoryLinkRow(id: "l3", aId: "m4", bId: "m5"),
    ]
    private let bridges = [
        MemoryBridgeRow(id: "b1", memoryId: "m1", artifactId: "p1"),
        MemoryBridgeRow(id: "b2", memoryId: "m3", artifactId: "p2"),
    ]
    private let artifacts = [
        MemoryGraphArtifact(id: "p1", title: "Lisbon plan", slug: "lisbon-plan"),
        MemoryGraphArtifact(id: "p2", title: "Roadmap", slug: "roadmap"),
    ]

    private func build(hideUnlinked: Bool = false, hidden: Set<String> = [], cap: Int = MemoryGraphBuilder.defaultCap) -> MemoryGraph {
        MemoryGraphBuilder.build(
            memories: memories, links: links, bridges: bridges, artifacts: artifacts,
            cap: cap, hideUnlinked: hideUnlinked, hiddenTypes: hidden
        )
    }

    private func ids(_ graph: MemoryGraph) -> [String] { graph.nodes.map(\.id) }

    // MARK: Types

    func testTheTypesAreTheSourcesByHowManyMemoriesHaveThemAndThenPage() {
        let graph = build()
        // "You" has three, then the single ones by name, then the pages.
        XCTAssertEqual(graph.types.map(\.name), ["You", "Chat", "File", "Repository", "Page"])
        XCTAssertEqual(graph.types.map(\.count), [3, 1, 1, 1, 2])
        XCTAssertEqual(graph.types.map(\.id), graph.types.map(\.name))
    }

    func testEachNodeCarriesTheTypeTheChipForItIsCalled() {
        let graph = build()
        XCTAssertEqual(graph.node("m1")?.type, "You")
        XCTAssertEqual(graph.node("m3")?.type, "Chat")
        XCTAssertEqual(graph.node("m5")?.type, "Repository")
        XCTAssertEqual(graph.node("p1")?.type, MemoryGraphType.page)
        XCTAssertEqual(MemoryGraphType.page, "Page")
    }

    func testSourcesThatReadTheSameShareAChipAndAnUnknownOneIsCapitalised() {
        let mixed = [
            MemoryItem(id: "a", title: "A", source: "manual"),
            MemoryItem(id: "b", title: "B", source: ""),
            MemoryItem(id: "c", title: "C", source: "zapier"),
        ]
        let graph = MemoryGraphBuilder.build(memories: mixed, links: [])
        XCTAssertEqual(graph.types, [MemoryGraphType(name: "You", count: 2), MemoryGraphType(name: "Zapier", count: 1)])
    }

    func testThereIsNoPageChipWithoutAPageAndNoneForABridgeFromAMemoryThatIsNotThere() {
        let none = MemoryGraphBuilder.build(memories: memories, links: links)
        XCTAssertFalse(none.types.contains { $0.name == MemoryGraphType.page })
        let stray = MemoryGraphBuilder.build(memories: memories, links: links, bridges: [MemoryBridgeRow(id: "x", memoryId: "gone", artifactId: "p9")])
        XCTAssertFalse(stray.types.contains { $0.name == MemoryGraphType.page })
        XCTAssertNil(stray.node("p9"))
    }

    func testAPageBridgedFromTwoMemoriesCountsOnce() {
        let twice = bridges + [MemoryBridgeRow(id: "b3", memoryId: "m2", artifactId: "p1")]
        let graph = MemoryGraphBuilder.build(memories: memories, links: links, bridges: twice, artifacts: artifacts)
        XCTAssertEqual(graph.types.last, MemoryGraphType(name: "Page", count: 2))
        XCTAssertEqual(graph.nodes.filter { $0.kind == .artifact }.count, 2)
        XCTAssertEqual(graph.node("p1")?.degree, 2)
    }

    func testTheChipsAreTheSameWhateverIsHidden() {
        let all = build().types
        XCTAssertEqual(build(hidden: ["You", "Page"]).types, all)
        XCTAssertEqual(build(hideUnlinked: true, hidden: ["Chat"]).types, all)
        XCTAssertEqual(build(cap: 2).types, all)
    }

    // MARK: Hiding a type

    func testHidingATypeTakesItsMemoriesAndTheirLinksOffTheMap() {
        let graph = build(hidden: ["You"])
        XCTAssertEqual(ids(graph), ["m3", "m4", "m5", "p2"])
        XCTAssertEqual(graph.edges.count, 2, "m4-m5 and m3-p2 are left; the links to m1 and m2 went with them")
        XCTAssertEqual(graph.node("m3")?.degree, 1)
        XCTAssertEqual(graph.memoryTotal, 6, "the total is of the memories, whatever is hidden")
    }

    func testAPageGoesWhenTheOnlyMemoryThatPointsAtItIsHidden() {
        let graph = build(hidden: ["Chat"])
        XCTAssertNil(graph.node("p2"), "m3 was the only one bridged to the Roadmap")
        XCTAssertNotNil(graph.node("p1"), "m1 still points at the Lisbon plan")
    }

    func testHidingPageLeavesTheMemoriesAndTheirLinks() {
        let graph = build(hidden: ["Page"])
        XCTAssertEqual(ids(graph), ["m1", "m2", "m3", "m4", "m5", "m6"])
        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertTrue(graph.nodes.allSatisfy { $0.kind == .memory })
        XCTAssertEqual(graph.node("m1")?.degree, 1, "its bridge to the page is gone")
    }

    func testHidingEveryTypeLeavesNothing() {
        let graph = build(hidden: Set(build().types.map(\.name)))
        XCTAssertTrue(graph.isEmpty)
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertFalse(graph.types.isEmpty, "the chips stay, so a type can be shown again")
        XCTAssertEqual(graph.eligible, 0)
        XCTAssertFalse(graph.isCapped)
    }

    func testAHiddenNameThatIsNotATypeChangesNothing() {
        XCTAssertEqual(build(hidden: ["Nonsense"]), build())
    }

    // MARK: Hiding what has no links

    func testHideUnlinkedLeavesOutTheMemoryWithNoLinks() {
        let graph = build(hideUnlinked: true)
        XCTAssertFalse(ids(graph).contains("m6"))
        XCTAssertEqual(ids(graph), ["m1", "m2", "m3", "m4", "m5", "p1", "p2"])
        XCTAssertEqual(graph.edges.count, 5)
        XCTAssertEqual(graph.eligible, 7)
        XCTAssertFalse(graph.isCapped)
    }

    func testHideUnlinkedOffKeepsEverythingAsBefore() {
        let graph = build()
        XCTAssertEqual(ids(graph), ["m1", "m2", "m3", "m4", "m5", "m6", "p1", "p2"])
        XCTAssertEqual(graph.node("m6")?.degree, 0)
    }

    func testAMemoryWhoseOnlyNeighbourIsHiddenCountsAsUnlinked() {
        // m4 and m5 are each other's only link; hiding Repository leaves m4 with nothing.
        XCTAssertNotNil(build(hidden: ["Repository"]).node("m4"), "without the filter, an unlinked memory stays")
        let graph = build(hideUnlinked: true, hidden: ["Repository"])
        XCTAssertNil(graph.node("m4"))
        XCTAssertNil(graph.node("m5"))
        XCTAssertEqual(ids(graph), ["m1", "m2", "m3", "p1", "p2"])
    }

    func testHidingTypesUntilNothingIsLinkedWithHideUnlinkedOnLeavesAnEmptyMap() {
        // Without its memories every page is unlinked, and so is each memory that is left.
        let graph = build(hideUnlinked: true, hidden: ["You", "Chat", "Repository"])
        XCTAssertTrue(graph.isEmpty)
        XCTAssertEqual(graph.memoryTotal, 6)
    }

    func testNoLinksAtAllWithHideUnlinkedOnLeavesAnEmptyMap() {
        let graph = MemoryGraphBuilder.build(memories: memories, links: [], hideUnlinked: true)
        XCTAssertTrue(graph.isEmpty)
        XCTAssertEqual(graph.types.map(\.name), ["You", "Chat", "File", "Repository"])
    }

    // MARK: The cap

    func testTheCapCountsOnlyWhatPassedTheFilters() {
        // Eight things, two of them unlinked once the filter is on; a cap of five cuts the six that are left.
        let capped = build(hideUnlinked: true, cap: 5)
        XCTAssertEqual(capped.nodes.count, 5)
        XCTAssertEqual(capped.eligible, 7)
        XCTAssertTrue(capped.isCapped)
        // Not capped at all when the filters take it under the cap.
        let narrowed = build(hidden: ["You", "Page"], cap: 5)
        XCTAssertEqual(ids(narrowed), ["m3", "m4", "m5"])
        XCTAssertFalse(narrowed.isCapped)
    }

    func testAPageCutByTheCapMakesTheMapCappedEvenWhenEveryMemoryIsShown() {
        // a-b are linked and each is bridged to a page: four nodes, and a cap of three drops one page.
        let pair = [MemoryItem(id: "a", title: "A"), MemoryItem(id: "b", title: "B")]
        let graph = MemoryGraphBuilder.build(
            memories: pair, links: [MemoryLinkRow(id: "1", aId: "a", bId: "b")],
            bridges: [MemoryBridgeRow(id: "x", memoryId: "a", artifactId: "pa"), MemoryBridgeRow(id: "y", memoryId: "b", artifactId: "pb")],
            cap: 3
        )
        XCTAssertEqual(graph.nodes.filter { $0.kind == .memory }.count, graph.memoryTotal, "both memories are drawn")
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertTrue(graph.isCapped, "the page that was cut is something the search cannot find")
    }

    func testTheCapKeepsTheBestConnectedAndDropsWhatItLeftAloneWhenAsked() {
        // m1, m2 and m3 have two links each and the rest fewer; a cap of two keeps m1 and m2 (the newest of the three), which
        // are linked to each other.
        let linked = build(hideUnlinked: true, cap: 2)
        XCTAssertEqual(ids(linked), ["m1", "m2"])
        XCTAssertEqual(linked.edges.count, 1)

        // x and y are the best connected and not linked to each other: the cap keeps just those two, each cut off from its
        // own neighbours. Left alone they stay; with Hide unlinked on they go, as unlinked nodes do.
        let hubs = ["x", "p1", "p2", "y", "r1", "r2"].map { MemoryItem(id: $0, title: $0) }
        let spokes = [
            MemoryLinkRow(id: "1", aId: "x", bId: "p1"), MemoryLinkRow(id: "2", aId: "x", bId: "p2"),
            MemoryLinkRow(id: "3", aId: "y", bId: "r1"), MemoryLinkRow(id: "4", aId: "y", bId: "r2"),
        ]
        let kept = MemoryGraphBuilder.build(memories: hubs, links: spokes, cap: 2)
        XCTAssertEqual(ids(kept), ["x", "y"])
        XCTAssertTrue(kept.edges.isEmpty)
        let dropped = MemoryGraphBuilder.build(memories: hubs, links: spokes, cap: 2, hideUnlinked: true)
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(dropped.eligible, 6)
        XCTAssertTrue(dropped.isCapped)
    }

    func testTheCallsThatPassNeitherControlBuildWhatTheyAlwaysDid() {
        let plain = MemoryGraphBuilder.build(memories: memories, links: links, bridges: bridges, artifacts: artifacts)
        XCTAssertEqual(plain, build())
        XCTAssertEqual(plain.nodes.count, 8)
        XCTAssertEqual(plain.edges.count, 5)
        XCTAssertFalse(plain.isCapped)
    }

    // MARK: Finding a memory

    func testASearchFindsPartOfAName() {
        let graph = build()
        // The memory has two links and the page one, so it comes first.
        XCTAssertEqual(graph.matches("lisbon").map(\.id), ["m1", "p1"])
        XCTAssertEqual(graph.matches("PASSPORT").map(\.id), ["m2"], "capitals do not count")
        XCTAssertEqual(graph.matches("  checklist \n").map(\.id), ["m2"], "spaces round the words do not count")
        XCTAssertTrue(graph.matches("nothing like this").isEmpty)
    }

    func testASearchDoesNotListAPageThatCannotBeOpened() {
        // p3 is bridged but its name and slug were not read, so it is drawn as "Page" and opens nothing.
        let graph = MemoryGraphBuilder.build(
            memories: memories, links: links,
            bridges: bridges + [MemoryBridgeRow(id: "b3", memoryId: "m2", artifactId: "p3")],
            artifacts: artifacts
        )
        XCTAssertEqual(graph.node("p3")?.title, "Page")
        XCTAssertNil(graph.node("p3")?.slug)
        XCTAssertTrue(graph.matches("page").isEmpty, "the page with no slug is on the map but not in the results")
        XCTAssertEqual(graph.matches("lisbon").map(\.id), ["m1", "p1"], "the pages that can be opened still are")
    }

    func testASearchWithNothingInItFindsNothing() {
        let graph = build()
        XCTAssertTrue(graph.matches("").isEmpty)
        XCTAssertTrue(graph.matches("   \n\t").isEmpty)
    }

    func testASearchIgnoresAccentsOnBothSides() {
        let accented = [
            MemoryItem(id: "a", title: "Café notes"),
            MemoryItem(id: "b", title: "Résumé draft"),
            MemoryItem(id: "c", title: "Plain"),
        ]
        let graph = MemoryGraphBuilder.build(memories: accented, links: [])
        XCTAssertEqual(graph.matches("cafe").map(\.id), ["a"])
        XCTAssertEqual(graph.matches("CAFÉ").map(\.id), ["a"])
        XCTAssertEqual(graph.matches("resume").map(\.id), ["b"])
        XCTAssertEqual(graph.matches("résumé").map(\.id), ["b"])
        XCTAssertEqual(graph.matches("e").map(\.id), ["a", "b"], "the accented letters are letters of the word")
    }

    func testTheBestConnectedMatchComesFirstAndEqualOnesKeepTheirOrderOnTheMap() {
        let notes = ["a", "b", "c", "d"].enumerated().map { MemoryItem(id: "n\($0.offset)", title: "Note \($0.element)") }
        // n2 has two links, n1 one, the rest none.
        let graph = MemoryGraphBuilder.build(
            memories: notes,
            links: [MemoryLinkRow(id: "1", aId: "n2", bId: "n1"), MemoryLinkRow(id: "2", aId: "n2", bId: "n3")]
        )
        XCTAssertEqual(graph.matches("note").map(\.id), ["n2", "n1", "n3", "n0"])
    }

    func testASearchStopsAtItsLimit() {
        let notes = (0..<20).map { MemoryItem(id: "n\($0)", title: "Note \($0)") }
        let graph = MemoryGraphBuilder.build(memories: notes, links: [])
        XCTAssertEqual(graph.matches("note").count, 6, "six by default, like the Library's box")
        XCTAssertEqual(graph.matches("note", limit: 3).map(\.id), ["n0", "n1", "n2"])
        XCTAssertTrue(graph.matches("note", limit: 0).isEmpty)
        XCTAssertTrue(graph.matches("note", limit: -2).isEmpty)
    }

    func testASearchFindsOnlyWhatIsOnTheMap() {
        // Hidden by type, hidden as unlinked and cut by the cap: none of the three can be found.
        XCTAssertTrue(build(hidden: ["You"]).matches("lisbon").isEmpty, "m1 is hidden, and the page it was bridged to goes with it")
        XCTAssertTrue(build(hideUnlinked: true).matches("lonely").isEmpty)
        let capped = MemoryGraphBuilder.build(memories: (0..<10).map { MemoryItem(id: "m\($0)", title: "Note \($0)") }, links: [], cap: 3)
        XCTAssertEqual(capped.matches("note", limit: 50).count, 3)
        XCTAssertTrue(capped.isCapped, "which is what the caption says, so a person knows why a memory is not found")
        XCTAssertEqual(capped.eligible, 10)
    }
}
