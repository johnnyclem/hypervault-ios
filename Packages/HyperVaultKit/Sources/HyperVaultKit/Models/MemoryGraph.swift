import Foundation

/// A page a memory is bridged to, as far as the graph needs to know it.
public struct MemoryGraphArtifact: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let slug: String?

    public init(id: String, title: String, slug: String? = nil) {
        self.id = id
        self.title = title
        self.slug = slug
    }
}

/// The memory graph: memories as nodes, the links between them as edges, and
/// the pages they are bridged to hanging off them. Built from the list and
/// `/api/connections`, capped so a big wiki stays readable and smooth.
public struct MemoryGraph: Sendable, Equatable {
    public struct Node: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case memory, artifact }

        public let id: String
        public let title: String
        public let kind: Kind
        /// A page's slug, for opening it.
        public let slug: String?
        /// How many edges it has in this graph.
        public let degree: Int
    }

    public struct Edge: Sendable, Hashable {
        public let source: String
        public let target: String
        /// Made by hand, as opposed to found by HyperVault.
        public let isManual: Bool
    }

    public let nodes: [Node]
    public let edges: [Edge]
    /// How many memories there were before the cap.
    public let memoryTotal: Int

    public var isCapped: Bool {
        nodes.filter { $0.kind == .memory }.count < memoryTotal
    }

    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// The ids a node is linked to.
    public func neighbours(of id: String) -> Set<String> {
        var out = Set<String>()
        for edge in edges {
            if edge.source == id { out.insert(edge.target) }
            if edge.target == id { out.insert(edge.source) }
        }
        return out
    }
}

public enum MemoryGraphBuilder {
    /// The web caps its graph for the same reason.
    public static let defaultCap = 150

    /// - Parameters:
    ///   - memories: the list, newest first.
    ///   - links: memory-to-memory links; ones whose ends are not in `memories` are left out.
    ///   - bridges: memory-to-page links.
    ///   - artifacts: names for the pages (a page without one is called "Page").
    ///   - cap: most nodes to keep. The best connected come first, then the newest.
    ///   - hideUnlinked: leave out memories with no links at all.
    public static func build(
        memories: [MemoryItem],
        links: [MemoryLinkRow],
        bridges: [MemoryBridgeRow] = [],
        artifacts: [MemoryGraphArtifact] = [],
        cap: Int = defaultCap,
        hideUnlinked: Bool = false
    ) -> MemoryGraph {
        let memoryIds = Set(memories.map(\.id))
        let artifactInfo = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Edges between things that exist, once each.
        var seenPairs = Set<String>()
        var rawEdges: [MemoryGraph.Edge] = []
        func add(_ a: String, _ b: String, manual: Bool) {
            guard a != b else { return }
            let key = a < b ? "\(a)\u{0}\(b)" : "\(b)\u{0}\(a)"
            guard seenPairs.insert(key).inserted else { return }
            rawEdges.append(MemoryGraph.Edge(source: a, target: b, isManual: manual))
        }
        for link in links where memoryIds.contains(link.aId) && memoryIds.contains(link.bId) {
            add(link.aId, link.bId, manual: link.kind == .manual)
        }
        var bridgedArtifacts: [String] = []
        var seenArtifacts = Set<String>()
        for bridge in bridges where memoryIds.contains(bridge.memoryId) {
            add(bridge.memoryId, bridge.artifactId, manual: bridge.kind == .manual)
            if seenArtifacts.insert(bridge.artifactId).inserted { bridgedArtifacts.append(bridge.artifactId) }
        }

        func degrees(_ edges: [MemoryGraph.Edge]) -> [String: Int] {
            var out: [String: Int] = [:]
            for edge in edges {
                out[edge.source, default: 0] += 1
                out[edge.target, default: 0] += 1
            }
            return out
        }

        // Candidates in a fixed order: memories as listed, then pages.
        struct Candidate {
            let id: String
            let title: String
            let kind: MemoryGraph.Node.Kind
            let slug: String?
        }
        var candidates: [Candidate] = memories.map { Candidate(id: $0.id, title: $0.title, kind: .memory, slug: nil) }
        for id in bridgedArtifacts {
            let info = artifactInfo[id]
            candidates.append(Candidate(id: id, title: info?.title ?? "Page", kind: .artifact, slug: info?.slug))
        }

        let firstDegrees = degrees(rawEdges)
        if hideUnlinked { candidates = candidates.filter { (firstDegrees[$0.id] ?? 0) > 0 } }

        let limit = max(cap, 0)
        if candidates.count > limit {
            let ranked = candidates.enumerated().sorted { lhs, rhs in
                let l = firstDegrees[lhs.element.id] ?? 0
                let r = firstDegrees[rhs.element.id] ?? 0
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            let keep = Set(ranked.prefix(limit).map { $0.element.id })
            candidates = candidates.filter { keep.contains($0.id) }
        }

        let kept = Set(candidates.map(\.id))
        let edges = rawEdges.filter { kept.contains($0.source) && kept.contains($0.target) }
        let finalDegrees = degrees(edges)
        let nodes = candidates.map {
            MemoryGraph.Node(id: $0.id, title: $0.title, kind: $0.kind, slug: $0.slug, degree: finalDegrees[$0.id] ?? 0)
        }
        return MemoryGraph(nodes: nodes, edges: edges, memoryTotal: memories.count)
    }
}
