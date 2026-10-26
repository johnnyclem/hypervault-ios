import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The graph's first frame: where the layout stands when the picture is first framed.
@MainActor
final class MemoryGraphLayoutTests: XCTestCase {
    private func tree(_ count: Int) -> (nodes: [ForceGraphNode], edges: [ForceGraphEdge]) {
        let nodes = (0..<count).map { ForceGraphNode(id: "n\($0)", label: "Node \($0)", color: Palette.blue, weight: 1 + Double($0 % 4)) }
        let edges = (1..<count).map { ForceGraphEdge(source: "n\($0)", target: "n\($0 / 2)", isStrong: $0 % 7 == 0) }
        return (nodes, edges)
    }

    func testTheFirstFrameIsCloseToTheSizeTheGraphComesToRestAt() throws {
        for count in [9, 24, 60] {
            let (nodes, edges) = tree(count)
            let model = ForceGraphModel()
            model.update(nodes: nodes, edges: edges, reduceMotion: false)
            model.stop()
            let first = try XCTUnwrap(model.bounds)

            var resting = ForceLayout(
                nodes: nodes.map { ForceNode(id: $0.id, weight: $0.weight) },
                edges: edges.map { ForceEdge(source: $0.source, target: $0.target, strength: $0.isStrong ? 1.4 : 1) }
            )
            resting.run()
            let last = try XCTUnwrap(resting.bounds)

            // A picture framed on the first frame has to hold for the last: within a tenth either way.
            XCTAssertEqual(first.width, last.width, accuracy: last.width * 0.1, "\(count) nodes, width")
            XCTAssertEqual(first.height, last.height, accuracy: last.height * 0.1, "\(count) nodes, height")
        }
    }

    func testReduceMotionStartsAtRest() throws {
        let (nodes, edges) = tree(24)
        let model = ForceGraphModel()
        model.update(nodes: nodes, edges: edges, reduceMotion: true)
        XCTAssertFalse(model.isSimulating)
        XCTAssertEqual(model.points.count, 24)
    }
}
