import Foundation

// The Library's Files graph: the web's `components/vault-graph.tsx` as the Library mounts it. Every page is a node
// beside every memory, joined by the page-to-page connections (made by hand or found by the server), the memory
// links and the memory-to-page bridges, and the person can hide a type, hide what has no links, and find a node by
// name. The Memory tab's map (`MemoryGraphBuilder`) draws memories first and only the pages they are bridged to; this
// one starts from the pages, so a vault of pages with no memories still has a map.

/// A page as the graph draws it. `id` is the artifact's row id, which is what a connection names it by (a page's slug,
/// which opens it, is not in any connection), and `type` is the word the web puts on it: "react" for a component, else the
/// stored type ("html", "markdown", "note", "pdf", "image"...).
public struct LibraryGraphPage: Sendable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let type: String

    public init(id: String, slug: String, title: String, type: String = "page") {
        self.id = id
        self.slug = slug
        self.title = title
        self.type = type
    }
}

/// One row of `artifacts` as PostgREST sends it for the graph: the columns the page needs, and the ones that tell a page
/// the system keeps for itself from one the person made.
public struct LibraryGraphRow: Sendable, Decodable, Equatable {
    public let id: String
    public let slug: String
    public let title: String
    public let type: String
    public let tags: [String]
    public let isJsx: Bool

    public init(id: String, slug: String, title: String = "Untitled", type: String = "html", tags: [String] = [], isJsx: Bool = false) {
        self.id = id
        self.slug = slug
        self.title = title
        self.type = type
        self.tags = tags
        self.isJsx = isJsx
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        let name = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "html"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
    }

    enum Keys: String, CodingKey { case id, slug, title, type, tags, isJsx }

    /// The page this row stands for, or nil for one the system keeps for itself (the setup challenge, a task board's data)
    /// or a group, which the web graph leaves out.
    public var page: LibraryGraphPage? {
        guard type != "group", !tags.contains(where: { ArtifactSummary.bookkeepingTags.contains($0) }) else { return nil }
        return LibraryGraphPage(id: id, slug: slug, title: title, type: isJsx ? "react" : type.lowercased())
    }
}

/// The pages the map read, and whether there were more than it keeps.
public struct LibraryGraphPages: Sendable, Equatable {
    public let pages: [LibraryGraphPage]
    /// The vault holds more pages than `LibraryGraphRow.limit`, and these are the newest.
    public let isTruncated: Bool

    public init(pages: [LibraryGraphPage], isTruncated: Bool = false) {
        self.pages = pages
        self.isTruncated = isTruncated
    }
}

extension LibraryGraphRow {
    /// The most pages one map reads: the web's graph stops at 300 and so does this.
    public static let limit = 300

    /// The person's pages with their row ids, newest first. `/api/artifacts` has no row ids and the one route that has
    /// them stops at 50 rows, so the map reads the table the way the web does, with the person's own token. One row
    /// more than the limit is asked for, to know whether the limit cut anything.
    public static func pages(rest: AccountRest, userID: String) async throws -> LibraryGraphPages {
        func query(_ columns: String) -> [URLQueryItem] {
            [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "type", value: "neq.group"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "\(limit + 1)"),
            ]
        }
        let rows: [LibraryGraphRow]
        do {
            rows = try await rest.rows(LibraryGraphRow.self, from: "artifacts", query: query("id,slug,title,type,tags,is_jsx"))
        } catch where AccountRest.isMissingColumn(error) {
            // A database that predates a column: the page still has an id, a name and a type.
            rows = try await rest.rows(LibraryGraphRow.self, from: "artifacts", query: query("id,slug,title,type"))
        }
        return LibraryGraphPages(pages: rows.prefix(limit).compactMap(\.page), isTruncated: rows.count > limit)
    }
}

/// `GET /api/connections`: all three kinds of edge in one read, which the Memory map and a page's sheet each read half of.
public struct LibraryConnections: Sendable, Decodable, Equatable {
    /// Page to page: made by hand, or found by the server from shared tags and title words.
    public let pageLinks: [ArtifactEdge]
    /// Memory to memory. The server sends the main branch's.
    public let memoryLinks: [MemoryLinkRow]
    /// Memory to page.
    public let bridges: [MemoryBridgeRow]

    public init(pageLinks: [ArtifactEdge] = [], memoryLinks: [MemoryLinkRow] = [], bridges: [MemoryBridgeRow] = []) {
        self.pageLinks = pageLinks
        self.memoryLinks = memoryLinks
        self.bridges = bridges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pageLinks = try c.decodeIfPresent([ArtifactEdge].self, forKey: .connections) ?? []
        memoryLinks = try c.decodeIfPresent([MemoryLinkRow].self, forKey: .memoryLinks) ?? []
        bridges = try c.decodeIfPresent([MemoryBridgeRow].self, forKey: .memoryArtifactLinks) ?? []
    }

    enum Keys: String, CodingKey { case connections, memoryLinks, memoryArtifactLinks }
}

extension Endpoint where Response == LibraryConnections {
    /// Every edge the caller owns, read once.
    public static var libraryConnections: Endpoint<LibraryConnections> {
        Endpoint(.get, "/api/connections")
    }
}

/// A type the map can hide: a page type, or "memory", with how many of it the vault holds.
public struct LibraryGraphType: Sendable, Hashable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }

    /// The type the chips use for memories.
    public static let memory = "memory"

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct LibraryGraph: Sendable, Equatable {
    public struct Node: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case memory, page }

        public let id: String
        public let title: String
        public let kind: Kind
        /// The page's type, or "memory".
        public let type: String
        /// What opens a page; nil for a memory.
        public let slug: String?
        /// How many edges the node has in the graph as drawn.
        public let degree: Int
    }

    public struct Edge: Sendable, Hashable {
        public let source: String
        public let target: String
        /// Made by hand, as against found by the server.
        public let isManual: Bool
    }

    public let nodes: [Node]
    public let edges: [Edge]
    /// What the chips offer, whatever is hidden: page types by how many pages have them, then "memory".
    public let types: [LibraryGraphType]
    /// Everything the vault gave the graph.
    public let total: Int
    /// What passed the type filter and hide-unlinked, before the cap.
    public let eligible: Int

    /// Some of what could be drawn was left out to keep the map readable.
    public var isCapped: Bool { nodes.count < eligible }

    public static let empty = LibraryGraph(nodes: [], edges: [], types: [], total: 0, eligible: 0)

    public func node(_ id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    /// The nodes whose name has `query` in it, the best connected first: the web's "Find a memory..." box.
    public func matches(_ query: String, limit: Int = 6) -> [Node] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let found = nodes.enumerated().filter { $0.element.title.lowercased().contains(needle) }
        let ranked = found.sorted { $0.element.degree != $1.element.degree ? $0.element.degree > $1.element.degree : $0.offset < $1.offset }
        return ranked.prefix(max(limit, 0)).map(\.element)
    }
}

public enum LibraryGraphBuilder {
    /// The most nodes drawn at once. The map's layout does work for every pair of nodes on every tick, and the Memory map
    /// stops at the same number.
    public static let defaultCap = 150

    /// Pages and memories as nodes and the links among them as edges.
    ///
    /// The order is the web's (`vault-graph.tsx`): hidden types go first, links are then kept only between the nodes
    /// that are left, and only then are the nodes with no links dropped when `hideUnlinked` is on, so a page whose only
    /// neighbour was a hidden type counts as unlinked. Past `cap` the best connected stay, the newest first among equals
    /// (pages come in the order given, which is newest first, then memories); a node that stayed but whose neighbours
    /// did not is dropped with the unlinked. An edge between a pair is kept once, the one made by hand when both a
    /// hand-made and a found link join them.
    public static func build(
        pages: [LibraryGraphPage],
        memories: [MemoryItem],
        pageLinks: [ArtifactEdge] = [],
        memoryLinks: [MemoryLinkRow] = [],
        bridges: [MemoryBridgeRow] = [],
        hiddenTypes: Set<String> = [],
        hideUnlinked: Bool = false,
        cap: Int = defaultCap
    ) -> LibraryGraph {
        var candidates: [LibraryGraph.Node] = []
        var seen = Set<String>()
        for page in pages where seen.insert(page.id).inserted {
            candidates.append(.init(id: page.id, title: page.title, kind: .page, type: page.type.lowercased(), slug: page.slug, degree: 0))
        }
        for memory in memories where seen.insert(memory.id).inserted {
            candidates.append(.init(id: memory.id, title: memory.title, kind: .memory, type: LibraryGraphType.memory, slug: nil, degree: 0))
        }

        var counts: [String: Int] = [:]
        for node in candidates { counts[node.type, default: 0] += 1 }
        var types = counts.filter { $0.key != LibraryGraphType.memory }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { LibraryGraphType(name: $0.key, count: $0.value) }
        if let memoryCount = counts[LibraryGraphType.memory] { types.append(LibraryGraphType(name: LibraryGraphType.memory, count: memoryCount)) }

        let hidden = Set(hiddenTypes.map { $0.lowercased() })
        let visible = candidates.filter { !hidden.contains($0.type) }
        let visibleIds = Set(visible.map(\.id))

        // Hand-made links first, so that the one kept for a pair is the one a person made.
        var edges: [LibraryGraph.Edge] = []
        var pairs = Set<String>()
        func add(_ a: String, _ b: String, manual: Bool) {
            guard a != b, visibleIds.contains(a), visibleIds.contains(b) else { return }
            let key = a < b ? "\(a)\u{0}\(b)" : "\(b)\u{0}\(a)"
            guard pairs.insert(key).inserted else { return }
            edges.append(.init(source: a, target: b, isManual: manual))
        }
        for link in pageLinks where !link.isAuto { add(link.aId, link.bId, manual: true) }
        for link in memoryLinks where link.kind == .manual { add(link.aId, link.bId, manual: true) }
        for bridge in bridges where bridge.kind == .manual { add(bridge.memoryId, bridge.artifactId, manual: true) }
        for link in pageLinks where link.isAuto { add(link.aId, link.bId, manual: false) }
        for link in memoryLinks where link.kind != .manual { add(link.aId, link.bId, manual: false) }
        for bridge in bridges where bridge.kind != .manual { add(bridge.memoryId, bridge.artifactId, manual: false) }

        func degrees(_ edges: [LibraryGraph.Edge]) -> [String: Int] {
            var result: [String: Int] = [:]
            for edge in edges {
                result[edge.source, default: 0] += 1
                result[edge.target, default: 0] += 1
            }
            return result
        }

        let firstPass = degrees(edges)
        let eligible = hideUnlinked ? visible.filter { (firstPass[$0.id] ?? 0) > 0 } : visible
        var kept = eligible
        let limit = max(cap, 0)
        if eligible.count > limit {
            let ranked = eligible.enumerated().sorted {
                let a = firstPass[$0.element.id] ?? 0, b = firstPass[$1.element.id] ?? 0
                return a != b ? a > b : $0.offset < $1.offset
            }
            let keepIds = Set(ranked.prefix(limit).map(\.element.id))
            kept = eligible.filter { keepIds.contains($0.id) }
        }
        let keptIds = Set(kept.map(\.id))
        let finalEdges = edges.filter { keptIds.contains($0.source) && keptIds.contains($0.target) }
        let finalDegrees = degrees(finalEdges)
        // A node kept for its links whose neighbours were all cut is unlinked on this map: it goes too, when asked.
        if hideUnlinked { kept = kept.filter { (finalDegrees[$0.id] ?? 0) > 0 } }
        let nodes = kept.map {
            LibraryGraph.Node(id: $0.id, title: $0.title, kind: $0.kind, type: $0.type, slug: $0.slug, degree: finalDegrees[$0.id] ?? 0)
        }
        return LibraryGraph(nodes: nodes, edges: finalEdges, types: types, total: candidates.count, eligible: eligible.count)
    }
}
