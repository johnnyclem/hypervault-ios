import Foundation

// Dreams (README "dreaming", lib/dreaming.ts, app/api/dreams/**): the nightly
// pass that looks for connections nobody made by hand, staged for review like
// a pull request. Nothing touches the graph until it is accepted.

public enum DreamEdgeType: String, Sendable, Codable, Hashable {
    case artifactArtifact = "artifact_artifact"
    case memoryMemory = "memory_memory"
    case memoryArtifact = "memory_artifact"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DreamEdgeType(rawValue: raw) ?? .memoryMemory
    }

    public var label: String {
        switch self {
        case .artifactArtifact: return "Page to page"
        case .memoryMemory: return "Memory to memory"
        case .memoryArtifact: return "Memory to page"
        }
    }
}

/// One end of a proposed connection.
public struct DreamEndpoint: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case artifact, memory

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .memory
        }
    }

    public let kind: Kind
    public let id: String
    public let label: String
    public let slug: String?

    public init(kind: Kind, id: String, label: String, slug: String? = nil) {
        self.kind = kind
        self.id = id
        self.label = label
        self.slug = slug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .memory
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Untitled"
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
    }

    enum Keys: String, CodingKey { case kind, id, label, slug }

    /// The endpoint no longer exists ("(deleted memory)").
    public var isGone: Bool { label.hasPrefix("(deleted") }
}

public struct DreamConnection: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let edgeType: DreamEdgeType
    public let score: Double
    public let reason: String
    public let a: DreamEndpoint
    public let b: DreamEndpoint

    public init(id: String, edgeType: DreamEdgeType, score: Double = 0, reason: String = "", a: DreamEndpoint, b: DreamEndpoint) {
        self.id = id
        self.edgeType = edgeType
        self.score = score
        self.reason = reason
        self.a = a
        self.b = b
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        edgeType = try c.decodeIfPresent(DreamEdgeType.self, forKey: .edgeType) ?? .memoryMemory
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        a = try c.decode(DreamEndpoint.self, forKey: .a)
        b = try c.decode(DreamEndpoint.self, forKey: .b)
    }

    enum Keys: String, CodingKey { case id, edgeType, score, reason, a, b }
}

/// One night's pass and the connections still waiting for a verdict.
public struct DreamRun: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let createdAt: Date?
    public var connections: [DreamConnection]

    public init(id: String, createdAt: Date? = nil, connections: [DreamConnection] = []) {
        self.id = id
        self.createdAt = createdAt
        self.connections = connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        connections = try c.decodeIfPresent([DreamConnection].self, forKey: .connections) ?? []
    }

    enum Keys: String, CodingKey { case id, createdAt, connections }
}

/// `GET /api/dreams`: the review queue.
public struct DreamQueue: Sendable, Codable, Equatable {
    public let dreamingEnabled: Bool
    public let lastRunAt: Date?
    public let pendingCount: Int
    public let runs: [DreamRun]

    public init(dreamingEnabled: Bool = false, lastRunAt: Date? = nil, pendingCount: Int? = nil, runs: [DreamRun] = []) {
        self.dreamingEnabled = dreamingEnabled
        self.lastRunAt = lastRunAt
        self.pendingCount = pendingCount ?? runs.reduce(0) { $0 + $1.connections.count }
        self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        dreamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .dreamingEnabled) ?? false
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        runs = try c.decodeIfPresent([DreamRun].self, forKey: .runs) ?? []
        pendingCount = try c.decodeIfPresent(Int.self, forKey: .pendingCount) ?? runs.reduce(0) { $0 + $1.connections.count }
    }

    enum Keys: String, CodingKey { case dreamingEnabled, lastRunAt, pendingCount, runs }
}

/// `GET` and `PUT /api/dreams/settings`.
public struct DreamSettings: Sendable, Codable, Equatable {
    public let enabled: Bool
    public let lastRunAt: Date?

    public init(enabled: Bool, lastRunAt: Date? = nil) {
        self.enabled = enabled
        self.lastRunAt = lastRunAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    enum Keys: String, CodingKey { case enabled, lastRunAt }
}

/// `POST /api/dreams/run`: a pass on demand. The route does the work before it
/// answers, so `jobId` is nil today; if a server ever hands the pass to a
/// background job, it is here and `BackgroundJobPoller` follows it.
public struct DreamRunResult: Sendable, Codable, Equatable {
    public let runId: String?
    public let jobId: String?
    public let total: Int
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        let counts = try c.decodeIfPresent(Counts.self, forKey: .counts)
        total = counts?.total ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(runId, forKey: .runId)
        try c.encodeIfPresent(jobId, forKey: .jobId)
        try c.encode(Counts(total: total), forKey: .counts)
        try c.encode(message, forKey: .message)
    }

    enum Keys: String, CodingKey { case runId, jobId, counts, message }

    struct Counts: Codable {
        var total: Int

        init(total: Int) {
            self.total = total
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        }

        enum Keys: String, CodingKey { case total }
    }

    /// The pass found nothing new.
    public var foundNothing: Bool { runId == nil && jobId == nil }
}

public enum DreamVerdict: String, Sendable, Hashable {
    case accept, reject
}

/// `POST /api/dreams`: what a verdict did. A connection that could not be
/// woven in stays pending and is listed in `failures`.
public struct DreamDecision: Sendable, Codable, Equatable {
    public struct Failure: Sendable, Codable, Hashable {
        public let id: String
        public let error: String

        public init(id: String, error: String) {
            self.id = id
            self.error = error
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? "unknown error"
        }

        enum Keys: String, CodingKey { case id, error }
    }

    public let accepted: Int
    public let rejected: Int
    public let failures: [Failure]
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        failures = try c.decodeIfPresent([Failure].self, forKey: .failures) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case accepted, rejected, failures, message }
}

/// The queue as someone works through it. Verdicts take effect on screen at
/// once and are put back if the server refuses; the tallies are this
/// sitting's, for the "all caught up" line.
public struct DreamReview: Sendable, Equatable {
    public private(set) var runs: [DreamRun]
    public private(set) var acceptedThisSitting = 0
    public private(set) var rejectedThisSitting = 0

    public init(runs: [DreamRun] = []) {
        self.runs = runs.filter { !$0.connections.isEmpty }
    }

    /// Where a removed connection sat, so a refusal can put it back.
    public struct Removal: Sendable, Equatable {
        public let runId: String
        public let runCreatedAt: Date?
        public let runIndex: Int
        public let connections: [(index: Int, connection: DreamConnection)]

        public static func == (lhs: Removal, rhs: Removal) -> Bool {
            lhs.runId == rhs.runId && lhs.runIndex == rhs.runIndex && lhs.connections.map(\.connection) == rhs.connections.map(\.connection)
        }
    }

    public var pendingCount: Int { runs.reduce(0) { $0 + $1.connections.count } }
    public var isEmpty: Bool { runs.isEmpty }

    /// Replaces the queue with a fresh answer from the server.
    public mutating func replace(with runs: [DreamRun]) {
        self.runs = runs.filter { !$0.connections.isEmpty }
    }

    public func connection(_ id: String) -> DreamConnection? {
        runs.lazy.flatMap { $0.connections }.first { $0.id == id }
    }

    /// Takes one connection off the queue (a run with nothing left goes too).
    @discardableResult
    public mutating func remove(connection id: String, verdict: DreamVerdict) -> Removal? {
        for (runIndex, run) in runs.enumerated() {
            guard let index = run.connections.firstIndex(where: { $0.id == id }) else { continue }
            let connection = run.connections[index]
            let removal = Removal(runId: run.id, runCreatedAt: run.createdAt, runIndex: runIndex, connections: [(index, connection)])
            runs[runIndex].connections.remove(at: index)
            if runs[runIndex].connections.isEmpty { runs.remove(at: runIndex) }
            tally(verdict, 1)
            return removal
        }
        return nil
    }

    /// Takes a whole run off the queue.
    @discardableResult
    public mutating func remove(run id: String, verdict: DreamVerdict) -> Removal? {
        guard let runIndex = runs.firstIndex(where: { $0.id == id }) else { return nil }
        let run = runs[runIndex]
        let removal = Removal(
            runId: run.id, runCreatedAt: run.createdAt, runIndex: runIndex,
            connections: run.connections.enumerated().map { (index: $0.offset, connection: $0.element) }
        )
        runs.remove(at: runIndex)
        tally(verdict, run.connections.count)
        return removal
    }

    /// Puts back what a refused verdict took off, and takes its count back.
    /// `only` limits it to some connections (the ones a batch could not weave in).
    public mutating func restore(_ removal: Removal, verdict: DreamVerdict, only ids: Set<String>? = nil) {
        let wanted = removal.connections.filter { ids == nil || ids!.contains($0.connection.id) }
        guard !wanted.isEmpty else { return }
        if let runIndex = runs.firstIndex(where: { $0.id == removal.runId }) {
            for entry in wanted.sorted(by: { $0.index < $1.index }) where !runs[runIndex].connections.contains(where: { $0.id == entry.connection.id }) {
                runs[runIndex].connections.insert(entry.connection, at: min(entry.index, runs[runIndex].connections.count))
            }
        } else {
            let run = DreamRun(id: removal.runId, createdAt: removal.runCreatedAt, connections: wanted.sorted { $0.index < $1.index }.map(\.connection))
            runs.insert(run, at: min(removal.runIndex, runs.count))
        }
        tally(verdict, -wanted.count)
    }

    private mutating func tally(_ verdict: DreamVerdict, _ count: Int) {
        switch verdict {
        case .accept: acceptedThisSitting = max(0, acceptedThisSitting + count)
        case .reject: rejectedThisSitting = max(0, rejectedThisSitting + count)
        }
    }
}

// MARK: Endpoints

extension Endpoint where Response == DreamQueue {
    public static var dreamQueue: Endpoint<DreamQueue> {
        Endpoint(.get, "/api/dreams")
    }
}

extension Endpoint where Response == DreamSettings {
    public static var dreamSettings: Endpoint<DreamSettings> {
        Endpoint(.get, "/api/dreams/settings")
    }

    public static func setDreaming(enabled: Bool) -> Endpoint<DreamSettings> {
        Endpoint(.put, "/api/dreams/settings", body: .jsonValue(["enabled": .bool(enabled)]))
    }
}

extension Endpoint where Response == DreamRunResult {
    /// "Dream now". The server does the whole pass before it answers.
    public static var dreamNow: Endpoint<DreamRunResult> {
        Endpoint(.post, "/api/dreams/run", timeout: 90)
    }
}

extension Endpoint where Response == DreamDecision {
    /// Accept or reject one connection. The keys go out as the route spells them (`runId`).
    public static func dreamDecide(connection id: String, _ verdict: DreamVerdict) -> Endpoint<DreamDecision> {
        Endpoint(.post, "/api/dreams", body: .jsonValue(["decision": .string(verdict.rawValue), "id": .string(id)]))
    }

    /// Accept or reject every connection still pending in a run.
    public static func dreamDecide(run id: String, _ verdict: DreamVerdict) -> Endpoint<DreamDecision> {
        Endpoint(.post, "/api/dreams", body: .jsonValue(["decision": .string(verdict.rawValue), "runId": .string(id)]))
    }
}
