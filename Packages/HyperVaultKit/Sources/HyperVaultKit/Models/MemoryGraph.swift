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

/// A kind of node the Memory map can leave out: where a memory came from (the words of `MemorySource.label`: "You", "Chat",
/// "Repository") or "Page" for a page a memory is bridged to, with how many of it there are. A memory whose source has no word
/// of its own is named by the source capitalised, as `MemorySource.label` does, so a source called "page" would share the
/// pages' chip; the server has none.
public struct MemoryGraphType: Sendable, Hashable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }

    /// The type the chips use for the pages memories are bridged to.
    public static let page = "Page"

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The memory graph: memories as nodes, the links between them as edges, and
/// the pages they are bridged to hanging off them. Built from the list and
/// `/api/connections` (and, for a branch other than main, that branch's own
/// links from its state), capped so a big wiki stays readable and smooth.
public struct MemoryGraph: Sendable, Equatable {
    public struct Node: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case memory, artifact }

        public let id: String
        public let title: String
        public let kind: Kind
        /// A page's slug, for opening it.
        public let slug: String?
        /// What the chips call it: the memory's source label, or `MemoryGraphType.page`.
        public let type: String
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
    /// How many memories there were before the cap, and before anything was left out.
    public let memoryTotal: Int
    /// What the chips offer, whatever is hidden: the memories' sources by how many memories have them, then "Page".
    public let types: [MemoryGraphType]
    /// What passed the type filter and hide-unlinked, before the cap.
    public let eligible: Int

    /// Some of what could be drawn was left out to keep the map readable.
    public var isCapped: Bool { nodes.count < eligible }

    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// The nodes whose name has `query` in it, the best connected first (the order they have on the map among equals): the
    /// web's "Find a memory..." box. Capital letters and accents do not count, so "cafe" finds "Café notes". Only what
    /// is on the map is found, so nothing past the cap is.
    public func matches(_ query: String, limit: Int = 6) -> [Node] {
        let needle = Self.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let found = nodes.enumerated().filter { Self.folded($0.element.title).contains(needle) }
        let ranked = found.sorted { $0.element.degree != $1.element.degree ? $0.element.degree > $1.element.degree : $0.offset < $1.offset }
        return ranked.prefix(max(limit, 0)).map(\.element)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

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
    ///   - hideUnlinked: leave out what has no links at all.
    ///   - hiddenTypes: kinds of node to leave out, by the names in `MemoryGraph.types`.
    ///
    /// The order is the Library graph's (`LibraryGraphBuilder`): hidden types go first, links are then kept only between the
    /// nodes that are left, and only then are the nodes with no links dropped when `hideUnlinked` is on, so a memory whose
    /// only neighbour was a hidden type counts as unlinked. A page is on the map for as long as a memory that is shown is
    /// bridged to it. Past `cap` the best connected stay; a node that stayed but whose neighbours did not is dropped with
    /// the unlinked.
    public static func build(
        memories: [MemoryItem],
        links: [MemoryLinkRow],
        bridges: [MemoryBridgeRow] = [],
        artifacts: [MemoryGraphArtifact] = [],
        cap: Int = defaultCap,
        hideUnlinked: Bool = false,
        hiddenTypes: Set<String> = []
    ) -> MemoryGraph {
        let artifactInfo = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // What the chips offer, whatever is hidden: sources by how many memories have them, the pages last.
        var counts: [String: Int] = [:]
        for memory in memories { counts[MemorySource.label(memory.source), default: 0] += 1 }
        var types = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { MemoryGraphType(name: $0.key, count: $0.value) }
        let allMemoryIds = Set(memories.map(\.id))
        let bridgedPages = Set(bridges.filter { allMemoryIds.contains($0.memoryId) }.map(\.artifactId))
        if !bridgedPages.isEmpty { types.append(MemoryGraphType(name: MemoryGraphType.page, count: bridgedPages.count)) }

        // Candidates in a fixed order: memories as listed, then pages.
        struct Candidate {
            let id: String
            let title: String
            let kind: MemoryGraph.Node.Kind
            let slug: String?
            let type: String
        }
        var candidates: [Candidate] = memories.compactMap { memory in
            let type = MemorySource.label(memory.source)
            guard !hiddenTypes.contains(type) else { return nil }
            return Candidate(id: memory.id, title: memory.title, kind: .memory, slug: nil, type: type)
        }
        let shownIds = Set(candidates.map(\.id))

        // Edges between things that are shown, once each.
        var seenPairs = Set<String>()
        var rawEdges: [MemoryGraph.Edge] = []
        func add(_ a: String, _ b: String, manual: Bool) {
            guard a != b else { return }
            let key = a < b ? "\(a)\u{0}\(b)" : "\(b)\u{0}\(a)"
            guard seenPairs.insert(key).inserted else { return }
            rawEdges.append(MemoryGraph.Edge(source: a, target: b, isManual: manual))
        }
        for link in links where shownIds.contains(link.aId) && shownIds.contains(link.bId) {
            add(link.aId, link.bId, manual: link.kind == .manual)
        }
        if !hiddenTypes.contains(MemoryGraphType.page) {
            var seenArtifacts = Set<String>()
            for bridge in bridges where shownIds.contains(bridge.memoryId) {
                add(bridge.memoryId, bridge.artifactId, manual: bridge.kind == .manual)
                if seenArtifacts.insert(bridge.artifactId).inserted {
                    let info = artifactInfo[bridge.artifactId]
                    candidates.append(Candidate(
                        id: bridge.artifactId, title: info?.title ?? "Page", kind: .artifact, slug: info?.slug, type: MemoryGraphType.page
                    ))
                }
            }
        }

        func degrees(_ edges: [MemoryGraph.Edge]) -> [String: Int] {
            var out: [String: Int] = [:]
            for edge in edges {
                out[edge.source, default: 0] += 1
                out[edge.target, default: 0] += 1
            }
            return out
        }

        let firstDegrees = degrees(rawEdges)
        if hideUnlinked { candidates = candidates.filter { (firstDegrees[$0.id] ?? 0) > 0 } }
        let eligible = candidates.count

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
        // A node kept for its links whose neighbours were all cut is unlinked on this map: it goes too, when asked.
        if hideUnlinked { candidates = candidates.filter { (finalDegrees[$0.id] ?? 0) > 0 } }
        let nodes = candidates.map {
            MemoryGraph.Node(id: $0.id, title: $0.title, kind: $0.kind, slug: $0.slug, type: $0.type, degree: finalDegrees[$0.id] ?? 0)
        }
        return MemoryGraph(nodes: nodes, edges: edges, memoryTotal: memories.count, types: types, eligible: eligible)
    }

    /// A branch's own memory-to-memory links, in the rows `build` takes, from the branch's state
    /// (`GET /api/mind/state?at=<branch>&branch=<branch>`). `/api/connections` carries main's links only.
    ///
    /// A link whose end is not among the state's memories is left out: it was made to something this branch no
    /// longer holds. A kind other than manual reads as found by HyperVault, as it does on `/api/connections`.
    public static func links(in state: MindState) -> [MemoryLinkRow] {
        let held = Set(state.memories.map(\.id))
        return state.links.compactMap { link in
            guard held.contains(link.aId), held.contains(link.bId) else { return nil }
            return MemoryLinkRow(id: link.id, aId: link.aId, bId: link.bId, kind: MemoryLinkKind(rawValue: link.kind) ?? .auto)
        }
    }
}
