import XCTest
@testable import HyperVaultKit

/// The Drift tour: where it starts, where each step goes, and what it does when it runs out of places to go.
final class GraphTourTests: XCTestCase {
    /// The next `count` stops of a tour.
    private func walk(_ tour: inout GraphTour, _ count: Int) -> [String] {
        (0..<count).compactMap { _ in tour.next() }
    }

    func testAnEmptyGraphHasNowhereToGo() {
        var tour = GraphTour(ids: [], edges: [])
        XCTAssertTrue(tour.isEmpty)
        XCTAssertEqual(tour.count, 0)
        XCTAssertNil(tour.next())
        XCTAssertNil(tour.next())
        XCTAssertNil(tour.current)
        // Links with no nodes to join are nothing.
        var linksOnly = GraphTour(ids: [], edges: [("a", "b")])
        XCTAssertNil(linksOnly.next())
    }

    func testOneNodeStaysWhereItIs() {
        var tour = GraphTour(ids: ["a"], edges: [])
        XCTAssertNil(tour.current, "nothing is visited before the first step")
        XCTAssertEqual(walk(&tour, 4), ["a", "a", "a", "a"])
        XCTAssertEqual(tour.current, "a")
        // A link from it to itself does not make it a neighbour of itself.
        var looped = GraphTour(ids: ["a"], edges: [("a", "a")])
        XCTAssertEqual(walk(&looped, 3), ["a", "a", "a"])
    }

    func testAPathStartsInTheMiddleAndFollowsTheLinks() {
        // a - b - c: b has two links and the others one.
        var tour = GraphTour(ids: ["a", "b", "c"], edges: [("a", "b"), ("b", "c")])
        // b first; its neighbours tie, so a (the smaller id); a has nothing unvisited next to it, so the jump takes c;
        // then everything has been seen and the tour starts over at b.
        XCTAssertEqual(walk(&tour, 6), ["b", "a", "c", "b", "a", "c"])
    }

    func testAStepPrefersTheBetterConnectedNeighbourAndLeavesTheFarEndForTheJump() {
        // n1, n2 and n3 have two links, the ends one. n1 is the smallest id of the best connected, so the tour starts there;
        // n2 (two links) is a better next step than n0 (one), and the tour runs on to the far end, which leaves n0 for the jump.
        let ids = ["n0", "n1", "n2", "n3", "n4"]
        let edges = [("n0", "n1"), ("n1", "n2"), ("n2", "n3"), ("n3", "n4")]
        var tour = GraphTour(ids: ids, edges: edges)
        XCTAssertEqual(walk(&tour, 5), ["n1", "n2", "n3", "n4", "n0"])
    }

    func testAStarStartsAtTheHubAndTakesTheSpokesInIdOrder() {
        var tour = GraphTour(
            ids: ["hub", "d", "b", "c", "a"],
            edges: [("hub", "d"), ("hub", "b"), ("c", "hub"), ("hub", "a")]
        )
        // After each spoke the hub is visited and the spoke has no other neighbour, so each step is a jump, in id order.
        XCTAssertEqual(walk(&tour, 5), ["hub", "a", "b", "c", "d"])
        XCTAssertEqual(tour.next(), "hub", "and it starts over")
    }

    func testTwoComponentsAreBothVisitedTheBetterConnectedFirst() {
        // {a, b, c} is a triangle (two links each); {x, y} is one link.
        var tour = GraphTour(
            ids: ["x", "y", "a", "b", "c"],
            edges: [("a", "b"), ("b", "c"), ("a", "c"), ("x", "y")]
        )
        // The triangle: a, then its best neighbour b, then c; the jump goes to x, the better of the two ends that are left
        // (a tie on one link each, so the smaller id), and from x the link leads on to y.
        XCTAssertEqual(walk(&tour, 5), ["a", "b", "c", "x", "y"])
        XCTAssertEqual(tour.next(), "a", "the whole graph was seen, so it begins again at the best connected")
    }

    func testItWrapsRoundAndRepeatsTheSameRoundForever() {
        var tour = GraphTour(ids: ["a", "b", "c", "d"], edges: [("a", "b"), ("b", "c"), ("c", "d")])
        let round = walk(&tour, 4)
        XCTAssertEqual(Set(round), ["a", "b", "c", "d"], "every node is visited once in a round")
        XCTAssertEqual(walk(&tour, 4), round)
        XCTAssertEqual(walk(&tour, 4), round)
    }

    func testTheWalkDoesNotDependOnTheOrderTheGraphIsGiven() {
        let ids = ["m", "a", "z", "k", "b", "q"]
        let edges = [("m", "a"), ("a", "z"), ("k", "b"), ("m", "k"), ("q", "z")]
        var first = GraphTour(ids: ids, edges: edges)
        var shuffled = GraphTour(ids: Array(ids.reversed()), edges: edges.reversed().map { ($0.1, $0.0) })
        XCTAssertEqual(walk(&first, 12), walk(&shuffled, 12))
        // And the same input twice is the same walk.
        var again = GraphTour(ids: ids, edges: edges)
        var other = GraphTour(ids: ids, edges: edges)
        XCTAssertEqual(walk(&again, 12), walk(&other, 12))
    }

    func testANodeWithNoLinksIsStillVisitedAfterTheLinkedOnes() {
        var tour = GraphTour(ids: ["lonely", "a", "b", "alone"], edges: [("a", "b")])
        // a and b first (a link each, a the smaller id); then the two with none, in id order.
        XCTAssertEqual(walk(&tour, 4), ["a", "b", "alone", "lonely"])
        XCTAssertEqual(tour.next(), "a")
    }

    func testLinksToThingsThatAreNotNodesRepeatedLinksAndLoopsAreLeftOut() {
        // The only real link is a-b, written three times and both ways; "ghost" is not a node, so c has no neighbours.
        var tour = GraphTour(
            ids: ["a", "b", "c", "a"],
            edges: [("a", "b"), ("b", "a"), ("a", "b"), ("a", "ghost"), ("ghost", "c"), ("c", "c")]
        )
        XCTAssertEqual(tour.count, 3, "a repeated id is one node")
        XCTAssertEqual(walk(&tour, 4), ["a", "b", "c", "a"])
    }

    func testTheWeightsGiveTheOrderInPlaceOfTheLinkCount() {
        // By links a would lead (two), but the weights say c is the one that matters.
        var tour = GraphTour(
            ids: ["a", "b", "c"], edges: [("a", "b"), ("a", "c")],
            weights: ["a": 1, "b": 2, "c": 9]
        )
        XCTAssertEqual(walk(&tour, 3), ["c", "a", "b"])
    }

    func testANodeWithNoWeightCountsItsLinksAndABadWeightCountsForNothing() {
        var tour = GraphTour(
            ids: ["a", "b", "c"], edges: [("a", "b"), ("b", "c")],
            weights: ["a": .nan, "c": .infinity]
        )
        // a and c are worth 0 (not numbers); b has no weight and two links.
        XCTAssertEqual(walk(&tour, 3), ["b", "a", "c"])
    }

    func testResetPutsTheTourBackAtTheStart() {
        var tour = GraphTour(ids: ["a", "b", "c"], edges: [("a", "b"), ("b", "c")])
        let first = walk(&tour, 2)
        XCTAssertEqual(first, ["b", "a"])
        tour.reset()
        XCTAssertNil(tour.current)
        XCTAssertEqual(walk(&tour, 2), first)
    }

    func testATourIsAValueSoACopyWalksOnItsOwn() {
        var tour = GraphTour(ids: ["a", "b", "c"], edges: [("a", "b"), ("b", "c")])
        tour.next()
        var copy = tour
        XCTAssertEqual(copy.next(), "a")
        XCTAssertEqual(tour.current, "b", "the original did not move")
        XCTAssertEqual(tour.next(), "a")
        XCTAssertEqual(tour, copy)
    }
}
