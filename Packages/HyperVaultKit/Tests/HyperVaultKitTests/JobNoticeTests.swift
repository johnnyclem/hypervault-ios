import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// What the job toast of the web (`components/job-notifications.tsx`) says about the jobs `GET /api/jobs` lists
/// (`app/api/jobs/route.ts`), and in which order. The repair route (`app/api/artifacts/[slug]/repair/route.ts`) is the
/// only job there is today, so the fixtures are its labels and messages.
final class JobNoticeTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func job(
        _ id: String, _ status: BackgroundJobStatus, label: String = "", result: JSONValue? = nil, error: String? = nil
    ) -> BackgroundJob {
        BackgroundJob(id: id, kind: "artifact_repair", status: status, label: label, result: result, error: error)
    }

    // MARK: One notice

    func testAJobThatWorkedSaysItsLabelAndItsMessage() throws {
        let notice = try XCTUnwrap(BackgroundJobNotice(job: job(
            "j1", .succeeded, label: "Repairing \u{201C}Trip plan\u{201D}",
            result: ["changed": true, "message": "My Claude took a pass at it \u{2014} reload the artifact to see if it renders now."]
        )))
        XCTAssertEqual(notice.id, "j1")
        XCTAssertEqual(notice.title, "Repairing \u{201C}Trip plan\u{201D}")
        XCTAssertEqual(notice.message, "My Claude took a pass at it \u{2014} reload the artifact to see if it renders now.")
        XCTAssertTrue(notice.succeeded)
        XCTAssertTrue(notice.changedSomething)
    }

    func testAJobThatFailedSaysItsError() throws {
        let notice = try XCTUnwrap(BackgroundJobNotice(job: job(
            "j2", .failed, label: "Repairing \u{201C}Budget\u{201D}", error: "Repaired, but couldn't save it: permission denied"
        )))
        XCTAssertEqual(notice.message, "Repaired, but couldn't save it: permission denied")
        XCTAssertFalse(notice.succeeded)
        XCTAssertFalse(notice.changedSomething)
    }

    func testTheWebsWordsFillInWhatTheServerLeftOut() throws {
        let worked = try XCTUnwrap(BackgroundJobNotice(job: job("j3", .succeeded)))
        XCTAssertEqual(worked.title, "Background job finished")
        XCTAssertEqual(worked.message, "Done.")
        let failed = try XCTUnwrap(BackgroundJobNotice(job: job("j4", .failed)))
        XCTAssertEqual(failed.title, "Background job finished")
        XCTAssertEqual(failed.message, "It failed \u{2014} try again.")
        let nulls = try XCTUnwrap(BackgroundJobNotice(job: job("j5", .succeeded, result: ["message": .null, "changed": .null])))
        XCTAssertEqual(nulls.message, "Done.")
        XCTAssertFalse(nulls.changedSomething)
    }

    func testAJobThatChangedNothingSaysSoWithoutAskingForARefresh() throws {
        let notice = try XCTUnwrap(BackgroundJobNotice(job: job(
            "j6", .succeeded,
            result: ["changed": false, "message": "My Claude looked it over but didn't change anything."]
        )))
        XCTAssertTrue(notice.succeeded)
        XCTAssertFalse(notice.changedSomething)
        // Only a real true counts, not a word that happens to be there.
        let odd = try XCTUnwrap(BackgroundJobNotice(job: job("j7", .succeeded, result: ["changed": "yes"])))
        XCTAssertFalse(odd.changedSomething)
    }

    func testAFailedJobNeverAsksForARefreshWhateverItsResultSays() throws {
        let notice = try XCTUnwrap(BackgroundJobNotice(job: job("j8", .failed, result: ["changed": true], error: "no")))
        XCTAssertFalse(notice.changedSomething)
    }

    func testAJobThatIsStillGoingHasNothingToSay() {
        XCTAssertNil(BackgroundJobNotice(job: job("j9", .pending)))
        XCTAssertNil(BackgroundJobNotice(job: job("j10", .running)))
    }

    // MARK: The order

    func testTheQueueKeepsTheServersOrderAndLeavesOutWhatIsNotFinished() {
        let notices = BackgroundJobNotice.queue(from: [
            job("a", .succeeded), job("b", .running), job("c", .failed, error: "no"), job("d", .succeeded),
        ])
        XCTAssertEqual(notices.map(\.id), ["a", "c", "d"])
    }

    func testTheQueueLeavesOutWhatThePersonHasDismissed() {
        let jobs = [job("a", .succeeded), job("b", .succeeded), job("c", .failed)]
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, skipping: ["a", "c"]).map(\.id), ["b"])
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, skipping: ["a", "b", "c"]), [])
        XCTAssertEqual(BackgroundJobNotice.queue(from: [], skipping: ["a"]), [])
    }

    func testTheNoticeBeingReadStaysFirstWhileANewerOneArrives() {
        // The server lists newest first, so "new" is ahead of "old" in the next answer.
        let jobs = [job("new", .succeeded), job("old", .succeeded), job("older", .failed)]
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs).map(\.id), ["new", "old", "older"])
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, holding: "old").map(\.id), ["old", "new", "older"])
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, holding: "new").map(\.id), ["new", "old", "older"])
    }

    func testAHeldNoticeThatIsNoLongerListedHoldsNothing() {
        // Someone else acknowledged it (the web, or the sheet that started it).
        let jobs = [job("new", .succeeded), job("old", .succeeded)]
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, holding: "gone").map(\.id), ["new", "old"])
        XCTAssertEqual(BackgroundJobNotice.queue(from: jobs, skipping: ["old"], holding: "old").map(\.id), ["new"])
    }

    // MARK: From the wire

    // The shape of `GET /api/jobs` (app/api/jobs/route.ts: the columns it selects, newest first) with the repair
    // route's own label and messages.
    private let listJSON = #"""
    {"jobs":[
     {"id":"job-2","kind":"artifact_repair","status":"failed","label":"Repairing \#u{201C}Budget 2026\#u{201D}","result":null,"error":"No LLM backend is connected.","created_at":"2026-10-27T10:00:00.000Z","started_at":"2026-10-27T10:00:01.000Z","finished_at":"2026-10-27T10:00:09.000Z","acknowledged_at":null},
     {"id":"job-1","kind":"artifact_repair","status":"succeeded","label":"Repairing \#u{201C}Trip plan\#u{201D}","result":{"changed":true,"backend":{"id":"b1","name":"My Claude"},"model":"claude","source":"<h1>x</h1>","message":"My Claude took a pass at it \#u{2014} reload the artifact to see if it renders now."},"error":null,"created_at":"2026-10-27T09:00:00.000Z","started_at":"2026-10-27T09:00:01.000Z","finished_at":"2026-10-27T09:00:40.000Z","acknowledged_at":null}
    ]}
    """#

    func testTheListTheServerSendsBecomesTwoNotices() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/jobs", listJSON)])
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let list = try await api.send(.backgroundJobs)
        let notices = BackgroundJobNotice.queue(from: list.jobs)
        XCTAssertEqual(notices.map(\.title), ["Repairing \u{201C}Budget 2026\u{201D}", "Repairing \u{201C}Trip plan\u{201D}"])
        XCTAssertEqual(notices.map(\.succeeded), [false, true])
        XCTAssertEqual(notices.map(\.changedSomething), [false, true])
        XCTAssertEqual(notices[0].message, "No LLM backend is connected.")
        XCTAssertEqual(notices[1].message, "My Claude took a pass at it \u{2014} reload the artifact to see if it renders now.")
    }

    func testAnAnswerWithoutJobsIsAnEmptyQueue() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/jobs", "{}")])
        let api = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let list = try await api.send(.backgroundJobs)
        XCTAssertEqual(BackgroundJobNotice.queue(from: list.jobs), [])
    }
}
