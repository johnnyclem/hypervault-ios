import HyperVaultKit
import SwiftUI

// A reusable force-directed graph. It takes plain nodes and edges (an id, a
// label, a colour, a shape and a weight), not memories, so the Library can
// draw its artifacts with it later.

/// A thing in the graph.
struct ForceGraphNode: Identifiable, Hashable {
    enum Shape: Hashable { case circle, diamond, square }

    let id: String
    var label: String
    var color: Color
    var shape: Shape = .circle
    /// Bigger weights draw bigger and push harder.
    var weight: Double = 1
    /// A word under the label when the node is selected ("Memory", "Page").
    var detail: String?
}

struct ForceGraphEdge: Hashable {
    let source: String
    let target: String
    /// Drawn heavier and pulls tighter: a link someone made by hand.
    var isStrong = false
}

struct ForceGraphLegendItem: Hashable, Identifiable {
    let title: String
    let color: Color
    var shape: ForceGraphNode.Shape = .circle

    var id: String { title }
}

/// Runs the layout and holds where everything is. The view reads `points`.
@MainActor
@Observable
final class ForceGraphModel {
    private(set) var nodes: [ForceGraphNode] = []
    private(set) var edges: [ForceGraphEdge] = []
    private(set) var points: [ForcePoint] = []
    private(set) var isSimulating = false
    /// Bumped each time the picture is rebuilt, so the view can frame it again.
    private(set) var generation = 0

    @ObservationIgnored private var layout = ForceLayout(nodes: [])
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var degrees: [String: Int] = [:]
    @ObservationIgnored private var reduceMotion = false

    func degree(of id: String) -> Int { degrees[id] ?? 0 }

    func neighbours(of id: String) -> Set<String> {
        var out = Set<String>()
        for edge in edges {
            if edge.source == id { out.insert(edge.target) }
            if edge.target == id { out.insert(edge.source) }
        }
        return out
    }

    var bounds: ForceBounds? { layout.bounds }

    /// Shows a graph. If nodes were already on screen they stay where they are
    /// and the newcomers settle in beside them; the first time, it is laid out
    /// ahead of drawing so nothing flies in from a heap.
    func update(nodes newNodes: [ForceGraphNode], edges newEdges: [ForceGraphEdge], reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        // The same picture again (the screen came back): leave it alone.
        if newNodes == nodes, newEdges == edges, !points.isEmpty { return }
        let hadNodes = !nodes.isEmpty
        nodes = newNodes
        edges = newEdges

        var count: [String: Int] = [:]
        for edge in newEdges {
            count[edge.source, default: 0] += 1
            count[edge.target, default: 0] += 1
        }
        degrees = count

        let forceNodes = newNodes.map { ForceNode(id: $0.id, weight: $0.weight) }
        let forceEdges = newEdges.map { ForceEdge(source: $0.source, target: $0.target, strength: $0.isStrong ? 1.4 : 1) }
        if hadNodes {
            layout.update(nodes: forceNodes, edges: forceEdges)
        } else {
            layout = ForceLayout(nodes: forceNodes, edges: forceEdges)
            if !reduceMotion { for _ in 0..<90 { layout.tick() } }
        }
        points = layout.points
        generation += 1
        if reduceMotion {
            layout.run()
            points = layout.points
            isSimulating = false
            task?.cancel()
        } else {
            startLoop()
        }
    }

    func stop() {
        task?.cancel()
        isSimulating = false
    }

    // MARK: Dragging

    func drag(_ id: String, to point: ForcePoint) {
        layout.pin(id, at: point)
        layout.alphaTarget = 0.25
        layout.reheat(0.3)
        if reduceMotion {
            layout.tick()
            points = layout.points
        } else if !isSimulating {
            startLoop()
        } else {
            points = layout.points
        }
    }

    func endDrag(_ id: String) {
        layout.release(id)
        layout.alphaTarget = 0
        if reduceMotion {
            layout.run(maxTicks: 200)
            points = layout.points
        } else {
            startLoop()
        }
    }

    // MARK: Loop

    private func startLoop() {
        guard task == nil || isSimulating == false else { return }
        task?.cancel()
        isSimulating = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.layout.isSettled { break }
                self.layout.tick()
                self.layout.tick()
                self.points = self.layout.points
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard let self else { return }
            self.isSimulating = false
        }
    }
}
