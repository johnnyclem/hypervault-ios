import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures are shaped by app/api/dreams/**, app/api/digest/** and app/api/jobs/**.
final class DreamsDigestJobsTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func client(_ routes: [MockRoute]) -> (HVClient, MockTransport) {
        let transport = MockTransport(routes: routes)
        return (HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none), transport)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try HVCoding.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Dreams

    private let queueJSON = #"""
    {"dreaming_enabled":true,"last_run_at":"2026-10-25T03:00:00.000Z","pending_count":3,"runs":[
      {"id":"run1","created_at":"2026-10-25T03:00:00Z","connections":[
        {"id":"d1","edge_type":"memory_memory","score":0.91,"reason":"Both are about passkeys.","a":{"kind":"memory","id":"m1","label":"Auth decision"},"b":{"kind":"memory","id":"m2","label":"Passkeys notes"}},
        {"id":"d2","edge_type":"memory_artifact","score":0.7,"reason":"The trip plan page mentions this.","a":{"kind":"memory","id":"m3","label":"Trip notes"},"b":{"kind":"artifact","id":"a1","label":"Trip plan","slug":"trip-plan"}}]},
      {"id":"run0","created_at":"2026-10-24T03:00:00Z","connections":[
        {"id":"d3","edge_type":"artifact_artifact","score":0.5,"reason":"Same client.","a":{"kind":"artifact","id":"a2","label":"Invoice","slug":"invoice"},"b":{"kind":"artifact","id":"a3","label":"(deleted artifact)"}}]}
    ]}
    """#

    func testDreamQueueDecodes() throws {
        let queue = try decode(DreamQueue.self, queueJSON)
        XCTAssertTrue(queue.dreamingEnabled)
        XCTAssertNotNil(queue.lastRunAt)
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(queue.runs.count, 2)
        let first = queue.runs[0].connections[0]
        XCTAssertEqual(first.edgeType, .memoryMemory)
        XCTAssertEqual(first.edgeType.label, "Memory to memory")
        XCTAssertEqual(first.score, 0.91, accuracy: 0.0001)
        XCTAssertEqual(first.a.label, "Auth decision")
        XCTAssertEqual(queue.runs[0].connections[1].b.slug, "trip-plan")
        XCTAssertEqual(queue.runs[0].connections[1].b.kind, .artifact)
        XCTAssertTrue(queue.runs[1].connections[0].b.isGone)
        XCTAssertFalse(first.a.isGone)
    }

    func testAnEmptyQueueHasNoRuns() throws {
        let queue = try decode(DreamQueue.self, #"{"dreaming_enabled":false,"last_run_at":null,"pending_count":0,"runs":[]}"#)
        XCTAssertFalse(queue.dreamingEnabled)
        XCTAssertNil(queue.lastRunAt)
        XCTAssertTrue(DreamReview(runs: queue.runs).isEmpty)
    }

    func testReviewTakesAConnectionOffAndPutsItBackWhereItWas() throws {
        let queue = try decode(DreamQueue.self, queueJSON)
        var review = DreamReview(runs: queue.runs)
        XCTAssertEqual(review.pendingCount, 3)

        let removal = try XCTUnwrap(review.remove(connection: "d1", verdict: .accept))
        XCTAssertEqual(review.pendingCount, 2)
        XCTAssertEqual(review.acceptedThisSitting, 1)
        XCTAssertNil(review.connection("d1"))
        XCTAssertEqual(review.runs[0].connections.map(\.id), ["d2"])

        review.restore(removal, verdict: .accept)
        XCTAssertEqual(review.runs[0].connections.map(\.id), ["d1", "d2"], "back in its place")
        XCTAssertEqual(review.acceptedThisSitting, 0, "a refusal does not count")
        XCTAssertEqual(review, DreamReview(runs: queue.runs))
    }

    func testAnEmptiedRunLeavesAndComesBack() throws {
        var review = DreamReview(runs: try decode(DreamQueue.self, queueJSON).runs)
        let removal = try XCTUnwrap(review.remove(connection: "d3", verdict: .reject))
        XCTAssertEqual(review.runs.map(\.id), ["run1"], "a run with nothing left goes")
        XCTAssertEqual(review.rejectedThisSitting, 1)
        review.restore(removal, verdict: .reject)
        XCTAssertEqual(review.runs.map(\.id), ["run1", "run0"])
        XCTAssertEqual(review.runs[1].createdAt, HVDate.parse("2026-10-24T03:00:00Z"))
        XCTAssertEqual(review.rejectedThisSitting, 0)
    }

    func testAWholeRunCanBeDecidedAndPartlyRestored() throws {
        var review = DreamReview(runs: try decode(DreamQueue.self, queueJSON).runs)
        let removal = try XCTUnwrap(review.remove(run: "run1", verdict: .accept))
        XCTAssertEqual(review.pendingCount, 1)
        XCTAssertEqual(review.acceptedThisSitting, 2)
        // The server wove d1 in but could not weave d2: it stays pending.
        review.restore(removal, verdict: .accept, only: ["d2"])
        XCTAssertEqual(review.runs.first?.connections.map(\.id), ["d2"])
        XCTAssertEqual(review.acceptedThisSitting, 1)
        XCTAssertNil(review.remove(connection: "nope", verdict: .accept))
        XCTAssertNil(review.remove(run: "nope", verdict: .accept))
    }

    func testDreamCalls() async throws {
        let (api, transport) = client([
            .json(.get, "/api/dreams", queueJSON),
            .json(.get, "/api/dreams/settings", #"{"enabled":false,"last_run_at":null}"#),
            .json(.put, "/api/dreams/settings", #"{"enabled":true,"last_run_at":"2026-10-25T03:00:00.000Z"}"#),
            .json(.post, "/api/dreams/run", #"{"run_id":"run2","counts":{"artifact_artifact":0,"memory_memory":2,"memory_artifact":1,"total":3},"message":"Dreamt up 3 new connections to review."}"#),
            .json(.post, "/api/dreams", #"{"accepted":1,"rejected":0,"failures":[],"message":"Merged 1 connection into your graph."}"#),
        ])
        let settings = try await api.send(.dreamSettings)
        XCTAssertFalse(settings.enabled)
        let turnedOn = try await api.send(.setDreaming(enabled: true))
        XCTAssertTrue(turnedOn.enabled)
        let ran = try await api.send(.dreamNow)
        XCTAssertEqual(ran.total, 3)
        XCTAssertEqual(ran.runId, "run2")
        XCTAssertNil(ran.jobId)
        XCTAssertFalse(ran.foundNothing)
        XCTAssertEqual(ran.message, "Dreamt up 3 new connections to review.")
        let decision = try await api.send(.dreamDecide(connection: "d1", .accept))
        XCTAssertEqual(decision.accepted, 1)
        _ = try await api.send(.dreamDecide(run: "run1", .reject))
        _ = try await api.send(.dreamQueue)

        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[1].httpBody ?? Data(), as: UTF8.self), #"{"enabled":true}"#)
        XCTAssertEqual(sent[2].httpMethod, "POST")
        XCTAssertNil(sent[2].httpBody)
        XCTAssertEqual(String(decoding: sent[3].httpBody ?? Data(), as: UTF8.self), #"{"decision":"accept","id":"d1"}"#)
        // The route reads `runId`, camel-cased: it must not become `run_id`.
        XCTAssertEqual(String(decoding: sent[4].httpBody ?? Data(), as: UTF8.self), #"{"decision":"reject","runId":"run1"}"#)
    }

    func testAQuietNightSaysSo() throws {
        let ran = try decode(DreamRunResult.self, #"{"run_id":null,"counts":{"artifact_artifact":0,"memory_memory":0,"memory_artifact":0,"total":0},"message":"No new connections this time — your graph is already well woven."}"#)
        XCTAssertTrue(ran.foundNothing)
        XCTAssertEqual(ran.total, 0)
        XCTAssertEqual(ran.message, "No new connections this time — your graph is already well woven.")
    }

    func testPartialFailuresComeBackWithTheirReasons() throws {
        let decision = try decode(DreamDecision.self, #"{"accepted":1,"rejected":0,"failures":[{"id":"d2","error":"Could not link: memory was forgotten."}],"message":"Merged 1 connection into your graph."}"#)
        XCTAssertEqual(decision.failures, [DreamDecision.Failure(id: "d2", error: "Could not link: memory was forgotten.")])
    }

    func testNothingPendingIsA404WithTheServersSentence() async {
        let (api, _) = client([.failure(.post, "/api/dreams", status: 404, message: "Nothing pending to decide — it may already have been reviewed.")])
        do {
            _ = try await api.send(.dreamDecide(connection: "d1", .accept))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.userMessage, "Nothing pending to decide — it may already have been reviewed.")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: Digest

    private let digestJSON = #"""
    {"digestion_enabled":true,"pending_count":1,"runs":[
      {"id":"dg1","source_memory_id":"m7","source_title":"Planning chat","strategy":"chat","created_at":"2026-10-25T09:00:00Z",
       "segments":[
         {"ordinal":0,"title":"Budget","summary":"We set the budget.","tags":["budget"],"reason":"Speaker turn"},
         {"ordinal":1,"title":"Timeline","summary":"Ship in March.","tags":null,"reason":"Speaker turn"},
         {"ordinal":2,"title":"Budget follow-up","summary":"Revisit budget.","tags":["budget"],"reason":"Speaker turn"}],
       "links":[{"a":0,"b":1,"kind":"sequence"},{"a":1,"b":2,"kind":"sequence"},{"a":0,"b":2,"kind":"theme"}]}]}
    """#

    func testDigestQueueDecodes() throws {
        let queue = try decode(DigestQueue.self, digestJSON)
        XCTAssertTrue(queue.digestionEnabled)
        let run = try XCTUnwrap(queue.runs.first)
        XCTAssertEqual(run.displayTitle, "Planning chat")
        XCTAssertEqual(run.strategy, .chat)
        XCTAssertEqual(run.strategy.label, "chat transcript")
        XCTAssertEqual(run.segments.map(\.title), ["Budget", "Timeline", "Budget follow-up"])
        XCTAssertEqual(run.segments[1].tags, [])
        XCTAssertEqual(run.themeLinkCount, 1)
        XCTAssertEqual(run.linksLine, "The pieces stay chained in reading order, plus 1 thematic link between related pieces.")
        let plain = DigestRun(id: "x", sourceMemoryId: "m", sourceTitle: "", links: [DigestLink(a: 0, b: 1, kind: .sequence)])
        XCTAssertEqual(plain.displayTitle, "Untitled memory")
        XCTAssertEqual(plain.linksLine, "The pieces stay chained in reading order.")
    }

    func testDigestCalls() async throws {
        let (api, transport) = client([
            .json(.get, "/api/digest", digestJSON),
            .json(.get, "/api/digest/settings", #"{"enabled":true}"#),
            .json(.put, "/api/digest/settings", #"{"enabled":false}"#),
            .json(.post, "/api/digest/run", #"{"run_id":"dg2","strategy":"headings","segment_count":4,"message":"Proposed splitting this into 4 memories — review the digest."}"#),
            .json(.post, "/api/digest", #"{"status":"applied","commit_id":"c1","created":3,"links":3,"branch":"main","message":"Split into 3 memories, wired with 3 links."}"#),
        ])
        let settings = try await api.send(.digestSettings)
        XCTAssertTrue(settings.enabled)
        let turnedOff = try await api.send(.setDigesting(enabled: false))
        XCTAssertFalse(turnedOff.enabled)
        let proposal = try await api.send(.digestMemory(id: "m7", branch: "ideas"))
        XCTAssertTrue(proposal.staged)
        XCTAssertEqual(proposal.segmentCount, 4)
        XCTAssertEqual(proposal.strategy, .headings)
        let decision = try await api.send(.digestDecide(run: "dg1", .accept))
        XCTAssertTrue(decision.applied)
        XCTAssertEqual(decision.created, 3)
        XCTAssertEqual(decision.message, "Split into 3 memories, wired with 3 links.")
        _ = try await api.send(.digestQueue)

        let sent = await transport.requests
        // `memoryId` and `runId` are read as the route spells them.
        XCTAssertEqual(String(decoding: sent[2].httpBody ?? Data(), as: UTF8.self), #"{"branch":"ideas","memoryId":"m7"}"#)
        XCTAssertEqual(String(decoding: sent[3].httpBody ?? Data(), as: UTF8.self), #"{"decision":"accept","runId":"dg1"}"#)
    }

    func testNothingToSplitSaysWhy() throws {
        let proposal = try decode(DigestProposal.self, #"{"run_id":null,"strategy":"none","segment_count":0,"message":"Nothing to split — this reads as a single memory."}"#)
        XCTAssertFalse(proposal.staged)
        XCTAssertEqual(proposal.message, "Nothing to split — this reads as a single memory.")
    }

    func testRejectingKeepsTheMemoryWhole() throws {
        let decision = try decode(DigestDecision.self, #"{"status":"rejected","message":"Digest dismissed — the memory was left whole."}"#)
        XCTAssertFalse(decision.applied)
        XCTAssertEqual(decision.message, "Digest dismissed — the memory was left whole.")
    }

    func testAlreadyReviewedIsAConflictWithTheServersSentence() async {
        let (api, _) = client([.failure(.post, "/api/digest", status: 409, message: "This digest has already been reviewed.")])
        do {
            _ = try await api.send(.digestDecide(run: "dg1", .accept))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "This digest has already been reviewed.")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: Jobs

    func testJobsDecode() throws {
        let job = try decode(BackgroundJob.self, #"{"id":"j1","kind":"repair","status":"succeeded","label":"Repair \"Trip plan\"","result":{"changed":true,"message":"Fixed 2 problems."},"error":null,"created_at":"2026-10-25T09:00:00Z","started_at":"2026-10-25T09:00:01Z","finished_at":"2026-10-25T09:00:30Z","acknowledged_at":null}"#)
        XCTAssertEqual(job.status, .succeeded)
        XCTAssertTrue(job.isFinished)
        XCTAssertEqual(job.outcomeMessage, "Fixed 2 problems.")
        XCTAssertNil(job.acknowledgedAt)
        let failed = try decode(BackgroundJob.self, #"{"id":"j2","kind":"repair","status":"failed","label":"","result":null,"error":"The model timed out."}"#)
        XCTAssertEqual(failed.outcomeMessage, "The model timed out.")
        let weird = try decode(BackgroundJob.self, #"{"id":"j3","status":"warming"}"#)
        XCTAssertEqual(weird.status, .pending)
        XCTAssertFalse(weird.isFinished)
        XCTAssertNil(weird.outcomeMessage)
    }

    func testJobEndpoints() async throws {
        let (api, transport) = client([
            .json(.get, "/api/jobs", #"{"jobs":[{"id":"j1","kind":"repair","status":"failed","label":"x","result":null,"error":"no"}]}"#),
            .json(.get, "/api/jobs/j1", #"{"job":{"id":"j1","kind":"repair","status":"running","label":"x","result":null,"error":null}}"#),
            .json(.post, "/api/jobs/j1", #"{"ok":true}"#),
        ])
        let list = try await api.send(.backgroundJobs)
        XCTAssertEqual(list.jobs.first?.error, "no")
        let polled = try await api.send(.backgroundJob(id: "j1"))
        XCTAssertEqual(polled.status, .running)
        _ = try await api.send(.acknowledgeBackgroundJob(id: "j1"))
        let sent = await transport.requests
        XCTAssertEqual(sent[2].httpMethod, "POST")
    }

    func testPollerWaitsForTheJobToFinish() async throws {
        let transport = MockTransport()
        let polls = PollCounter()
        await transport.add(MockRoute(.get, "/api/jobs/j1") { _ in
            let n = polls.bump()
            let status = n < 3 ? "running" : "succeeded"
            return HTTPResponse(status: 200, data: Data(#"{"job":{"id":"j1","kind":"dream","status":"\#(status)","label":"","result":{"message":"Done."},"error":null}}"#.utf8))
        })
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let slept = PollCounter()
        let poller = BackgroundJobPoller(client: api, interval: 2, maxWait: 60, sleep: { _ in _ = slept.bump() })
        let outcome = try await poller.wait(for: "j1")
        guard case .finished(let job) = outcome else { return XCTFail("expected it to finish") }
        XCTAssertEqual(job.outcomeMessage, "Done.")
        XCTAssertEqual(polls.value, 3)
        XCTAssertEqual(slept.value, 2)
    }

    func testPollerGivesUpWaitingButNotOnTheJob() async throws {
        let (api, _) = client([.json(.get, "/api/jobs/j1", #"{"job":{"id":"j1","kind":"dream","status":"running","label":"","result":null,"error":null}}"#)])
        let poller = BackgroundJobPoller(client: api, interval: 2, maxWait: 6, sleep: { _ in })
        let outcome = try await poller.wait(for: "j1")
        guard case .stillRunning(let job) = outcome else { return XCTFail("expected it to still be running") }
        XCTAssertEqual(job.status, .running)
    }

    func testPollerSurvivesABlipButNotAMissingJob() async throws {
        let transport = MockTransport()
        let polls = PollCounter()
        await transport.add(MockRoute(.get, "/api/jobs/j1") { _ in
            if polls.bump() == 1 { return HTTPResponse(status: 503, data: Data(#"{"error":"warming up"}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(#"{"job":{"id":"j1","kind":"dream","status":"failed","label":"","result":null,"error":"It failed — try again."}}"#.utf8))
        })
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let poller = BackgroundJobPoller(client: api, interval: 1, maxWait: 30, sleep: { _ in })
        let outcome = try await poller.wait(for: "j1")
        XCTAssertEqual(outcome.job.status, .failed)

        let (missing, _) = client([.failure(.get, "/api/jobs/j2", status: 404, message: "No job matching that id.")])
        do {
            _ = try await BackgroundJobPoller(client: missing, sleep: { _ in }).wait(for: "j2")
            XCTFail("expected the 404")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, "No job matching that id.")
        }
    }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
