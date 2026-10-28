import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the job notices ask, say and acknowledge, against a stand-in for the server's jobs (`app/api/jobs/**`): it lists
/// the finished jobs nobody has acknowledged, newest first, and an acknowledgement takes a job off the list. The asking
/// interval is set to a few milliseconds where a test needs the loop, and left at an hour where it calls `poll()` itself.
@MainActor
final class JobNoticesTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func make(
        _ server: JobsTestServer, interval: TimeInterval = 3600
    ) -> (notices: JobNotices, speech: RecordingAnnouncer) {
        let transport = MockTransport(routes: server.routes)
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let speech = RecordingAnnouncer()
        return (JobNotices(client: client, interval: interval, announcer: speech), speech)
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Never happened: \(what)", file: file, line: line)
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private let repairWorked = JobsTestServer.job(
        "job-1", label: "Repairing \u{201C}Trip plan\u{201D}",
        result: #"{"changed":true,"message":"My Claude took a pass at it \#u{2014} reload the artifact to see if it renders now."}"#
    )
    private let repairFailed = JobsTestServer.job(
        "job-2", "failed", label: "Repairing \u{201C}Budget\u{201D}", error: "No LLM backend is connected."
    )

    // MARK: Saying

    func testNothingFinishedSaysNothing() async {
        let server = JobsTestServer([])
        let (notices, speech) = make(server)
        await notices.poll()
        XCTAssertNil(notices.current)
        XCTAssertEqual(notices.waiting, 0)
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(server.acknowledgements, [])
    }

    func testTheNewestFinishedJobIsShownInTheWebsWordsAndTheRestWait() async throws {
        let server = JobsTestServer([repairFailed, repairWorked])
        let (notices, speech) = make(server)
        await notices.poll()
        let notice = try XCTUnwrap(notices.current)
        XCTAssertEqual(notice.id, "job-2")
        XCTAssertEqual(notice.title, "Repairing \u{201C}Budget\u{201D}")
        XCTAssertEqual(notice.message, "No LLM backend is connected.")
        XCTAssertFalse(notice.succeeded)
        XCTAssertEqual(notices.waiting, 1)
        XCTAssertEqual(speech.spoken, ["Error. Repairing \u{201C}Budget\u{201D}. No LLM backend is connected."])
        XCTAssertEqual(server.acknowledgements, [], "showing is not dismissing: the server hears nothing yet")
    }

    func testAnAnswerThatChangesNothingDoesNotSpeakAgain() async {
        let server = JobsTestServer([repairWorked])
        let (notices, speech) = make(server)
        await notices.poll()
        await notices.poll()
        await notices.poll()
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertEqual(notices.current?.id, "job-1")
    }

    func testTheNoticeBeingReadStaysWhileANewerJobArrivesBehindIt() async {
        let server = JobsTestServer([repairWorked])
        let (notices, speech) = make(server)
        await notices.poll()
        server.list([repairFailed, repairWorked])
        await notices.poll()
        XCTAssertEqual(notices.current?.id, "job-1", "the words under the thumb do not change")
        XCTAssertEqual(notices.waiting, 1)
        XCTAssertEqual(speech.spoken.count, 1)
    }

    func testAJobSomeoneElseAcknowledgedLeavesTheBanner() async {
        let server = JobsTestServer([repairWorked])
        let (notices, _) = make(server)
        await notices.poll()
        server.list([])
        await notices.poll()
        XCTAssertNil(notices.current)
        XCTAssertEqual(notices.waiting, 0)
    }

    // MARK: Dismissing

    func testDismissingTellsTheServerOnceAndShowsTheNextJob() async throws {
        let server = JobsTestServer([repairFailed, repairWorked])
        let (notices, speech) = make(server)
        await notices.poll()
        notices.dismiss("job-2")
        XCTAssertEqual(notices.current?.id, "job-1")
        XCTAssertEqual(notices.waiting, 0)
        notices.dismiss("job-2")
        await eventually("the acknowledgement") { server.acknowledgements.count == 1 }
        XCTAssertEqual(server.acknowledgements, ["job-2"], "a second tap on a notice that has gone does nothing")
        XCTAssertEqual(speech.spoken.count, 2, "the next job is spoken as it takes the banner")
        XCTAssertEqual(speech.spoken.last, "Repairing \u{201C}Trip plan\u{201D}. My Claude took a pass at it \u{2014} reload the artifact to see if it renders now.")
        notices.dismiss("job-1")
        XCTAssertNil(notices.current)
        await eventually("the second acknowledgement") { server.acknowledgements.count == 2 }
        XCTAssertEqual(server.acknowledgements, ["job-2", "job-1"])
    }

    func testADismissedJobIsNotShownAgainWhileTheServerStillListsIt() async {
        let server = JobsTestServer([repairWorked])
        server.refuseAcknowledgements = true
        let (notices, _) = make(server)
        await notices.poll()
        notices.dismiss("job-1")
        await eventually("the first try") { server.acknowledgements.count == 1 }
        await notices.poll()
        XCTAssertNil(notices.current, "the server never heard, but the person did dismiss it")
    }

    func testAnAcknowledgementThatFailedIsTriedAgainOnTheNextAskAndNotAfterItWorked() async {
        let server = JobsTestServer([repairWorked])
        server.refuseAcknowledgements = true
        let (notices, _) = make(server)
        await notices.poll()
        notices.dismiss("job-1")
        await eventually("the first try") { server.acknowledgements.count == 1 }
        await pause(0.05)

        server.refuseAcknowledgements = false
        await notices.poll()
        await eventually("the second try") { server.acknowledgements.count == 2 }
        XCTAssertEqual(server.acknowledgements, ["job-1", "job-1"])
        await pause(0.05)

        // A stale answer that lists it once more finds it already told about.
        server.keepListingAcknowledgedJobs = true
        server.list([repairWorked])
        await notices.poll()
        await pause(0.05)
        XCTAssertEqual(server.acknowledgements.count, 2)
        XCTAssertNil(notices.current)
    }

    func testAJobThatChangedSomethingMovesTheCountWhenItIsDismissed() async {
        let server = JobsTestServer([repairFailed, repairWorked])
        let (notices, _) = make(server)
        await notices.poll()
        XCTAssertEqual(notices.changes, 0)
        notices.dismiss("job-2")
        XCTAssertEqual(notices.changes, 0, "a failure changed nothing")
        notices.dismiss("job-1")
        XCTAssertEqual(notices.changes, 1)
    }

    func testAJobThatChangedNothingDoesNotMoveTheCount() async {
        let server = JobsTestServer([
            JobsTestServer.job("job-3", result: #"{"changed":false,"message":"My Claude looked it over but didn't change anything."}"#),
        ])
        let (notices, _) = make(server)
        await notices.poll()
        notices.dismiss("job-3")
        XCTAssertEqual(notices.changes, 0)
    }

    // MARK: Failing quietly

    func testAnAskThatFailsSaysNothingAndLeavesTheBannerAlone() async {
        let server = JobsTestServer([repairWorked])
        let (notices, speech) = make(server)
        server.isDown = true
        await notices.poll()
        XCTAssertNil(notices.current)
        XCTAssertTrue(speech.spoken.isEmpty)

        server.isDown = false
        await notices.poll()
        XCTAssertEqual(notices.current?.id, "job-1")

        server.isDown = true
        await notices.poll()
        XCTAssertEqual(notices.current?.id, "job-1", "a lost connection does not take the notice away")
        XCTAssertEqual(speech.spoken.count, 1)
    }

    // MARK: Watching

    func testTheFirstScreenToAppearAsksAtOnceAndTheNextOnesShareTheAsking() async {
        let server = JobsTestServer([repairWorked])
        let (notices, _) = make(server)
        let home = UUID()
        let library = UUID()
        notices.setWatching(home, true)
        await eventually("the first ask") { notices.current != nil }
        notices.setWatching(library, true)
        notices.setWatching(home, true)
        await pause(0.1)
        XCTAssertEqual(server.listings, 1, "one question however many screens, and however many times they say so")
        notices.setWatching(home, false)
        notices.setWatching(library, false)
    }

    func testTheAskingGoesOnEveryIntervalUntilTheLastScreenHasGone() async {
        let server = JobsTestServer([])
        let (notices, _) = make(server, interval: 0.02)
        let home = UUID()
        let library = UUID()
        notices.setWatching(home, true)
        notices.setWatching(library, true)
        await eventually("three asks") { server.listings >= 3 }

        notices.setWatching(home, false)
        let before = server.listings
        await eventually("asks while the Library still shows") { server.listings >= before + 3 }

        notices.setWatching(library, false)
        await pause(0.1)
        let stopped = server.listings
        await pause(0.2)
        XCTAssertEqual(server.listings, stopped, "no ask after the last screen has gone")
    }

    func testAScreenThatComesBackStartsAskingAgain() async {
        let server = JobsTestServer([])
        let (notices, _) = make(server, interval: 3600)
        let home = UUID()
        notices.setWatching(home, true)
        await eventually("the first ask") { server.listings == 1 }
        notices.setWatching(home, false)
        await pause(0.05)
        notices.setWatching(home, true)
        await eventually("an ask on coming back") { server.listings == 2 }
        notices.setWatching(home, false)
    }

    func testAnAnswerThatArrivesAfterTheLastScreenHasGoneSaysNothing() async {
        let server = JobsTestServer([repairWorked])
        let hold = RequestHold()
        await hold.arm()
        let transport = HeldTransport(base: MockTransport(routes: server.routes), hold: hold, holds: { $0.httpMethod == "GET" })
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let speech = RecordingAnnouncer()
        let notices = JobNotices(client: client, interval: 3600, announcer: speech)
        let home = UUID()

        notices.setWatching(home, true)
        await eventually("the ask is on its way") { await hold.waiting == 1 }
        notices.setWatching(home, false)
        await hold.release()
        await pause(0.1)

        XCTAssertEqual(server.listings, 1, "the ask was answered")
        XCTAssertNil(notices.current)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}

/// A stand-in for `app/api/jobs/**`: `GET /api/jobs` lists the finished jobs nobody has acknowledged and `POST
/// /api/jobs/[id]` acknowledges one, as the real routes do, with the faults a test turns on.
final class JobsTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String]
    private var told: [String] = []
    private var asks = 0
    private var refusing = false
    private var keeping = false
    private var down = false

    init(_ jobs: [String]) {
        self.jobs = jobs
    }

    /// A job as `GET /api/jobs` lists it (`app/api/jobs/route.ts`).
    static func job(_ id: String, _ status: String = "succeeded", label: String = "", result: String = "null", error: String? = nil) -> String {
        let failure = error.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","kind":"artifact_repair","status":"\#(status)","label":"\#(label)","result":\#(result),"error":\#(failure),"acknowledged_at":null}"#
    }

    var routes: [MockRoute] {
        [
            MockRoute(.get, "/api/jobs") { [self] _ in answerList() },
            MockRoute(.post, "/api/jobs/*") { [self] request in acknowledge(request) },
        ]
    }

    /// Replaces what the server lists.
    func list(_ jobs: [String]) { locked { self.jobs = jobs } }
    /// How many times the list was asked for.
    var listings: Int { locked { asks } }
    /// The ids of the acknowledgements that arrived, in order, whether or not they were taken.
    var acknowledgements: [String] { locked { told } }
    /// Answers every acknowledgement with a server error and changes nothing.
    var refuseAcknowledgements: Bool {
        get { locked { refusing } }
        set { locked { refusing = newValue } }
    }
    /// Takes an acknowledgement but goes on listing the job, as a stale answer would.
    var keepListingAcknowledgedJobs: Bool {
        get { locked { keeping } }
        set { locked { keeping = newValue } }
    }
    /// Answers the list with a server error.
    var isDown: Bool {
        get { locked { down } }
        set { locked { down = newValue } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func answerList() -> HTTPResponse {
        let (listed, isDown) = locked { () -> ([String], Bool) in
            asks += 1
            return (jobs, down)
        }
        if isDown {
            return HTTPResponse(status: 503, headers: ["content-type": "application/json"], data: Data(#"{"error":"Server is not configured with Supabase credentials."}"#.utf8))
        }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data("{\"jobs\":[\(listed.joined(separator: ","))]}".utf8))
    }

    private func acknowledge(_ request: URLRequest) -> HTTPResponse {
        let id = request.url?.lastPathComponent ?? ""
        let refused = locked { () -> Bool in
            told.append(id)
            if refusing { return true }
            if !keeping { jobs.removeAll { $0.contains("\"id\":\"\(id)\"") } }
            return false
        }
        if refused {
            return HTTPResponse(status: 500, headers: ["content-type": "application/json"], data: Data(#"{"error":"Could not acknowledge."}"#.utf8))
        }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"ok":true}"#.utf8))
    }
}
