import XCTest
@testable import HyperVaultKit

final class ForceLayoutTests: XCTestCase {
    private func ring(_ count: Int, chords: Bool = true) -> (nodes: [ForceNode], edges: [ForceEdge]) {
        let nodes = (0..<count).map { ForceNode(id: "n\($0)") }
        var edges = (0..<count).map { ForceEdge(source: "n\($0)", target: "n\(($0 + 1) % count)") }
        if chords {
            for i in stride(from: 0, to: count, by: 5) { edges.append(ForceEdge(source: "n\(i)", target: "n\((i + count / 2) % count)")) }
        }
        return (nodes, edges)
    }

    private func assertFinite(_ layout: ForceLayout, file: StaticString = #filePath, line: UInt = #line) {
        for point in layout.points {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite, "a position is not finite: \(point)", file: file, line: line)
        }
    }

    func testSettlesAndStopsMoving() {
        let (nodes, edges) = ring(40)
        var layout = ForceLayout(nodes: nodes, edges: edges)
        let ticks = layout.run(maxTicks: 1_000)
        XCTAssertLessThan(ticks, 1_000, "never settled")
        XCTAssertTrue(layout.isSettled)
        XCTAssertLessThan(layout.peakSpeed, 0.5)
        assertFinite(layout)
    }

    func testNoNaNFromDegenerateInput() {
        // Everything on one spot, loops, repeats, links to nothing, nonsense weights.
        let nodes = [
            ForceNode(id: "a", weight: 0, position: .zero),
            ForceNode(id: "b", weight: .nan, position: .zero),
            ForceNode(id: "c", weight: -3, position: .zero),
            ForceNode(id: "d", weight: 1e12, position: .zero),
            ForceNode(id: "a", weight: 1),
            ForceNode(id: "e", position: ForcePoint(x: .infinity, y: .nan)),
        ]
        let edges = [
            ForceEdge(source: "a", target: "a"),
            ForceEdge(source: "a", target: "b"),
            ForceEdge(source: "b", target: "a"),
            ForceEdge(source: "a", target: "zzz"),
            ForceEdge(source: "c", target: "d", strength: .nan),
        ]
        var layout = ForceLayout(nodes: nodes, edges: edges)
        XCTAssertEqual(layout.nodes.count, 5, "the repeated id should be dropped")
        XCTAssertEqual(layout.edges.count, 2, "loops, repeats and links to nothing should be dropped")
        layout.run(maxTicks: 800)
        assertFinite(layout)
        XCTAssertTrue(layout.isSettled)
    }

    func testEmptyAndSingleNode() {
        var empty = ForceLayout(nodes: [])
        XCTAssertEqual(empty.run(), 0)  // nothing to do, and nothing crashes
        XCTAssertNil(empty.bounds)

        var one = ForceLayout(nodes: [ForceNode(id: "only")])
        one.run()
        assertFinite(one)
        XCTAssertNotNil(one.point(for: "only"))
        XCTAssertNil(one.point(for: "missing"))
        // Gravity brings a lone node to the middle.
        XCTAssertLessThan(one.point(for: "only")!.distance(to: .zero), 5)
    }

    func testFixedNodesDoNotMove() {
        let spot = ForcePoint(x: 120, y: -80)
        var nodes = (0..<12).map { ForceNode(id: "n\($0)") }
        nodes[3] = ForceNode(id: "n3", isFixed: true, position: spot)
        nodes[7] = ForceNode(id: "n7", isFixed: true, position: ForcePoint(x: -60, y: 10))
        let edges = (0..<11).map { ForceEdge(source: "n\($0)", target: "n\($0 + 1)") }
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run(maxTicks: 800)
        XCTAssertEqual(layout.point(for: "n3"), spot)
        XCTAssertEqual(layout.point(for: "n7"), ForcePoint(x: -60, y: 10))
        // The free ones arranged themselves around the fixed ones: a link is still a link.
        XCTAssertLessThan(layout.point(for: "n3")!.distance(to: layout.point(for: "n4")!), 200)
        assertFinite(layout)
    }

    func testSameSeedSamePicture() {
        let (nodes, edges) = ring(30)
        var a = ForceLayout(nodes: nodes, edges: edges)
        var b = ForceLayout(nodes: nodes, edges: edges)
        a.run()
        b.run()
        XCTAssertEqual(a.points, b.points)

        var other = ForceConfiguration()
        other.seed = 99
        var c = ForceLayout(nodes: nodes, edges: edges, configuration: other)
        c.run()
        XCTAssertNotEqual(a.points, c.points)
    }

    func testGroupsSeparate() {
        // Three groups of eight, each a ring with a chord, joined by single bridges.
        var nodes: [ForceNode] = []
        var edges: [ForceEdge] = []
        for g in 0..<3 {
            for i in 0..<8 { nodes.append(ForceNode(id: "g\(g)n\(i)")) }
            for i in 0..<8 { edges.append(ForceEdge(source: "g\(g)n\(i)", target: "g\(g)n\((i + 1) % 8)")) }
            edges.append(ForceEdge(source: "g\(g)n0", target: "g\(g)n4"))
        }
        edges.append(ForceEdge(source: "g0n2", target: "g1n2"))
        edges.append(ForceEdge(source: "g1n6", target: "g2n6"))
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run()
        let p = layout.positions
        var within = 0.0, between = 0.0, withinCount = 0.0, betweenCount = 0.0
        for a in 0..<nodes.count {
            for b in (a + 1)..<nodes.count {
                let d = p[nodes[a].id]!.distance(to: p[nodes[b].id]!)
                if a / 8 == b / 8 { within += d; withinCount += 1 } else { between += d; betweenCount += 1 }
            }
        }
        XCTAssertGreaterThan((between / betweenCount) / (within / withinCount), 1.5, "the groups ran together")
    }

    func testLinkLengthIsNearTheConfiguredDistance() {
        var layout = ForceLayout(nodes: [ForceNode(id: "a"), ForceNode(id: "b")], edges: [ForceEdge(source: "a", target: "b")])
        layout.run()
        let distance = layout.point(for: "a")!.distance(to: layout.point(for: "b")!)
        XCTAssertEqual(distance, layout.configuration.linkDistance, accuracy: layout.configuration.linkDistance * 0.5)
    }

    func testNodesDoNotOverlap() {
        let nodes = (0..<30).map { ForceNode(id: "n\($0)", weight: Double(1 + $0 % 5)) }
        var layout = ForceLayout(nodes: nodes, edges: [])
        layout.run()
        let config = layout.configuration
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let gap = layout.points[i].distance(to: layout.points[j])
                let need = config.radius(forWeight: nodes[i].weight) + config.radius(forWeight: nodes[j].weight)
                XCTAssertGreaterThan(gap, need * 0.8, "n\(i) and n\(j) overlap")
            }
        }
    }

    func testPinHoldsANodeUntilItIsReleased() {
        let (nodes, edges) = ring(10, chords: false)
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run()
        let target = ForcePoint(x: 300, y: 300)
        layout.pin("n0", at: target)
        layout.reheat(0.5)
        for _ in 0..<60 { layout.tick() }
        XCTAssertEqual(layout.point(for: "n0"), target)
        // The neighbours were pulled towards it.
        XCTAssertLessThan(layout.point(for: "n1")!.distance(to: target), 300 * 2.0.squareRoot())
        layout.release("n0")
        layout.reheat(0.5)
        for _ in 0..<200 { layout.tick() }
        XCTAssertNotEqual(layout.point(for: "n0"), target)
        assertFinite(layout)
    }

    func testAlphaTargetKeepsItMoving() {
        let (nodes, edges) = ring(8, chords: false)
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run()
        XCTAssertTrue(layout.isSettled)
        layout.alphaTarget = 0.3
        for _ in 0..<100 { layout.tick() }
        XCTAssertFalse(layout.isSettled)
        XCTAssertGreaterThan(layout.alpha, 0.2)
    }

    func testUpdateGrowsTheGraphWithoutRedrawingIt() {
        let (nodes, edges) = ring(12, chords: false)
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run()
        let before = layout.positions

        var more = nodes
        more.append(ForceNode(id: "new"))
        var moreEdges = edges
        moreEdges.append(ForceEdge(source: "n4", target: "new"))
        layout.update(nodes: more, edges: moreEdges)

        for node in nodes { XCTAssertEqual(layout.point(for: node.id), before[node.id], "\(node.id) was moved by the update") }
        let fresh = layout.point(for: "new")!
        XCTAssertLessThan(fresh.distance(to: before["n4"]!), layout.configuration.linkDistance)
        XCTAssertFalse(layout.isSettled, "a change should warm the layout up")
        layout.run()
        XCTAssertTrue(layout.isSettled)

        // And a node that goes away goes.
        layout.update(nodes: nodes, edges: edges)
        XCTAssertNil(layout.point(for: "new"))
        XCTAssertEqual(layout.nodes.count, 12)
    }

    func testDegreeAndBounds() {
        let nodes = ["hub", "x", "y", "z", "alone"].map { ForceNode(id: $0) }
        let edges = ["x", "y", "z"].map { ForceEdge(source: "hub", target: $0) }
        var layout = ForceLayout(nodes: nodes, edges: edges)
        layout.run()
        XCTAssertEqual(layout.degree(of: "hub"), 3)
        XCTAssertEqual(layout.degree(of: "alone"), 0)
        XCTAssertEqual(layout.degree(of: "nobody"), 0)
        let bounds = layout.bounds!
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        for point in layout.points {
            XCTAssertTrue(point.x >= bounds.minX && point.x <= bounds.maxX)
        }
    }

    func testAHundredAndFiftyNodesStayInReach() {
        // The size of graph the app draws: no links at all is the worst case for drifting apart.
        let loose = (0..<150).map { ForceNode(id: "m\($0)") }
        var layout = ForceLayout(nodes: loose, edges: [])
        layout.run(maxTicks: 500)
        assertFinite(layout)
        let farthest = layout.points.map { $0.distance(to: .zero) }.max() ?? 0
        XCTAssertLessThan(farthest, 2_000)
        XCTAssertTrue(layout.isSettled)
    }
}
