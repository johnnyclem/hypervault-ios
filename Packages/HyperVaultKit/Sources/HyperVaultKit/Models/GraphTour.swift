import Foundation

/// The "Drift" tour of the web's Semantic map: a walk that visits every node of a graph once, following the links where
/// it can, so the person sees how the things they kept hang together without choosing where to look next.
///
/// It starts at the best connected node. Each step goes to a neighbour not yet visited, the best connected first; when the
/// node it is on has none, it jumps to the best connected node not yet visited (the next island of a graph that falls in
/// pieces, or a node with no links at all); when everything has been visited it starts over. Ties go to the smaller id, so the
/// same graph is always walked in the same order, and a test, or a person coming back to the map, sees the same tour.
///
/// A value type with no clock and no UI: the view holds it and asks for the next stop when its timer fires.
public struct GraphTour: Sendable, Equatable {
    /// Every node, best connected first.
    private let ranked: [String]
    /// Each node's neighbours, best connected first.
    private let neighbours: [String: [String]]
    private var visited: Set<String> = []

    /// Where the tour is now; nil before the first step.
    public private(set) var current: String?

    /// - Parameters:
    ///   - ids: the nodes. A repeated id counts once.
    ///   - edges: pairs of ids. A pair that names an id not in `ids`, joins a node to itself or repeats an earlier pair
    ///     (in either order) is left out.
    ///   - weights: how well connected each node is, by id; the larger comes first. A node with no entry here counts the
    ///     nodes it is linked to, and a weight that is not a number counts as 0.
    public init(ids: [String], edges: [(String, String)], weights: [String: Double] = [:]) {
        var known = Set<String>()
        let unique = ids.filter { known.insert($0).inserted }

        var linked: [String: Set<String>] = [:]
        for (a, b) in edges where a != b && known.contains(a) && known.contains(b) {
            linked[a, default: []].insert(b)
            linked[b, default: []].insert(a)
        }
        let links = linked

        func weight(_ id: String) -> Double {
            guard let given = weights[id] else { return Double(links[id]?.count ?? 0) }
            return given.isFinite ? given : 0
        }
        func comesBefore(_ a: String, _ b: String) -> Bool {
            let wa = weight(a), wb = weight(b)
            return wa != wb ? wa > wb : a < b
        }
        ranked = unique.sorted(by: comesBefore)
        neighbours = links.mapValues { $0.sorted(by: comesBefore) }
    }

    /// How many nodes there are to visit.
    public var count: Int { ranked.count }

    public var isEmpty: Bool { ranked.isEmpty }

    /// Moves to the next stop and returns it; nil only when the graph has no nodes. A graph of one node stays on it.
    @discardableResult
    public mutating func next() -> String? {
        guard !ranked.isEmpty else { return nil }
        let along = current.flatMap { here in neighbours[here]?.first { !visited.contains($0) } }
        let stop: String
        if let along {
            stop = along
        } else if let jump = ranked.first(where: { !visited.contains($0) }) {
            stop = jump
        } else {
            // Everything has had its turn: go round again from the top.
            visited = []
            stop = ranked[0]
        }
        visited.insert(stop)
        current = stop
        return stop
    }

    /// Forgets where the tour has been, so the next step is the first one again.
    public mutating func reset() {
        visited = []
        current = nil
    }
}
