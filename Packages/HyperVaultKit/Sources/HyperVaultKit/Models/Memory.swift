import Foundation

// The memory wiki (docs/prd-7-imaging-v2-memory.md). Sources:
// app/api/memories/**, app/api/connections/route.ts, lib/memory.ts.

// MARK: Vocabulary

/// Where a memory came from, in the words a person would use.
public enum MemorySource {
    public static func label(_ source: String) -> String {
        switch source {
        case "manual", "": return "You"
        case "chat": return "Chat"
        case "coding": return "Coding"
        case "agent": return "Agent"
        case "file": return "File"
        case "github": return "Repository"
        case "web": return "Web page"
        case "polytician": return "Import"
        default: return String(source.prefix(1).uppercased()) + String(source.dropFirst())
        }
    }

    /// The values `POST /api/memories` accepts for `source`.
    public static let writable: [String] = ["manual", "chat", "coding", "agent"]
}

/// Which way recall ranked, as `recall_mode` says. Unknown values read as keyword.
public enum MemoryRecallMode: String, Sendable, Codable, Hashable {
    case lexical
    case hybrid
    case hybridLocal = "hybrid-local"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryRecallMode(rawValue: raw) ?? .lexical
    }

    /// "Meaning and keywords" or "Keywords".
    public var label: String {
        self == .lexical ? "Keywords" : "Meaning and keywords"
    }
}

// MARK: Reading

/// A memory in a list: no body.
public struct MemoryItem: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let createdAt: Date?

    public init(id: String, title: String, summary: String = "", tags: [String] = [], source: String = "manual", createdAt: Date? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, title, summary, tags, source, createdAt }

    public var sourceLabel: String { MemorySource.label(source) }
}

/// `GET /api/memories`: the branch's memories, newest first (at most 200).
public struct MemoryList: Sendable, Codable, Equatable {
    public let branch: String
    public let memories: [MemoryItem]

    public init(branch: String = MindBranchName.defaultName, memories: [MemoryItem] = []) {
        self.branch = branch
        self.memories = memories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        memories = try c.decodeIfPresent([MemoryItem].self, forKey: .memories) ?? []
    }

    enum Keys: String, CodingKey { case branch, memories }
}

/// The receipt on a memory: the commit that last touched it.
public struct MemoryProvenance: Sendable, Codable, Hashable {
    public let commitId: String
    public let message: String
    public let authorKind: MindAuthorKind
    public let authorKeyPrefix: String?
    public let committedAt: Date?

    public init(commitId: String, message: String, authorKind: MindAuthorKind = .user, authorKeyPrefix: String? = nil, committedAt: Date? = nil) {
        self.commitId = commitId
        self.message = message
        self.authorKind = authorKind
        self.authorKeyPrefix = authorKeyPrefix
        self.committedAt = committedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        authorKind = try c.decodeIfPresent(MindAuthorKind.self, forKey: .authorKind) ?? .user
        authorKeyPrefix = try c.decodeIfPresent(String.self, forKey: .authorKeyPrefix)
        committedAt = try c.decodeIfPresent(Date.self, forKey: .committedAt)
    }

    enum Keys: String, CodingKey { case commitId, message, authorKind, authorKeyPrefix, committedAt }

    public var shortCommitId: String { String(commitId.prefix(8)) }
    public var author: String { authorKind.label(keyPrefix: authorKeyPrefix) }
}

/// One match from recall. The best few carry `content`, the exact stored chunk.
public struct MemoryRecallHit: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let createdAt: Date?
    public let score: Double
    public let content: String?
    /// Titles of the memories this one links to.
    public let related: [String]
    public let provenance: MemoryProvenance?

    public init(
        id: String, title: String, summary: String = "", tags: [String] = [], source: String = "manual",
        createdAt: Date? = nil, score: Double = 0, content: String? = nil, related: [String] = [],
        provenance: MemoryProvenance? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.score = score
        self.content = content
        self.related = related
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        content = try c.decodeIfPresent(String.self, forKey: .content)
        related = try c.decodeIfPresent([String].self, forKey: .related) ?? []
        provenance = try c.decodeIfPresent(MemoryProvenance.self, forKey: .provenance)
    }

    enum Keys: String, CodingKey { case id, title, summary, tags, source, createdAt, score, content, related, provenance }

    public var item: MemoryItem {
        MemoryItem(id: id, title: title, summary: summary, tags: tags, source: source, createdAt: createdAt)
    }
}

/// `GET /api/memories?q=`: natural-language recall.
public struct MemoryRecall: Sendable, Codable, Equatable {
    public let query: String
    public let branch: String
    public let recallMode: MemoryRecallMode
    public let results: [MemoryRecallHit]
    /// The server's sentence: "Recalled 3 matching memories." or "Nothing in memory matches that yet. Keep something first."
    public let message: String

    public init(query: String, branch: String = MindBranchName.defaultName, recallMode: MemoryRecallMode = .lexical, results: [MemoryRecallHit] = [], message: String = "") {
        self.query = query
        self.branch = branch
        self.recallMode = recallMode
        self.results = results
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        recallMode = try c.decodeIfPresent(MemoryRecallMode.self, forKey: .recallMode) ?? .lexical
        results = try c.decodeIfPresent([MemoryRecallHit].self, forKey: .results) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case query, branch, recallMode, results, message }
}

extension MemoryRecallHit {
    /// The part of the stored chunk worth showing under a match: the first
    /// `limit` characters on a word boundary. Nil when the server sent no
    /// chunk or it adds nothing to the summary.
    public func excerpt(limit: Int = 240) -> String? {
        guard let content else { return nil }
        let flat = content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !flat.isEmpty, flat != summary else { return nil }
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

/// A memory with its body.
public struct MemoryFull: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let content: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let createdAt: Date?

    public init(id: String, title: String, content: String, summary: String = "", tags: [String] = [], source: String = "manual", createdAt: Date? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.summary = summary
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, title, content, summary, tags, source, createdAt }

    public var sourceLabel: String { MemorySource.label(source) }
    public var item: MemoryItem {
        MemoryItem(id: id, title: title, summary: summary, tags: tags, source: source, createdAt: createdAt)
    }
}

/// A page the memory is bridged to.
public struct MemoryArtifactRef: Sendable, Codable, Identifiable, Hashable {
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "page"
    }

    enum Keys: String, CodingKey { case id, slug, title, type }
}

/// One of the truths a memory rests on (docs/truth-graph.md). The Truth
/// screens own the entries themselves; the memory only says which it leans on
/// and whether any has moved since.
public struct MemoryTruthEdge: Sendable, Codable, Hashable, Identifiable {
    public let ledger: String
    public let entryId: String
    public let entryText: String
    public let relation: String
    public let staleSince: Date?
    public let staleSummary: String?

    public var id: String { "\(ledger)/\(entryId)" }
    public var isStale: Bool { staleSince != nil }

    public init(ledger: String, entryId: String, entryText: String, relation: String = "rests_on", staleSince: Date? = nil, staleSummary: String? = nil) {
        self.ledger = ledger
        self.entryId = entryId
        self.entryText = entryText
        self.relation = relation
        self.staleSince = staleSince
        self.staleSummary = staleSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ledger = try c.decodeIfPresent(String.self, forKey: .ledger) ?? ""
        let entry = try c.decodeIfPresent(Entry.self, forKey: .entry)
        let storedId = try c.decodeIfPresent(String.self, forKey: .entryId)
        let storedText = try c.decodeIfPresent(String.self, forKey: .entryText)
        entryId = entry?.id ?? storedId ?? ""
        entryText = entry?.text ?? storedText ?? ""
        relation = try c.decodeIfPresent(String.self, forKey: .relation) ?? "rests_on"
        staleSince = try c.decodeIfPresent(Date.self, forKey: .staleSince)
        staleSummary = try c.decodeIfPresent(String.self, forKey: .staleSummary)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(ledger, forKey: .ledger)
        try c.encode(entryId, forKey: .entryId)
        try c.encode(entryText, forKey: .entryText)
        try c.encode(relation, forKey: .relation)
        try c.encodeIfPresent(staleSince, forKey: .staleSince)
        try c.encodeIfPresent(staleSummary, forKey: .staleSummary)
    }

    enum Keys: String, CodingKey { case ledger, entry, entryId, entryText, relation, staleSince, staleSummary }

    private struct Entry: Decodable {
        let id: String?
        let text: String?
    }
}

public struct MemoryTruth: Sendable, Codable, Hashable {
    public let restsOn: [MemoryTruthEdge]
    public let stale: Int

    public init(restsOn: [MemoryTruthEdge] = [], stale: Int = 0) {
        self.restsOn = restsOn
        self.stale = stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        restsOn = try c.decodeIfPresent([MemoryTruthEdge].self, forKey: .restsOn) ?? []
        stale = try c.decodeIfPresent(Int.self, forKey: .stale) ?? 0
    }

    enum Keys: String, CodingKey { case restsOn, stale }
}

/// A memory this one links to.
public struct MemoryRelated: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]

    public init(id: String, title: String, summary: String = "", tags: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    enum Keys: String, CodingKey { case id, title, summary, tags }
}

/// `GET /api/memories/[id]`: one page, with its neighbours and receipt.
public struct MemoryPage: Sendable, Codable, Equatable {
    public let branch: String
    public let memory: MemoryFull
    public let related: [MemoryRelated]
    public let artifacts: [MemoryArtifactRef]
    public let provenance: MemoryProvenance?
    public let revisionCount: Int
    public let truth: MemoryTruth?

    public init(
        branch: String = MindBranchName.defaultName, memory: MemoryFull, related: [MemoryRelated] = [],
        artifacts: [MemoryArtifactRef] = [], provenance: MemoryProvenance? = nil, revisionCount: Int = 0, truth: MemoryTruth? = nil
    ) {
        self.branch = branch
        self.memory = memory
        self.related = related
        self.artifacts = artifacts
        self.provenance = provenance
        self.revisionCount = revisionCount
        self.truth = truth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        memory = try c.decode(MemoryFull.self, forKey: .memory)
        related = try c.decodeIfPresent([MemoryRelated].self, forKey: .related) ?? []
        artifacts = try c.decodeIfPresent([MemoryArtifactRef].self, forKey: .artifacts) ?? []
        provenance = try c.decodeIfPresent(MemoryProvenance.self, forKey: .provenance)
        revisionCount = try c.decodeIfPresent(Int.self, forKey: .revisionCount) ?? 0
        truth = try c.decodeIfPresent(MemoryTruth.self, forKey: .truth)
    }

    enum Keys: String, CodingKey { case branch, memory, related, artifacts, provenance, revisionCount, truth }
}

// MARK: History

/// The commit behind one revision.
public struct MemoryRevisionCommit: Sendable, Codable, Hashable {
    public let id: String
    public let message: String
    public let authorKind: MindAuthorKind
    public let authorKeyPrefix: String?
    public let branch: String?
    public let createdAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        authorKind = try c.decodeIfPresent(MindAuthorKind.self, forKey: .authorKind) ?? .user
        authorKeyPrefix = try c.decodeIfPresent(String.self, forKey: .authorKeyPrefix)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public init(id: String, message: String, authorKind: MindAuthorKind = .user, authorKeyPrefix: String? = nil, branch: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.message = message
        self.authorKind = authorKind
        self.authorKeyPrefix = authorKeyPrefix
        self.branch = branch
        self.createdAt = createdAt
    }

    enum Keys: String, CodingKey { case id, message, authorKind, authorKeyPrefix, branch, createdAt }

    public var author: String { authorKind.label(keyPrefix: authorKeyPrefix) }
}

/// One saved version of a memory.
public struct MemoryRevision: Sendable, Codable, Identifiable, Hashable {
    public let revisionId: String
    public let op: MindOp
    public let title: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let content: String?
    public let commit: MemoryRevisionCommit?

    public var id: String { revisionId }

    public init(
        revisionId: String, op: MindOp = .update, title: String, summary: String = "", tags: [String] = [],
        source: String = "manual", content: String? = nil, commit: MemoryRevisionCommit? = nil
    ) {
        self.revisionId = revisionId
        self.op = op
        self.title = title
        self.summary = summary
        self.tags = tags
        self.source = source
        self.content = content
        self.commit = commit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        revisionId = try c.decode(String.self, forKey: .revisionId)
        op = try c.decodeIfPresent(MindOp.self, forKey: .op) ?? .update
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        content = try c.decodeIfPresent(String.self, forKey: .content)
        commit = try c.decodeIfPresent(MemoryRevisionCommit.self, forKey: .commit)
    }

    enum Keys: String, CodingKey { case revisionId, op, title, summary, tags, source, content, commit }
}

/// `GET /api/memories/[id]/history`, newest first.
public struct MemoryHistory: Sendable, Codable, Equatable {
    public let memoryId: String
    public let revisions: [MemoryRevision]

    public init(memoryId: String, revisions: [MemoryRevision] = []) {
        self.memoryId = memoryId
        self.revisions = revisions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        memoryId = try c.decodeIfPresent(String.self, forKey: .memoryId) ?? ""
        revisions = try c.decodeIfPresent([MemoryRevision].self, forKey: .revisions) ?? []
    }

    enum Keys: String, CodingKey { case memoryId, revisions }

    /// The newest version that was not the memory being forgotten: what to
    /// bring back when someone forgot it by mistake.
    public var lastLive: MemoryRevision? {
        revisions.first { $0.op != .delete }
    }

    /// The version the memory had at a moment, or nil when it did not exist
    /// then (not yet written, or already forgotten).
    public func revision(asOf date: Date) -> MemoryRevision? {
        guard let latest = revisions.first(where: { ($0.commit?.createdAt ?? .distantFuture) <= date }) else { return nil }
        return latest.op == .delete ? nil : latest
    }

    /// The most revisions the route gives for one memory.
    public static let maxLimit = 200

    /// The revision a branch's state row stands for. History lists the revisions of every branch, so a moment
    /// alone can land on another branch's edit. A row names its version by when its commit was made, and a commit
    /// makes its revisions at that moment, so the time is matched first. A memory that predates branches has its
    /// original time on its first revision and the commit's on the commit, so failing that, what the row says.
    public func revision(for row: MindStateMemory) -> MemoryRevision? {
        let live = revisions.filter { $0.op != .delete }
        if let committed = row.committedAt,
           let exact = live.first(where: { revision in revision.commit?.createdAt.map { abs($0.timeIntervalSince(committed)) < 0.001 } ?? false }) {
            return exact
        }
        return live.first { $0.title == row.title && $0.summary == row.summary && Set($0.tags) == Set(row.tags) }
    }

    /// The revision a diff of `revision` reads against: the next older one.
    public func previous(of revision: MemoryRevision) -> MemoryRevision? {
        guard let index = revisions.firstIndex(where: { $0.revisionId == revision.revisionId }) else { return nil }
        let next = revisions.index(after: index)
        return next < revisions.endIndex ? revisions[next] : nil
    }
}

// MARK: Writing

/// What `POST /api/memories` and `POST /api/memories/import` answer.
public struct MemoryKept: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]
    public let source: String
    /// How many other memories it was linked to.
    public let links: Int
    public let branch: String
    public let commitId: String?
    /// The server's sentence. Narrate it as written.
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        links = try c.decodeIfPresent(Int.self, forKey: .links) ?? 0
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case id, title, summary, tags, source, links, branch, commitId, message }

    /// The list row this write adds.
    public func item(now: Date = Date()) -> MemoryItem {
        MemoryItem(id: id, title: title, summary: summary, tags: tags, source: source, createdAt: now)
    }
}

/// `PATCH /api/memories/[id]`.
public struct MemoryEdited: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]
    public let branch: String
    public let commitId: String?
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case id, title, summary, tags, branch, commitId, message }
}

/// `DELETE /api/memories/[id]`.
public struct MemoryForgotten: Sendable, Codable, Equatable {
    public let deleted: String
    public let branch: String
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        deleted = try c.decodeIfPresent(String.self, forKey: .deleted) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case deleted, branch, message }
}

/// A memory being written: what the Memorize sheet holds.
public struct MemoryDraft: Sendable, Equatable {
    public var content = ""
    public var title = ""
    public var tagsText = ""
    public var source = "manual"

    public init(content: String = "", title: String = "", tagsText: String = "", source: String = "manual") {
        self.content = content
        self.title = title
        self.tagsText = tagsText
        self.source = source
    }

    public var trimmedContent: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var tags: [String] { MemoryTags.parse(tagsText) }

    /// The server's sentence for a draft it would refuse, or nil when it is fine.
    public func problem(limitBytes: Int) -> String? {
        if trimmedContent.isEmpty { return "content is required — the text to memorize." }
        if trimmedContent.utf8.count > limitBytes {
            return "That chunk is over the \(MemoryLimits.label(forBytes: limitBytes)) memory limit — split it into smaller memories."
        }
        return nil
    }

    var request: MemoryCreateRequest {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryCreateRequest(
            content: trimmedContent,
            title: name.isEmpty ? nil : name,
            tags: tags.isEmpty ? nil : tags,
            source: MemorySource.writable.contains(source) ? source : nil
        )
    }
}

struct MemoryCreateRequest: Sendable, Encodable {
    var content: String
    var title: String?
    var tags: [String]?
    var source: String?
    var branch: String?
}

/// The edit to send, built from what was changed. Nil when nothing was.
public struct MemoryEditRequest: Sendable, Encodable, Equatable {
    public var title: String?
    public var content: String?
    public var tags: [String]?
    public var branch: String?
    public var message: String?

    /// Compares an editor's state with the memory it opened; only the fields
    /// that differ are sent (the server refuses an edit that changes nothing).
    public static func make(
        original: MemoryFull, title: String, content: String, tags: [String], message: String = "", branch: String? = nil
    ) -> MemoryEditRequest? {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = MemoryEditRequest(branch: branch)
        var changed = false
        if !newTitle.isEmpty, newTitle != original.title {
            request.title = newTitle
            changed = true
        }
        if !newContent.isEmpty, newContent != original.content.trimmingCharacters(in: .whitespacesAndNewlines) {
            request.content = newContent
            changed = true
        }
        let cleaned = MemoryTags.clean(tags)
        if cleaned != original.tags {
            request.tags = cleaned
            changed = true
        }
        guard changed else { return nil }
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { request.message = note }
        return request
    }
}

public enum MemoryTags {
    public static let maxCount = 12

    /// Tags from what someone typed: split on commas and new lines, `#` dropped,
    /// duplicates (ignoring case) removed, at most twelve.
    public static func parse(_ text: String) -> [String] {
        clean(text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init))
    }

    public static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            out.append(tag)
            if out.count == maxCount { break }
        }
        return out
    }
}

public enum MemoryLimits {
    /// "500 kB", "4 MB".
    public static func label(forBytes bytes: Int) -> String {
        if bytes >= 1_000_000 {
            let mb = Double(bytes) / 1_000_000
            return mb == mb.rounded() ? "\(Int(mb)) MB" : String(format: "%.1f MB", mb)
        }
        return "\(max(bytes / 1000, 1)) kB"
    }
}

// MARK: Importing

/// What the import route takes (app/api/memories/import/route.ts, lib/ingest/files.ts).
public enum MemoryImportPolicy {
    public static let maxFileBytes = 4_000_000
    public static let maxFileLabel = "4 MB"
    public static let extensions = ["pdf", "docx", "md", "markdown", "mdx", "txt", "text"]
    public static let unsupportedTypeMessage = "Unsupported file type — import a PDF, DOCX, .md, or .txt file."

    public enum FileKind: String, Sendable, Hashable {
        case pdf, docx, markdown, text

        public var mimeType: String {
            switch self {
            case .pdf: return "application/pdf"
            case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case .markdown: return "text/markdown"
            case .text: return "text/plain"
            }
        }
    }

    public static func kind(forFilename name: String) -> FileKind? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        switch name[name.index(after: dot)...].lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "md", "markdown", "mdx": return .markdown
        case "txt", "text": return .text
        default: return nil
        }
    }

    /// The sentence for a file that would be refused before it is sent, or nil.
    public static func problem(filename: String, byteCount: Int) -> String? {
        if byteCount > maxFileBytes {
            return "\"\(filename)\" is over the \(maxFileLabel) import limit — split it or trim it down."
        }
        if kind(forFilename: filename) == nil { return unsupportedTypeMessage }
        return nil
    }

    /// What to say for a refused import. The server's sentence goes through as
    /// written; a 413 that never reached it (the platform's plain-text answer
    /// to a body that is too big) gets the sentence the web app uses.
    public static func message(for error: HVError) -> String {
        if case .api(let failure) = error, failure.status == 413, failure.body == nil {
            return "That upload is too large — the import limit is \(maxFileLabel)."
        }
        return error.userMessage
    }

    /// Whether a link is plausibly something the importer can fetch.
    public static func normalizedURL(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".")
        else { return nil }
        return trimmed
    }
}

// MARK: Recall, on the device

/// A small copy of the server's keyword scoring (lib/memory.ts `scoreRecall`),
/// so the list narrows as someone types, before the server's recall answers.
public enum MemoryRecallScorer {
    private static let stopwords: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "asked",
        "back", "based", "be", "because", "been", "before", "being", "but", "can",
        "could", "did", "do", "does", "doing", "down", "each", "few", "for", "from",
        "get", "got", "had", "has", "have", "having", "her", "here", "him", "his",
        "how", "however", "i'm", "into", "it's", "its", "just", "let", "like",
        "made", "make", "many", "may", "me", "might", "more", "most", "much", "my",
        "need", "new", "not", "now", "of", "off", "on", "one", "only", "or",
        "other", "our", "out", "over", "own", "said", "same", "say", "see",
        "she", "should", "so", "some", "such", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "through",
        "to", "too", "under", "up", "us", "use", "used", "using", "very", "want",
        "was", "way", "we", "well", "were", "what", "when", "where", "which",
        "while", "who", "why", "will", "with", "would", "you", "your",
    ]

    /// Meaningful lowercase words: three or more characters, no filler.
    /// Letters of any alphabet count (the server only keeps a-z).
    public static func keywords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || "'+#.-".contains($0)) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".'-")) }
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// The server's score: 3 for a title or tag word, 2 for a summary word, 1 for a body word.
    public static func score(query: String, title: String, summary: String, tags: [String]) -> Int {
        let words = Set(keywords(query))
        guard !words.isEmpty else { return 0 }
        let titleWords = Set(keywords(title))
        let summaryWords = Set(keywords(summary))
        let tagSet = Set(tags.map { $0.lowercased() })
        var total = 0
        for word in words {
            if titleWords.contains(word) { total += 3 }
            if tagSet.contains(word) { total += 3 }
            if summaryWords.contains(word) { total += 2 }
        }
        return total
    }

    /// Narrows a list to what the words so far could mean: the server's score
    /// plus a word that merely starts like a query word (so "arch" finds
    /// "architecture" while it is being typed). Best match first; ties keep the
    /// list's order (newest first).
    public static func rank(_ query: String, in items: [MemoryItem]) -> [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
        let scored: [(index: Int, item: MemoryItem, score: Int)] = items.enumerated().compactMap { (index, item) -> (index: Int, item: MemoryItem, score: Int)? in
            var total = score(query: trimmed, title: item.title, summary: item.summary, tags: item.tags)
            let titleLower = item.title.lowercased()
            let summaryLower = item.summary.lowercased()
            let tagsLower = item.tags.map { $0.lowercased() }
            for word in words {
                if titleLower.contains(word) { total += 2 }
                if tagsLower.contains(where: { $0.hasPrefix(word) }) { total += 1 }
                if summaryLower.contains(word) { total += 1 }
            }
            return total > 0 ? (index: index, item: item, score: total) : nil
        }
        return scored
            .sorted { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index }
            .map(\.item)
    }
}

// MARK: Connections (the graph's edges)

public enum MemoryLinkKind: String, Sendable, Codable, Hashable {
    case manual, auto

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryLinkKind(rawValue: raw) ?? .auto
    }
}

public struct MemoryLinkRow: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let aId: String
    public let bId: String
    public let kind: MemoryLinkKind

    public init(id: String, aId: String, bId: String, kind: MemoryLinkKind = .auto) {
        self.id = id
        self.aId = aId
        self.bId = bId
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        aId = try c.decode(String.self, forKey: .aId)
        bId = try c.decode(String.self, forKey: .bId)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(aId):\(bId)"
        kind = try c.decodeIfPresent(MemoryLinkKind.self, forKey: .kind) ?? .auto
    }

    enum Keys: String, CodingKey { case id, aId, bId, kind }
}

/// A memory bridged to a page.
public struct MemoryBridgeRow: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let memoryId: String
    public let artifactId: String
    public let kind: MemoryLinkKind

    public init(id: String, memoryId: String, artifactId: String, kind: MemoryLinkKind = .auto) {
        self.id = id
        self.memoryId = memoryId
        self.artifactId = artifactId
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        memoryId = try c.decode(String.self, forKey: .memoryId)
        artifactId = try c.decode(String.self, forKey: .artifactId)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(memoryId):\(artifactId)"
        kind = try c.decodeIfPresent(MemoryLinkKind.self, forKey: .kind) ?? .auto
    }

    enum Keys: String, CodingKey { case id, memoryId, artifactId, kind }
}

/// `GET /api/connections`: every edge the caller owns. Memory links are those
/// of the main branch.
public struct MemoryConnections: Sendable, Codable, Equatable {
    public let memoryLinks: [MemoryLinkRow]
    public let bridges: [MemoryBridgeRow]

    public init(memoryLinks: [MemoryLinkRow] = [], bridges: [MemoryBridgeRow] = []) {
        self.memoryLinks = memoryLinks
        self.bridges = bridges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        memoryLinks = try c.decodeIfPresent([MemoryLinkRow].self, forKey: .memoryLinks) ?? []
        bridges = try c.decodeIfPresent([MemoryBridgeRow].self, forKey: .memoryArtifactLinks) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(memoryLinks, forKey: .memoryLinks)
        try c.encode(bridges, forKey: .memoryArtifactLinks)
    }

    enum Keys: String, CodingKey { case memoryLinks, memoryArtifactLinks }
}

/// `POST /api/connections`: two things joined by hand.
public struct MemoryConnected: Sendable, Codable, Equatable {
    public let connected: [String]
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        connected = try c.decodeIfPresent([String].self, forKey: .connected) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case connected, message }
}

// MARK: Ask

/// A connected model that can answer a question (`GET /api/backends`). Only
/// what asking needs; the Chat feature owns the rest.
public struct MemoryAskBackend: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let defaultModel: String?

    public init(id: String, name: String, defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.defaultModel = defaultModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Backend"
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
    }

    enum Keys: String, CodingKey { case id, name, defaultModel }
}

struct MemoryAskBackends: Sendable, Decodable {
    let backends: [MemoryAskBackend]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        backends = try c.decodeIfPresent([MemoryAskBackend].self, forKey: .backends) ?? []
    }

    enum Keys: String, CodingKey { case backends }
}

/// One answer from `POST /api/chat` with wiki recall on.
public struct MemoryAnswer: Sendable, Equatable {
    public let conversationId: String
    public let text: String
    public let model: String?
    public let truncated: Bool
    /// Titles of the memories the model was handed.
    public let recalled: [String]
}

extension MemoryAnswer: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        let reply = try c.decodeIfPresent(Reply.self, forKey: .reply)
        text = reply?.content ?? ""
        model = reply?.model
        truncated = reply?.truncated ?? false
        recalled = try c.decodeIfPresent([String].self, forKey: .recalledMemories) ?? []
    }

    enum Keys: String, CodingKey { case conversationId, reply, recalledMemories }

    private struct Reply: Decodable {
        let content: String?
        let model: String?
        let truncated: Bool?
    }
}

// MARK: Endpoints

extension Endpoint where Response == MemoryList {
    public static func memoryList(branch: String? = nil) -> Endpoint<MemoryList> {
        Endpoint(.get, "/api/memories", query: .make([("branch", branch)]))
    }
}

extension Endpoint where Response == MemoryRecall {
    public static func memoryRecall(_ query: String, branch: String? = nil) -> Endpoint<MemoryRecall> {
        Endpoint(.get, "/api/memories", query: .make([("q", query.trimmingCharacters(in: .whitespacesAndNewlines)), ("branch", branch)]))
    }
}

extension Endpoint where Response == MemoryPage {
    public static func memoryPage(id: String, branch: String? = nil) -> Endpoint<MemoryPage> {
        Endpoint(.get, "/api/memories/\(id)", query: .make([("branch", branch)]))
    }
}

extension Endpoint where Response == MemoryHistory {
    /// `full` includes each revision's text.
    public static func memoryHistory(id: String, full: Bool = false, limit: Int? = nil) -> Endpoint<MemoryHistory> {
        Endpoint(.get, "/api/memories/\(id)/history", query: .make([("full", full ? "1" : nil), ("limit", limit.map(String.init))]))
    }
}

extension Endpoint where Response == MemoryKept {
    /// "Memorize this."
    public static func memoryCreate(_ draft: MemoryDraft, branch: String? = nil) -> Endpoint<MemoryKept> {
        var request = draft.request
        request.branch = branch
        return Endpoint(.post, "/api/memories", body: .json(request))
    }

    /// A document (PDF, DOCX, Markdown, text) becomes a memory.
    public static func memoryImport(filename: String, data: Data, branch: String? = nil) -> Endpoint<MemoryKept> {
        var form = MultipartForm()
        let mime = MemoryImportPolicy.kind(forFilename: filename)?.mimeType ?? "application/octet-stream"
        form.addFile("file", filename: filename, mimeType: mime, data: data)
        return Endpoint(.post, "/api/memories/import", query: .make([("branch", branch)]), body: .multipart(form), timeout: 90)
    }

    /// A GitHub repository becomes a project digest; any other page becomes a note.
    public static func memoryImport(url: String, branch: String? = nil) -> Endpoint<MemoryKept> {
        Endpoint(.post, "/api/memories/import", query: .make([("branch", branch)]), body: .jsonValue(["url": .string(url)]), timeout: 90)
    }
}

extension Endpoint where Response == MemoryEdited {
    public static func memoryEdit(id: String, _ request: MemoryEditRequest) -> Endpoint<MemoryEdited> {
        Endpoint(.patch, "/api/memories/\(id)", body: .json(request))
    }
}

extension Endpoint where Response == MemoryForgotten {
    public static func memoryForget(id: String, branch: String? = nil) -> Endpoint<MemoryForgotten> {
        Endpoint(.delete, "/api/memories/\(id)", query: .make([("branch", branch)]))
    }
}

extension Endpoint where Response == MemoryConnections {
    public static var memoryConnections: Endpoint<MemoryConnections> {
        Endpoint(.get, "/api/connections")
    }
}

extension Endpoint where Response == MemoryConnected {
    /// Links a memory to another memory or to a page. Memory links are commits on main.
    public static func memoryConnect(source: String, target: String) -> Endpoint<MemoryConnected> {
        Endpoint(.post, "/api/connections", body: .jsonValue(["source": .string(source), "target": .string(target)]))
    }
}

extension Endpoint where Response == MemoryAnswer {
    /// One turn of chat with wiki recall on, as the web's Ask mode sends it. `recallBranch` is the branch the
    /// answer is written from; the route reads main when it is left out.
    public static func memoryAsk(
        backendId: String, message: String, conversationId: String? = nil, recallBranch: String? = nil
    ) -> Endpoint<MemoryAnswer> {
        var body: [String: JSONValue] = [
            "backend_id": .string(backendId),
            "message": .string(message),
            "use_recall": .bool(true),
        ]
        if let conversationId { body["conversation_id"] = .string(conversationId) }
        if let recallBranch, !recallBranch.isEmpty, recallBranch != MindBranchName.defaultName { body["recall_branch"] = .string(recallBranch) }
        return Endpoint(.post, "/api/chat", body: .jsonValue(.object(body)), timeout: 120)
    }
}

extension Endpoint where Response == [MemoryAskBackend] {
    public static var memoryAskBackends: Endpoint<[MemoryAskBackend]> {
        Endpoint(
            method: .get, path: "/api/backends"
        ) { response, keys in
            (try HVCoding.decoder(keys).decode(MemoryAskBackends.self, from: response.data)).backends
        }
    }
}
