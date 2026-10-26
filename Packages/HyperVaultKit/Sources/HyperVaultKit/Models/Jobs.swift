import Foundation

// Background jobs (lib/jobs.ts, app/api/jobs/**): long work the server runs
// after the response has gone, polled by id. The web app polls `GET
// /api/jobs/[id]` while someone waits and `GET /api/jobs` on a timer for the
// ones that finished while nobody watched.

public enum BackgroundJobStatus: String, Sendable, Codable, Hashable {
    case pending, running, succeeded, failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BackgroundJobStatus(rawValue: raw) ?? .pending
    }

    public var isFinished: Bool { self == .succeeded || self == .failed }
}

public struct BackgroundJob: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let kind: String
    public let status: BackgroundJobStatus
    public let label: String
    public let result: JSONValue?
    public let error: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let acknowledgedAt: Date?

    public init(
        id: String, kind: String = "", status: BackgroundJobStatus = .pending, label: String = "", result: JSONValue? = nil,
        error: String? = nil, createdAt: Date? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, acknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.label = label
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.acknowledgedAt = acknowledgedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        status = try c.decodeIfPresent(BackgroundJobStatus.self, forKey: .status) ?? .pending
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        acknowledgedAt = try c.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
    }

    enum Keys: String, CodingKey {
        case id, kind, status, label, result, error, createdAt, startedAt, finishedAt, acknowledgedAt
    }

    public var isFinished: Bool { status.isFinished }

    /// The sentence to show for a finished job: its result's `message`, or its
    /// error, in the server's words.
    public var outcomeMessage: String? {
        switch status {
        case .succeeded: return result?["message"]?.string
        case .failed: return error ?? "It failed — try again."
        default: return nil
        }
    }
}

/// `GET /api/jobs`: finished jobs nobody has acknowledged yet.
public struct BackgroundJobList: Sendable, Codable, Equatable {
    public let jobs: [BackgroundJob]

    public init(jobs: [BackgroundJob] = []) {
        self.jobs = jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        jobs = try c.decodeIfPresent([BackgroundJob].self, forKey: .jobs) ?? []
    }

    enum Keys: String, CodingKey { case jobs }
}

struct BackgroundJobEnvelope: Sendable, Decodable {
    let job: BackgroundJob
}

/// How a wait for a job ended.
public enum BackgroundJobWait: Sendable, Equatable {
    case finished(BackgroundJob)
    /// Still going when the wait ran out. The server keeps working; the job
    /// turns up in `GET /api/jobs` when it is done.
    case stillRunning(BackgroundJob)

    public var job: BackgroundJob {
        switch self {
        case .finished(let job), .stillRunning(let job): return job
        }
    }
}

/// Polls a job until it finishes or the wait runs out.
public struct BackgroundJobPoller: Sendable {
    private let client: HVClient
    private let interval: TimeInterval
    private let maxWait: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        client: HVClient,
        interval: TimeInterval = 2,
        maxWait: TimeInterval = 120,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.client = client
        self.interval = interval
        self.maxWait = maxWait
        self.sleep = sleep
    }

    /// Polls `GET /api/jobs/[id]`. A poll that fails for a passing reason
    /// (offline for a moment) is tried again; a missing job or a refusal ends the wait.
    public func wait(for id: String, onUpdate: (@Sendable (BackgroundJob) -> Void)? = nil) async throws -> BackgroundJobWait {
        var waited: TimeInterval = 0
        var last: BackgroundJob?
        while true {
            if Task.isCancelled { throw HVError.cancelled }
            do {
                let job = try await client.send(.backgroundJob(id: id))
                last = job
                onUpdate?(job)
                if job.isFinished { return .finished(job) }
            } catch let error as HVError {
                switch error {
                case .transport: break
                case .api(let failure) where failure.status >= 500: break
                default: throw error
                }
            }
            if waited >= maxWait { return .stillRunning(last ?? BackgroundJob(id: id)) }
            await sleep(interval)
            waited += interval
        }
    }
}

extension Endpoint where Response == BackgroundJobList {
    public static var backgroundJobs: Endpoint<BackgroundJobList> {
        Endpoint(.get, "/api/jobs")
    }
}

extension Endpoint where Response == BackgroundJob {
    public static func backgroundJob(id: String) -> Endpoint<BackgroundJob> {
        Endpoint(method: .get, path: "/api/jobs/\(id)") { response, keys in
            try HVCoding.decoder(keys).decode(BackgroundJobEnvelope.self, from: response.data).job
        }
    }
}

extension Endpoint where Response == NoContent {
    /// Stops a finished job being surfaced again.
    public static func acknowledgeBackgroundJob(id: String) -> Endpoint<NoContent> {
        Endpoint(.post, "/api/jobs/\(id)")
    }
}
