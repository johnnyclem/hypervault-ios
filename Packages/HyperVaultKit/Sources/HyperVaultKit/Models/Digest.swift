import Foundation

// Digest (docs/digestion.md, app/api/digest/**): a memory that is really many
// is proposed as a split, reviewed like a pull request, and applied as one
// commit that can be reverted.

public enum DigestStrategy: String, Sendable, Codable, Hashable {
    case chat, headings, rules, none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DigestStrategy(rawValue: raw) ?? .none
    }

    /// How the split was found, as the web says it.
    public var label: String {
        switch self {
        case .chat: return "chat transcript"
        case .headings: return "document sections"
        case .rules: return "thematic breaks"
        case .none: return "content"
        }
    }
}

public struct DigestSegment: Sendable, Codable, Identifiable, Hashable {
    public let ordinal: Int
    public let title: String
    public let summary: String
    public let tags: [String]
    /// Why the split falls here ("Speaker turn", "Section heading").
    public let reason: String

    public var id: Int { ordinal }

    public init(ordinal: Int, title: String, summary: String = "", tags: [String] = [], reason: String = "") {
        self.ordinal = ordinal
        self.title = title
        self.summary = summary
        self.tags = tags
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    enum Keys: String, CodingKey { case ordinal, title, summary, tags, reason }
}

/// A link the pieces will have once the split is applied.
public struct DigestLink: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case sequence, theme

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .sequence
        }
    }

    public let a: Int
    public let b: Int
    public let kind: Kind

    public init(a: Int, b: Int, kind: Kind) {
        self.a = a
        self.b = b
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        a = try c.decodeIfPresent(Int.self, forKey: .a) ?? 0
        b = try c.decodeIfPresent(Int.self, forKey: .b) ?? 0
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .sequence
    }

    enum Keys: String, CodingKey { case a, b, kind }
}

public struct DigestRun: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let sourceMemoryId: String
    public let sourceTitle: String
    public let strategy: DigestStrategy
    public let createdAt: Date?
    public let segments: [DigestSegment]
    public let links: [DigestLink]

    public init(
        id: String, sourceMemoryId: String, sourceTitle: String, strategy: DigestStrategy = .none, createdAt: Date? = nil,
        segments: [DigestSegment] = [], links: [DigestLink] = []
    ) {
        self.id = id
        self.sourceMemoryId = sourceMemoryId
        self.sourceTitle = sourceTitle
        self.strategy = strategy
        self.createdAt = createdAt
        self.segments = segments
        self.links = links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceMemoryId = try c.decodeIfPresent(String.self, forKey: .sourceMemoryId) ?? ""
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        strategy = try c.decodeIfPresent(DigestStrategy.self, forKey: .strategy) ?? .none
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        segments = try c.decodeIfPresent([DigestSegment].self, forKey: .segments) ?? []
        links = try c.decodeIfPresent([DigestLink].self, forKey: .links) ?? []
    }

    enum Keys: String, CodingKey { case id, sourceMemoryId, sourceTitle, strategy, createdAt, segments, links }

    public var themeLinkCount: Int { links.filter { $0.kind == .theme }.count }

    /// "Split "Trip notes"": the title, or a stand-in when the source has none.
    public var displayTitle: String { sourceTitle.isEmpty ? "Untitled memory" : sourceTitle }

    /// The line under the pieces: how they will be wired.
    public var linksLine: String {
        let theme = themeLinkCount
        let base = "The pieces stay chained in reading order"
        guard theme > 0 else { return base + "." }
        return base + ", plus \(theme) thematic link\(theme == 1 ? "" : "s") between related pieces."
    }
}

/// `GET /api/digest`: the review queue.
public struct DigestQueue: Sendable, Codable, Equatable {
    public let digestionEnabled: Bool
    public let runs: [DigestRun]

    public init(digestionEnabled: Bool = false, runs: [DigestRun] = []) {
        self.digestionEnabled = digestionEnabled
        self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        digestionEnabled = try c.decodeIfPresent(Bool.self, forKey: .digestionEnabled) ?? false
        runs = try c.decodeIfPresent([DigestRun].self, forKey: .runs) ?? []
    }

    enum Keys: String, CodingKey { case digestionEnabled, runs }
}

/// `GET` and `PUT /api/digest/settings`: the auto-digest switch.
public struct DigestSettings: Sendable, Codable, Equatable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    enum Keys: String, CodingKey { case enabled }
}

/// `POST /api/digest/run`: a split proposed for one memory. `runId` is nil
/// when the content reads as one thought; `message` says why.
public struct DigestProposal: Sendable, Codable, Equatable {
    public let runId: String?
    public let strategy: DigestStrategy
    public let segmentCount: Int
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        strategy = try c.decodeIfPresent(DigestStrategy.self, forKey: .strategy) ?? .none
        segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case runId, strategy, segmentCount, message }

    public var staged: Bool { runId != nil }
}

public enum DigestVerdict: String, Sendable, Hashable {
    case accept, reject
}

/// `POST /api/digest`: what a verdict did.
public struct DigestDecision: Sendable, Codable, Equatable {
    /// "applied" or "rejected".
    public let status: String
    public let created: Int
    public let links: Int
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        links = try c.decodeIfPresent(Int.self, forKey: .links) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case status, created, links, message }

    public var applied: Bool { status == "applied" }
}

extension Endpoint where Response == DigestQueue {
    public static var digestQueue: Endpoint<DigestQueue> {
        Endpoint(.get, "/api/digest")
    }
}

extension Endpoint where Response == DigestSettings {
    public static var digestSettings: Endpoint<DigestSettings> {
        Endpoint(.get, "/api/digest/settings")
    }

    public static func setDigesting(enabled: Bool) -> Endpoint<DigestSettings> {
        Endpoint(.put, "/api/digest/settings", body: .jsonValue(["enabled": .bool(enabled)]))
    }
}

extension Endpoint where Response == DigestProposal {
    /// "Digest this": stages a proposal to split one memory.
    public static func digestMemory(id: String, branch: String? = nil) -> Endpoint<DigestProposal> {
        var body: [String: JSONValue] = ["memoryId": .string(id)]
        if let branch { body["branch"] = .string(branch) }
        return Endpoint(.post, "/api/digest/run", body: .jsonValue(.object(body)), timeout: 90)
    }
}

extension Endpoint where Response == DigestDecision {
    /// Apply the split (accept) or keep the memory whole (reject).
    public static func digestDecide(run id: String, _ verdict: DigestVerdict) -> Endpoint<DigestDecision> {
        Endpoint(.post, "/api/digest", body: .jsonValue(["decision": .string(verdict.rawValue), "runId": .string(id)]), timeout: 60)
    }
}
