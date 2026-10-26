import Foundation

// Edges between a page and other pages or memories (`app/api/connections`).

/// A page-to-page connection. The pair is stored with the smaller id first.
public struct ArtifactEdge: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let aId: String
    public let bId: String
    /// manual, or auto (found by shared tags and title words).
    public let kind: String
    public let createdAt: Date?

    public init(id: String, aId: String, bId: String, kind: String = "manual", createdAt: Date? = nil) {
        self.id = id
        self.aId = aId
        self.bId = bId
        self.kind = kind
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        aId = try c.decode(String.self, forKey: .aId)
        bId = try c.decode(String.self, forKey: .bId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, aId, bId, kind, createdAt }

    public var isAuto: Bool { kind == "auto" }

    /// The other end of the edge, seen from `artifactId`.
    public func other(from artifactId: String) -> String? {
        if aId == artifactId { return bId }
        if bId == artifactId { return aId }
        return nil
    }
}

/// A page-to-memory connection.
public struct ArtifactMemoryBridge: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let memoryId: String
    public let artifactId: String
    public let kind: String
    public let createdAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        memoryId = try c.decode(String.self, forKey: .memoryId)
        artifactId = try c.decode(String.self, forKey: .artifactId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, memoryId, artifactId, kind, createdAt }

    public var isAuto: Bool { kind == "auto" }
}

/// `GET /api/connections`: every edge the caller owns that touches a page.
/// (The memory-to-memory links the route also sends belong to the graph.)
public struct ArtifactEdges: Sendable, Codable, Equatable {
    public let connections: [ArtifactEdge]
    public let memoryArtifactLinks: [ArtifactMemoryBridge]

    public init(connections: [ArtifactEdge] = [], memoryArtifactLinks: [ArtifactMemoryBridge] = []) {
        self.connections = connections
        self.memoryArtifactLinks = memoryArtifactLinks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        connections = try c.decodeIfPresent([ArtifactEdge].self, forKey: .connections) ?? []
        memoryArtifactLinks = try c.decodeIfPresent([ArtifactMemoryBridge].self, forKey: .memoryArtifactLinks) ?? []
    }

    enum Keys: String, CodingKey { case connections, memoryArtifactLinks }

    /// How many other pages each page is connected to: the web's count on a page's sheet.
    public var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for edge in connections {
            counts[edge.aId, default: 0] += 1
            counts[edge.bId, default: 0] += 1
        }
        return counts
    }

    public func edges(touching artifactId: String) -> [ArtifactEdge] {
        connections.filter { $0.aId == artifactId || $0.bId == artifactId }
    }

    public func bridges(touching artifactId: String) -> [ArtifactMemoryBridge] {
        memoryArtifactLinks.filter { $0.artifactId == artifactId }
    }
}

/// What a connection is to, once its other end has been looked up.
public struct ArtifactLinkedItem: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        case page(slug: String)
        case memory(id: String)
    }

    /// The edge's own id, which Remove names.
    public let id: String
    public let name: String
    public let kind: KeptKind
    public let target: Target?
    public let isAuto: Bool

    public init(id: String, name: String, kind: KeptKind, target: Target?, isAuto: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
        self.isAuto = isAuto
    }
}

/// `POST /api/connections` answers `{ connected: [a, b], message }`.
public struct ArtifactConnected: Sendable, Decodable {
    public let message: String
}
